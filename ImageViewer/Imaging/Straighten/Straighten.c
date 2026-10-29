// Tilt from straight lines: a Hough transform over strong edges, limited to lines near level and near plumb.
//
// Edge pixels (Sobel, the strongest few percent) vote for every line through them whose angle is within a
// few degrees of their own edge direction; votes pile up on long straight lines, and the angle of the best
// one is the tilt. Near-horizontal lines (a horizon, a shelf, a tabletop) are tried first; when there's no
// clear one, the near-vertical lines (walls, door frames) are used, taking the middle of the strongest few
// since verticals lean apart in perspective.

#include "Straighten.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define ANGLE_STEP 0.1          // degrees per accumulator bin
#define LOCAL_SPREAD 5.0        // a pixel votes for angles this close to its own edge direction
#define EDGE_FRACTION 0.08      // the strongest 8% of gradients count as edges
#define MIN_MAGNITUDE 48
#define BORDER_MARGIN 4         // pixels next to the picture's edges never count as edges

/// A line: its angle, votes, and where it crosses the middle of the picture (x for a near-vertical line at
/// half the height, y for a near-horizontal one at half the width).
typedef struct { double angle; int votes; double position; } Line;

static int cmp_line_votes(const void *a, const void *b) {
    return ((const Line *)b)->votes - ((const Line *)a)->votes;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

/// Hough over one family of lines, at angles from `lo` to `hi` degrees. `vertical` swaps the roles of x and y:
/// lines x = y·tan(a) + c. Fills `best` with up to `count` strongest lines (distinct angles), returns how many.
static int hough(const int16_t *gx, const int16_t *gy, const uint8_t *edge, int w, int h, double lo, double hi,
                 int vertical, Line *best, int count) {
    const int bins = (int)lround((hi - lo) / ANGLE_STEP) + 1;
    const int along = vertical ? h : w, across = vertical ? w : h;
    const double maxShift = along * tan(fmax(fabs(lo), fabs(hi)) * M_PI / 180);
    const int offsets = across + 2 * (int)ceil(maxShift) + 2;
    int32_t *acc = calloc((size_t)bins * offsets, sizeof(int32_t));
    double *tans = malloc(sizeof(double) * bins);
    if (!acc || !tans) { free(acc); free(tans); return 0; }
    for (int k = 0; k < bins; k++) tans[k] = tan((lo + k * ANGLE_STEP) * M_PI / 180);
    const int spread = (int)lround(LOCAL_SPREAD / ANGLE_STEP);

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const int p = y * w + x;
            if (!edge[p]) continue;
            // Along-axis and across-axis gradient: for horizontal lines the gradient points across (y).
            const double ga = vertical ? gy[p] : gx[p], gc = vertical ? gx[p] : gy[p];
            if (fabs(gc) < 2 * fabs(ga)) continue;          // this edge runs more than ~27° off the family
            const double local = atan(-ga / gc) * 180 / M_PI; // the edge's own slope angle
            int k0 = (int)lround((local - lo) / ANGLE_STEP) - spread, k1 = k0 + 2 * spread;
            if (k0 < 0) k0 = 0;
            if (k1 >= bins) k1 = bins - 1;
            const double a = vertical ? y : x, c = vertical ? x : y;
            for (int k = k0; k <= k1; k++) {
                const int o = (int)lround(c - a * tans[k] + maxShift) + 1;
                if (o >= 0 && o < offsets) acc[k * offsets + o]++;
            }
        }
    }

    // The strongest lines, one per angle neighborhood (so one long line doesn't fill every slot).
    int found = 0;
    for (int round = 0; round < count; round++) {
        int bestK = -1, bestO = 0, bestV = 0;
        for (int k = 0; k < bins; k++) {
            const int32_t *row = acc + (size_t)k * offsets;
            for (int o = 0; o < offsets; o++) if (row[o] > bestV) { bestV = row[o]; bestK = k; bestO = o; }
        }
        if (bestK < 0 || bestV == 0) break;
        best[found].angle = lo + bestK * ANGLE_STEP;
        best[found].votes = bestV;
        best[found].position = (bestO - 1 - maxShift) + along / 2.0 * tans[bestK];
        found++;
        // Suppress that line and its near neighbors.
        for (int k = bestK - 8; k <= bestK + 8; k++) {
            if (k < 0 || k >= bins) continue;
            for (int o = bestO - 6; o <= bestO + 6; o++) if (o >= 0 && o < offsets) acc[k * offsets + o] = 0;
        }
    }
    free(acc);
    free(tans);
    return found;
}

/// Sobel gradients and the strong edges, thinned to their ridges. Returns 0 when out of memory (nothing to free).
static int find_edges(const uint8_t *gray, int w, int h, int16_t **gxOut, int16_t **gyOut, uint8_t **edgeOut) {
    const int n = w * h;
    int16_t *gx = calloc((size_t)n, sizeof(int16_t)), *gy = calloc((size_t)n, sizeof(int16_t));
    uint8_t *edge = calloc((size_t)n, 1);
    if (!gx || !gy || !edge) { free(gx); free(gy); free(edge); return 0; }

    // Sobel, and the gradient magnitude's histogram for the edge threshold.
    int histogram[2048] = {0};
    for (int y = 1; y < h - 1; y++) {
        for (int x = 1; x < w - 1; x++) {
            const uint8_t *r0 = gray + (y - 1) * w + x, *r1 = gray + y * w + x, *r2 = gray + (y + 1) * w + x;
            const int sx = (r0[1] + 2 * r1[1] + r2[1]) - (r0[-1] + 2 * r1[-1] + r2[-1]);
            const int sy = (r2[-1] + 2 * r2[0] + r2[1]) - (r0[-1] + 2 * r0[0] + r0[1]);
            gx[y * w + x] = (int16_t)sx;
            gy[y * w + x] = (int16_t)sy;
            int m = abs(sx) + abs(sy);
            histogram[m < 2047 ? m : 2047]++;
        }
    }
    int threshold = 2047, above = 0;
    while (threshold > MIN_MAGNITUDE && above + histogram[threshold] < n * EDGE_FRACTION) above += histogram[threshold--];
    // Thin the edges to their ridge (non-maximum along the gradient), so a thick edge counts once. The
    // picture's own border (and a dark sliver along it) isn't a line in the scene.
    const int margin = BORDER_MARGIN;
    for (int y = margin; y < h - margin; y++) {
        for (int x = margin; x < w - margin; x++) {
            const int p = y * w + x, m = abs(gx[p]) + abs(gy[p]);
            if (m < threshold) continue;
            int q1, q2;
            if (abs(gx[p]) > abs(gy[p])) { q1 = p - 1; q2 = p + 1; } else { q1 = p - w; q2 = p + w; }
            if (m >= abs(gx[q1]) + abs(gy[q1]) && m >= abs(gx[q2]) + abs(gy[q2])) edge[p] = 1;
        }
    }
    *gxOut = gx;
    *gyOut = gy;
    *edgeOut = edge;
    return 1;
}

/// The near-vertical lines' tilt, read at the middle of the picture: looking up or down, verticals lean apart
/// (more the further they are from the middle), so the strong ones' (at least half the best one's length)
/// angles are fitted against where they are across the picture and the fit is read at the center; with too
/// few to fit, the one nearest the center is used. Returns their strength (the best one's length as a fraction
/// of the height), 0 when there are none.
static double vertical_tilt(const int16_t *gx, const int16_t *gy, const uint8_t *edge, int w, int h, double maxDegrees,
                            double *degrees) {
    Line lines[8];
    const int found = hough(gx, gy, edge, w, h, -maxDegrees, maxDegrees, 1, lines, 8);
    if (!found) return 0;
    qsort(lines, (size_t)found, sizeof(Line), cmp_line_votes);
    int strong = 0;
    while (strong < found && lines[strong].votes * 2 >= lines[0].votes) strong++;
    // Weighted least squares of angle against position (u: -0.5 left edge … 0.5 right edge).
    double sw = 0, su = 0, sa = 0, suu = 0, sua = 0, lowest = 1e9, highest = -1e9;
    int nearest = 0;
    for (int i = 0; i < strong; i++) {
        const double u = lines[i].position / w - 0.5, a = lines[i].angle, wt = lines[i].votes;
        sw += wt; su += wt * u; sa += wt * a; suu += wt * u * u; sua += wt * u * a;
        if (a < lowest) lowest = a;
        if (a > highest) highest = a;
        if (fabs(u) < fabs(lines[nearest].position / w - 0.5)) nearest = i;
    }
    const double meanU = su / sw, varU = suu / sw - meanU * meanU;
    if (strong >= 3 && varU >= 0.15 * 0.15) {
        const double slope = (sua / sw - meanU * (sa / sw)) / varU;
        const double atCenter = sa / sw - slope * meanU;
        // (Never past the angles seen: no extrapolating.)
        *degrees = fmin(fmax(atCenter, lowest), highest);
    } else {
        *degrees = lines[nearest].angle;
    }
    return (double)lines[0].votes / h;
}

int iv_tilt_families(const uint8_t *gray, int width, int height, double maxDegrees,
                     double *hDegrees, double *hStrength, double *hDisagreement, double *vDegrees, double *vStrength) {
    if (!gray || width < 16 || height < 16 || !hDegrees || !hStrength || !hDisagreement || !vDegrees || !vStrength) return 0;
    int16_t *gx, *gy;
    uint8_t *edge;
    if (!find_edges(gray, width, height, &gx, &gy, &edge)) return 0;
    Line horizontals[8];
    *hDegrees = 0;
    *hStrength = 0;
    *hDisagreement = 0;
    const int found = hough(gx, gy, edge, width, height, -maxDegrees, maxDegrees, 0, horizontals, 8);
    if (found) {
        *hDegrees = -horizontals[0].angle;   // y runs down: a line rising to the right has a negative slope
        *hStrength = (double)horizontals[0].votes / width;
        // Other strong lines near level that tilt differently: lines receding in perspective (they converge),
        // not a tilted camera (which tilts every line alike).
        for (int i = 1; i < found; i++) {
            if (horizontals[i].votes * 10 < horizontals[0].votes * 6 || fabs(horizontals[i].angle) > 8) continue;
            const double apart = fabs(horizontals[i].angle - horizontals[0].angle);
            if (apart > *hDisagreement) *hDisagreement = apart;
        }
    }
    *vDegrees = 0;
    *vStrength = vertical_tilt(gx, gy, edge, width, height, maxDegrees, vDegrees);
    free(gx); free(gy); free(edge);
    return 1;
}

double iv_horizontal_strength_near(const uint8_t *gray, int width, int height, double degrees, double tolerance) {
    if (!gray || width < 16 || height < 16) return 0;
    int16_t *gx, *gy;
    uint8_t *edge;
    if (!find_edges(gray, width, height, &gx, &gy, &edge)) return 0;
    Line line;
    // (Lines' own angles run the other way: y runs down.)
    const int found = hough(gx, gy, edge, width, height, -degrees - tolerance, -degrees + tolerance, 0, &line, 1);
    free(gx); free(gy); free(edge);
    return found ? (double)line.votes / width : 0;
}

int iv_estimate_tilt(const uint8_t *gray, int width, int height, double maxDegrees,
                     double *degrees, double *strength, int *kind) {
    if (!gray || width < 16 || height < 16 || !degrees || !strength || !kind) return 0;
    const int w = width, h = height;
    int16_t *gx, *gy;
    uint8_t *edge;
    if (!find_edges(gray, w, h, &gx, &gy, &edge)) return 0;
    int status = 0;

    Line horizon;
    int found = hough(gx, gy, edge, w, h, -maxDegrees, maxDegrees, 0, &horizon, 1);
    const double horizontalStrength = found ? (double)horizon.votes / w : 0;
    if (found && horizontalStrength >= 0.3) {
        *degrees = -horizon.angle;   // y runs down: a line rising to the right has a negative slope
        *strength = horizontalStrength;
        *kind = 1;
        status = 1;
        goto done;
    }
    double vertical = 0;
    const double verticalStrength = vertical_tilt(gx, gy, edge, w, h, maxDegrees, &vertical);
    if (verticalStrength >= 0.33 && verticalStrength > horizontalStrength) {
        *degrees = vertical;
        *strength = verticalStrength;
        *kind = 2;
        status = 1;
        goto done;
    }
    if (horizontalStrength >= 0.25) {   // a weaker horizon is still better than nothing
        *degrees = -horizon.angle;
        *strength = horizontalStrength;
        *kind = 1;
        status = 1;
    }
done:
    free(gx); free(gy); free(edge);
    return status;
}
