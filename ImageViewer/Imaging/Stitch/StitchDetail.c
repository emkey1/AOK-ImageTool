#include "StitchDetail.h"

#include <dispatch/dispatch.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// The pictures' texture for the filled-in parts of a stitched picture. See StitchDetail.h.
//
// Everything is worked out at the filling's own size. A grid of points is laid over it, `spacing` apart. Each
// point near something filled in gets a shift: to the place in the pictures that's shaped most like the filling
// around the point (plain to plain; shapes are brightness, blurred, less a much wider blur of it), and of such
// places the one colored most alike, most evenly textured, and nearest. Neighbors that could as well share a
// shift are made to, so that texture comes in unbroken stretches of the pictures and not as a patchwork.
//
// A filled-in pixel then takes its detail from where its nearest point's shift leads (handing over to the next
// point's in the middle of each square of the grid); a pixel the pictures cover takes its own. Detail is two
// things: what the pictures hold beyond the filling's size (the picture at full size minus itself at the
// filling's size), and their texture at about the filling's size (itself minus its blur). In a filled-in place
// the second stands in for the filling's own of that size: a generator's asphalt is a speckle, which enlarged
// beside the real thing is a smear.

struct iv_detail {
    int w, h, spacing, gw, gh;
    /// The filling, and the pictures (the filling where they don't cover): w * h * 3.
    uint8_t *fill, *real;
    /// The pictures' texture at about the filling's size (`real` minus its blur), and the filling's own. w * h * 3.
    int16_t *mid, *fillMid;
    /// How strong that kind of texture is around each pixel, in the filling and in the pictures (levels). w * h.
    float *fillEnergy, *realEnergy;
    /// How bright each is around each pixel (their blur): texture taken to somewhere darker is turned down. w * h.
    float *fillLevel, *realLevel;
    /// The shapes in each at a few pixels' size (that blur, less a much wider one): what places are compared by,
    /// so that plain takes from plain and a railing's detail never lands on a wall. w * h.
    float *fillShape, *realShape;
    /// How much of the pictures shows: 255 inside them, fading out just inside their edges. w * h.
    uint8_t *show;
    /// Each grid point's shift to where its texture comes from (x, y); SHRT_MIN for nowhere. gw * gh * 2.
    int16_t *shift;
    /// How strong the pictures' texture is where a point's comes from, on the whole (levels): anything much
    /// stronger there is a thing (a leaf, a painted line), not texture, and is turned down. gw * gh.
    float *usual;
};

static inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

/// A box blur of radius `r`, `passes` times (three is about a Gaussian), each channel on its own, edges extended.
static int box_blur(float *data, int w, int h, int channels, int r, int passes) {
    if (r <= 0) return 1;
    int longest = w > h ? w : h;
    float *line = malloc(sizeof(float) * (size_t)longest);
    if (!line) return 0;
    float norm = 1.0f / (2 * r + 1);
    for (int pass = 0; pass < passes; pass++) {
        for (int c = 0; c < channels; c++) {
            for (int y = 0; y < h; y++) {
                float *row = data + (size_t)y * w * channels + c;
                for (int x = 0; x < w; x++) line[x] = row[(size_t)x * channels];
                float sum = 0;
                for (int k = -r; k <= r; k++) sum += line[clampi(k, 0, w - 1)];
                for (int x = 0; x < w; x++) {
                    row[(size_t)x * channels] = sum * norm;
                    sum += line[clampi(x + r + 1, 0, w - 1)] - line[clampi(x - r, 0, w - 1)];
                }
            }
            for (int x = 0; x < w; x++) {
                float *col = data + (size_t)x * channels + c;
                size_t step = (size_t)w * channels;
                for (int y = 0; y < h; y++) line[y] = col[(size_t)y * step];
                float sum = 0;
                for (int k = -r; k <= r; k++) sum += line[clampi(k, 0, h - 1)];
                for (int y = 0; y < h; y++) {
                    col[(size_t)y * step] = sum * norm;
                    sum += line[clampi(y + r + 1, 0, h - 1)] - line[clampi(y - r, 0, h - 1)];
                }
            }
        }
    }
    free(line);
    return 1;
}

/// Sums of `flags` over every rectangle from the top left corner: (w + 1) * (h + 1).
static uint32_t *sums_of(const uint8_t *flags, int w, int h) {
    uint32_t *sums = calloc((size_t)(w + 1) * (h + 1), sizeof(uint32_t));
    if (!sums) return NULL;
    for (int y = 0; y < h; y++) {
        uint32_t run = 0;
        for (int x = 0; x < w; x++) {
            run += flags[(size_t)y * w + x] ? 1 : 0;
            sums[(size_t)(y + 1) * (w + 1) + x + 1] = sums[(size_t)y * (w + 1) + x + 1] + run;
        }
    }
    return sums;
}

/// How many are flagged in columns x0...x1 and rows y0...y1 (inclusive, clipped to the image).
static inline uint32_t flagged(const uint32_t *sums, int w, int h, int x0, int y0, int x1, int y1) {
    x0 = clampi(x0, 0, w); y0 = clampi(y0, 0, h); x1 = clampi(x1 + 1, 0, w); y1 = clampi(y1 + 1, 0, h);
    if (x1 <= x0 || y1 <= y0) return 0;
    size_t stride = (size_t)w + 1;
    return sums[(size_t)y1 * stride + x1] - sums[(size_t)y0 * stride + x1] - sums[(size_t)y1 * stride + x0] + sums[(size_t)y0 * stride + x0];
}

/// Sums of `values` (or their squares) over every rectangle from the top left corner: (w + 1) * (h + 1).
static double *double_sums(const float *values, int w, int h, int squared) {
    double *sums = calloc((size_t)(w + 1) * (h + 1), sizeof(double));
    if (!sums) return NULL;
    for (int y = 0; y < h; y++) {
        double run = 0;
        for (int x = 0; x < w; x++) {
            double v = values[(size_t)y * w + x];
            run += squared ? v * v : v;
            sums[(size_t)(y + 1) * (w + 1) + x + 1] = sums[(size_t)y * (w + 1) + x + 1] + run;
        }
    }
    return sums;
}

/// The sum over columns x0...x1 and rows y0...y1 (inclusive, inside the image).
static inline double summed(const double *sums, int w, int x0, int y0, int x1, int y1) {
    size_t stride = (size_t)w + 1;
    return sums[(size_t)(y1 + 1) * stride + x1 + 1] - sums[(size_t)y0 * stride + x1 + 1] - sums[(size_t)(y1 + 1) * stride + x0] + sums[(size_t)y0 * stride + x0];
}

/// How strong the texture `texture` (w * h * 3, around zero) is around each pixel: the root of its mean square.
static int energy_of(const float *texture, int w, int h, float *energy) {
    size_t n = (size_t)w * h;
    for (size_t i = 0; i < n; i++) {
        float v = (texture[i * 3] + 2 * texture[i * 3 + 1] + texture[i * 3 + 2]) * 0.25f;
        energy[i] = v * v;
    }
    if (!box_blur(energy, w, h, 1, 3, 2)) return 0;
    for (size_t i = 0; i < n; i++) energy[i] = sqrtf(energy[i] > 0 ? energy[i] : 0);
    return 1;
}

typedef struct {
    iv_detail *d;
    /// The filling and the pictures, blurred wide: their color on the whole around each pixel. w * h * 3.
    const float *wideFill, *wideReal;
    /// Sums of the pixels the pictures don't cover, and of those not well inside them.
    const uint32_t *bare, *open;
    /// Sums of how strong the pictures' texture is around each pixel, and of that squared.
    const double *energy, *squares;
    double diagonal2;
} search_job;

enum { SAMPLES = 8 };
/// The blur that parts texture at about the filling's size from what's broader (about a Gaussian of 2 pixels).
enum { MID_RADIUS = 2, MID_PASSES = 2 };
/// How much being far away counts against a place: one whole diagonal away is as bad as looking this
/// different (levels, squared).
static const double FAR = 6000;
/// How much a place's texture being uneven counts against it (levels, squared, for its strength varying by as
/// much as its mean): even is texture, uneven has things in it.
static const double UNEVEN = 600;
/// How much a place's color on the whole being different counts against it, beside its shapes being different
/// (which count in full): texture is taken from what's shaped alike first (plain from plain, never a railing's
/// onto a wall), and of that from what's colored alike.
static const double TINT = 0.08;

/// How different the pictures around (cx, cy) look from the filling around (vx, vy), plus how far that is;
/// gives up (returning `limit`) once it's past `limit`.
static double cost_at(const search_job *job, int vx, int vy, int cx, int cy, double limit, double *usual) {
    const iv_detail *d = job->d;
    int w = d->w, h = d->h, S = d->spacing, step = S / SAMPLES < 1 ? 1 : S / SAMPLES;
    double far = FAR * ((double)(cx - vx) * (cx - vx) + (double)(cy - vy) * (cy - vy)) / job->diagonal2;
    if (far >= limit) return limit;
    // (The part of the point's surroundings that's in the image; the same part must be well inside the pictures.)
    int x0 = -S, x1 = S, y0 = -S, y1 = S;
    while (vx + x0 < 0) x0 += step;
    while (vx + x1 > w - 1) x1 -= step;
    while (vy + y0 < 0) y0 += step;
    while (vy + y1 > h - 1) y1 -= step;
    if (cx + x0 < 0 || cx + x1 > w - 1 || cy + y0 < 0 || cy + y1 > h - 1) return limit;
    if (flagged(job->open, w, h, cx + x0, cy + y0, cx + x1, cy + y1) != 0) return limit;
    int count = ((x1 - x0) / step + 1) * ((y1 - y0) / step + 1);
    if (count <= 0) return limit;
    // Texture that's as strong all over the place is texture; where it's uneven there are things in it.
    double area = (double)(x1 - x0 + 1) * (y1 - y0 + 1);
    double mean = summed(job->energy, w, cx + x0, cy + y0, cx + x1, cy + y1) / area;
    double spread = summed(job->squares, w, cx + x0, cy + y0, cx + x1, cy + y1) / area - mean * mean;
    far += UNEVEN * (spread > 0 ? spread : 0) / ((mean + 1) * (mean + 1));
    if (far >= limit) return limit;
    // (What it is where there's nothing but texture: its mean is raised by whatever things are there.)
    if (usual) *usual = fmax(mean - 0.75 * sqrt(spread > 0 ? spread : 0), 0.4 * mean);
    const float *mine = job->wideFill + ((size_t)vy * w + vx) * 3, *theirs = job->wideReal + ((size_t)cy * w + cx) * 3;
    double tr = mine[0] - theirs[0], tg = mine[1] - theirs[1], tb = mine[2] - theirs[2];
    far += TINT * (tr * tr + tg * tg + tb * tb);
    if (far >= limit) return limit;
    // (Shapes are compared in brightness alone; times three, to weigh as three colors' worth did.)
    double budget = (limit - far) * count / 3, sum = 0;
    for (int dy = y0; dy <= y1; dy += step) {
        const float *a = d->fillShape + (size_t)(vy + dy) * w + vx + x0;
        const float *b = d->realShape + (size_t)(cy + dy) * w + cx + x0;
        for (int dx = x0; dx <= x1; dx += step, a += step, b += step) {
            float difference = a[0] - b[0];
            sum += difference * difference;
        }
        if (sum >= budget) return limit;
    }
    return 3 * sum / count + far;
}

/// Finds one grid point's shift.
static void search_point(void *context, size_t index) {
    const search_job *job = context;
    iv_detail *d = job->d;
    int w = d->w, h = d->h, S = d->spacing;
    int gx = (int)(index % (size_t)d->gw), gy = (int)(index / (size_t)d->gw);
    int vx = clampi(gx * S, 0, w - 1), vy = clampi(gy * S, 0, h - 1);
    int16_t *shift = d->shift + index * 2;
    // Only points with something filled in around them need anywhere else to look.
    if (flagged(job->bare, w, h, vx - S, vy - S, vx + S, vy + S) == 0) { shift[0] = shift[1] = 0; return; }
    int coarse = S / 4 < 2 ? 2 : S / 4;
    double best = DBL_MAX;
    int bx = 0, by = 0, found = 0;
    for (int cy = coarse / 2; cy < h; cy += coarse) {
        for (int cx = coarse / 2; cx < w; cx += coarse) {
            double c = cost_at(job, vx, vy, cx, cy, best, NULL);
            if (c < best) { best = c; bx = cx; by = cy; found = 1; }
        }
    }
    if (!found) { shift[0] = shift[1] = SHRT_MIN; return; }
    int mx = bx, my = by;
    for (int cy = my - coarse + 1; cy < my + coarse; cy++) {
        for (int cx = mx - coarse + 1; cx < mx + coarse; cx++) {
            double c = cost_at(job, vx, vy, cx, cy, best, NULL);
            if (c < best) { best = c; bx = cx; by = cy; }
        }
    }
    shift[0] = (int16_t)clampi(bx - vx, SHRT_MIN + 1, SHRT_MAX);
    shift[1] = (int16_t)clampi(by - vy, SHRT_MIN + 1, SHRT_MAX);
}

void iv_detail_free(iv_detail *d) {
    if (!d) return;
    free(d->fill); free(d->real); free(d->mid); free(d->fillMid); free(d->fillEnergy); free(d->realEnergy); free(d->fillLevel); free(d->realLevel);
    free(d->fillShape); free(d->realShape); free(d->show); free(d->shift); free(d->usual);
    free(d);
}

iv_detail *iv_detail_make(const uint8_t *filling, const uint8_t *pictures, int w, int h, int band) {
    if (!filling || !pictures || w < 8 || h < 8) return NULL;
    size_t n = (size_t)w * h;
    iv_detail *d = calloc(1, sizeof(iv_detail));
    if (!d) return NULL;
    d->w = w; d->h = h;
    int shorter = w < h ? w : h;
    d->spacing = clampi((int)lround(shorter / 40.0), 10, 72);
    d->gw = (w - 1) / d->spacing + 2;
    d->gh = (h - 1) / d->spacing + 2;
    d->fill = malloc(n * 3); d->real = malloc(n * 3); d->mid = malloc(n * 3 * sizeof(int16_t));
    d->fillMid = malloc(n * 3 * sizeof(int16_t));
    d->fillEnergy = malloc(n * sizeof(float)); d->realEnergy = malloc(n * sizeof(float));
    d->fillLevel = malloc(n * sizeof(float)); d->realLevel = malloc(n * sizeof(float));
    d->fillShape = malloc(n * sizeof(float)); d->realShape = malloc(n * sizeof(float));
    d->show = malloc(n); d->shift = malloc((size_t)d->gw * d->gh * 2 * sizeof(int16_t));
    d->usual = calloc((size_t)d->gw * d->gh, sizeof(float));
    double *energySums = NULL, *squareSums = NULL;
    double *found = malloc((size_t)d->gw * d->gh * sizeof(double));
    uint8_t *bare = malloc(n), *open = malloc(n);
    float *a = malloc(n * 3 * sizeof(float)), *b = malloc(n * 3 * sizeof(float)), *soft = malloc(n * sizeof(float));
    uint32_t *bareSums = NULL, *openSums = NULL;
    int ok = d->fill && d->real && d->mid && d->fillMid && d->fillEnergy && d->realEnergy && d->fillLevel && d->realLevel && d->fillShape && d->realShape
        && d->show && d->shift && d->usual && found && bare && open && a && b && soft;
    if (ok) {
        for (size_t i = 0; i < n; i++) {
            bare[i] = pictures[i * 4 + 3] != 255;
            const uint8_t *p = bare[i] ? filling + i * 4 : pictures + i * 4;
            for (int c = 0; c < 3; c++) { d->fill[i * 3 + c] = filling[i * 4 + c]; d->real[i * 3 + c] = p[c]; }
        }
        bareSums = sums_of(bare, w, h);
        ok = bareSums != NULL;
    }
    // The pictures' texture at about this size, and how strong it is; then the filling's.
    if (ok) {
        for (size_t i = 0; i < n * 3; i++) a[i] = d->real[i];
        memcpy(b, a, n * 3 * sizeof(float));
        ok = box_blur(b, w, h, 3, MID_RADIUS, MID_PASSES);
        for (size_t i = 0; ok && i < n * 3; i++) { a[i] -= b[i]; d->mid[i] = (int16_t)lroundf(a[i] * 16); }
        ok = ok && energy_of(a, w, h, d->realEnergy);
    }
    if (ok) {
        for (size_t i = 0; i < n * 3; i++) a[i] = d->fill[i];
        memcpy(b, a, n * 3 * sizeof(float));
        ok = box_blur(b, w, h, 3, MID_RADIUS, MID_PASSES);
        for (size_t i = 0; ok && i < n * 3; i++) { a[i] -= b[i]; d->fillMid[i] = (int16_t)lroundf(a[i] * 16); }
        ok = ok && energy_of(a, w, h, d->fillEnergy);
    }
    // Where the pictures show: all of them but a band inside their edges, the edge of that softened.
    if (ok) {
        int inset = band * 3 / 5 < 1 ? 1 : band * 3 / 5, softness = band / 5;
        for (size_t i = 0; i < n; i++) {
            int x = (int)(i % (size_t)w), y = (int)(i / (size_t)w);
            soft[i] = flagged(bareSums, w, h, x - inset, y - inset, x + inset, y + inset) == 0 ? 255 : 0;
        }
        ok = box_blur(soft, w, h, 1, softness, 2);
        for (size_t i = 0; ok && i < n; i++) d->show[i] = bare[i] ? 0 : (uint8_t)lroundf(clampf(soft[i], 0, 255));
    }
    // What places are compared by: both blurred, so that it's their look and not their grain, and that parted
    // into their shapes and (blurred much wider) their color on the whole. A place texture can be taken from is
    // well inside the pictures (its blur is all theirs).
    if (ok) {
        for (size_t i = 0; i < n * 3; i++) { a[i] = d->fill[i]; b[i] = d->real[i]; }
        ok = box_blur(a, w, h, 3, 2, 3) && box_blur(b, w, h, 3, 2, 3);
        for (size_t i = 0; ok && i < n; i++) {
            d->fillLevel[i] = (a[i * 3] + 2 * a[i * 3 + 1] + a[i * 3 + 2]) * 0.25f;
            d->realLevel[i] = (b[i * 3] + 2 * b[i * 3 + 1] + b[i * 3 + 2]) * 0.25f;
        }
        if (ok) {
            memcpy(d->fillShape, d->fillLevel, n * sizeof(float));
            memcpy(d->realShape, d->realLevel, n * sizeof(float));
            ok = box_blur(d->fillShape, w, h, 1, d->spacing / 2, 2) && box_blur(d->realShape, w, h, 1, d->spacing / 2, 2);
            for (size_t i = 0; ok && i < n; i++) {
                d->fillShape[i] = d->fillLevel[i] - d->fillShape[i];
                d->realShape[i] = d->realLevel[i] - d->realShape[i];
            }
            ok = ok && box_blur(a, w, h, 3, d->spacing / 2, 2) && box_blur(b, w, h, 3, d->spacing / 2, 2);
        }
    }
    if (ok) {
        int margin = 6;
        for (size_t i = 0; i < n; i++) {
            int x = (int)(i % (size_t)w), y = (int)(i / (size_t)w);
            open[i] = flagged(bareSums, w, h, x - margin, y - margin, x + margin, y + margin) != 0;
        }
        openSums = sums_of(open, w, h);
        ok = openSums != NULL;
    }
    if (ok) {
        energySums = double_sums(d->realEnergy, w, h, 0);
        squareSums = double_sums(d->realEnergy, w, h, 1);
        ok = energySums && squareSums;
    }
    if (ok) {
        search_job job = { d, a, b, bareSums, openSums, energySums, squareSums, (double)w * w + (double)h * h };
        dispatch_apply_f((size_t)d->gw * d->gh, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), &job, search_point);
        // Neighbors that could as well share a shift do, the fewer giving way to the more: what's copied then
        // carries on unbroken across them, as whole stretches of the pictures' texture and not a patchwork.
        for (size_t i = 0; i < (size_t)d->gw * d->gh; i++) {
            const int16_t *mine = d->shift + i * 2;
            int vx = clampi((int)(i % (size_t)d->gw) * d->spacing, 0, w - 1), vy = clampi((int)(i / (size_t)d->gw) * d->spacing, 0, h - 1);
            found[i] = mine[0] == SHRT_MIN || (mine[0] == 0 && mine[1] == 0) ? -1 : cost_at(&job, vx, vy, vx + mine[0], vy + mine[1], DBL_MAX, NULL);
        }
        const int near[4][2] = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } };
        for (int pass = 0; pass < 6; pass++) {
            int changed = 0;
            for (int row = 0; row < d->gh; row++) {
                for (int column = 0; column < d->gw; column++) {
                    int gx = pass & 1 ? d->gw - 1 - column : column, gy = pass & 1 ? d->gh - 1 - row : row;
                    size_t at = (size_t)gy * d->gw + gx;
                    int16_t *mine = d->shift + at * 2;
                    if (found[at] < 0) continue;
                    int vx = clampi(gx * d->spacing, 0, w - 1), vy = clampi(gy * d->spacing, 0, h - 1);
                    int shifts[4][2], votes[4], kinds = 0, own = 0;
                    for (int k = 0; k < 4; k++) {
                        int nx = gx + near[k][0], ny = gy + near[k][1];
                        if (nx < 0 || ny < 0 || nx >= d->gw || ny >= d->gh || found[(size_t)ny * d->gw + nx] < 0) continue;
                        const int16_t *theirs = d->shift + ((size_t)ny * d->gw + nx) * 2;
                        if (theirs[0] == mine[0] && theirs[1] == mine[1]) { own++; continue; }
                        int same = -1;
                        for (int j = 0; j < kinds; j++) if (shifts[j][0] == theirs[0] && shifts[j][1] == theirs[1]) same = j;
                        if (same >= 0) { votes[same]++; continue; }
                        shifts[kinds][0] = theirs[0]; shifts[kinds][1] = theirs[1]; votes[kinds] = 1; kinds++;
                    }
                    double current = cost_at(&job, vx, vy, vx + mine[0], vy + mine[1], DBL_MAX, NULL), best = DBL_MAX;
                    int pick = -1;
                    for (int j = 0; j < kinds; j++) {
                        if (votes[j] < own) continue;
                        // (As good a match as its own best, or nearly: within a few levels of it.)
                        double c = cost_at(&job, vx, vy, vx + shifts[j][0], vy + shifts[j][1], found[at] * 1.5 + 12, NULL);
                        if (c >= found[at] * 1.5 + 12) continue;
                        if (votes[j] == own && c >= current) continue;
                        if (pick < 0 || votes[j] > votes[pick] || (votes[j] == votes[pick] && c < best)) { pick = j; best = c; }
                    }
                    if (pick >= 0) { mine[0] = (int16_t)shifts[pick][0]; mine[1] = (int16_t)shifts[pick][1]; changed++; }
                }
            }
            if (!changed) break;
        }
        for (size_t i = 0; i < (size_t)d->gw * d->gh; i++) {
            const int16_t *mine = d->shift + i * 2;
            if (found[i] < 0) continue;
            int vx = clampi((int)(i % (size_t)d->gw) * d->spacing, 0, w - 1), vy = clampi((int)(i / (size_t)d->gw) * d->spacing, 0, h - 1);
            double usual = 0;
            cost_at(&job, vx, vy, vx + mine[0], vy + mine[1], DBL_MAX, &usual);
            d->usual[i] = (float)usual;
        }
    }
    free(found); free(bare); free(open); free(a); free(b); free(soft); free(bareSums); free(openSums); free(energySums); free(squareSums);
    if (!ok) { iv_detail_free(d); return NULL; }
    return d;
}

void iv_detail_counts(const iv_detail *d, int *moved, int *none) {
    int m = 0, z = 0;
    if (d) {
        for (size_t i = 0; i < (size_t)d->gw * d->gh; i++) {
            if (d->shift[i * 2] == SHRT_MIN) z++;
            else if (d->shift[i * 2] != 0 || d->shift[i * 2 + 1] != 0) m++;
        }
    }
    if (moved) *moved = m;
    if (none) *none = z;
}

// MARK: - Finishing

/// Catmull-Rom weights for a point `t` of the way from the second of four samples to the third.
static inline void cubic_weights(float t, float w[4]) {
    float t2 = t * t, t3 = t2 * t;
    w[0] = -0.5f * t3 + t2 - 0.5f * t;
    w[1] = 1.5f * t3 - 2.5f * t2 + 1;
    w[2] = -1.5f * t3 + 2 * t2 + 0.5f * t;
    w[3] = 0.5f * t3 - 0.5f * t2;
}

/// `image` (w * h * 3) at (x, y), a pixel's middle at whole numbers.
static inline void sample_cubic(const uint8_t *image, int w, int h, double x, double y, float out[3]) {
    int x0 = (int)floor(x), y0 = (int)floor(y);
    float wx[4], wy[4];
    cubic_weights((float)(x - x0), wx);
    cubic_weights((float)(y - y0), wy);
    float sum[3] = { 0, 0, 0 };
    for (int j = 0; j < 4; j++) {
        const uint8_t *row = image + (size_t)clampi(y0 - 1 + j, 0, h - 1) * w * 3;
        float line[3] = { 0, 0, 0 };
        for (int i = 0; i < 4; i++) {
            const uint8_t *p = row + (size_t)clampi(x0 - 1 + i, 0, w - 1) * 3;
            line[0] += wx[i] * p[0]; line[1] += wx[i] * p[1]; line[2] += wx[i] * p[2];
        }
        sum[0] += wy[j] * line[0]; sum[1] += wy[j] * line[1]; sum[2] += wy[j] * line[2];
    }
    out[0] = sum[0]; out[1] = sum[1]; out[2] = sum[2];
}

static inline void sample_mid(const iv_detail *d, const int16_t *mid, double x, double y, float out[3]) {
    int x0 = (int)floor(x), y0 = (int)floor(y);
    float ax = (float)(x - x0), ay = (float)(y - y0);
    int xa = clampi(x0, 0, d->w - 1), xb = clampi(x0 + 1, 0, d->w - 1), ya = clampi(y0, 0, d->h - 1), yb = clampi(y0 + 1, 0, d->h - 1);
    const int16_t *p00 = mid + ((size_t)ya * d->w + xa) * 3, *p10 = mid + ((size_t)ya * d->w + xb) * 3;
    const int16_t *p01 = mid + ((size_t)yb * d->w + xa) * 3, *p11 = mid + ((size_t)yb * d->w + xb) * 3;
    for (int k = 0; k < 3; k++) {
        float top = p00[k] + (p10[k] - p00[k]) * ax, bottom = p01[k] + (p11[k] - p01[k]) * ax;
        out[k] = (top + (bottom - top) * ay) / 16;
    }
}

static inline float sample_show(const iv_detail *d, double x, double y) {
    int x0 = (int)floor(x), y0 = (int)floor(y);
    float ax = (float)(x - x0), ay = (float)(y - y0);
    int xa = clampi(x0, 0, d->w - 1), xb = clampi(x0 + 1, 0, d->w - 1), ya = clampi(y0, 0, d->h - 1), yb = clampi(y0 + 1, 0, d->h - 1);
    float top = d->show[(size_t)ya * d->w + xa] + (d->show[(size_t)ya * d->w + xb] - d->show[(size_t)ya * d->w + xa]) * ax;
    float bottom = d->show[(size_t)yb * d->w + xa] + (d->show[(size_t)yb * d->w + xb] - d->show[(size_t)yb * d->w + xa]) * ax;
    return (top + (bottom - top) * ay) / 255;
}

static inline float energy_at(const float *energy, const iv_detail *d, double x, double y) {
    int x0 = (int)floor(x), y0 = (int)floor(y);
    float ax = (float)(x - x0), ay = (float)(y - y0);
    int xa = clampi(x0, 0, d->w - 1), xb = clampi(x0 + 1, 0, d->w - 1), ya = clampi(y0, 0, d->h - 1), yb = clampi(y0 + 1, 0, d->h - 1);
    float top = energy[(size_t)ya * d->w + xa] + (energy[(size_t)ya * d->w + xb] - energy[(size_t)ya * d->w + xa]) * ax;
    float bottom = energy[(size_t)yb * d->w + xa] + (energy[(size_t)yb * d->w + xb] - energy[(size_t)yb * d->w + xa]) * ax;
    return top + (bottom - top) * ay;
}

typedef struct {
    const iv_detail *d;
    const uint8_t *top;
    uint8_t *out;
    int width, height, texture, firstRow;
    double scale, left, up;
} finish_job;

/// The pictures' detail at `top`'s pixel (qx, qy), for the filling at (px, py) (the filling's own pixels):
/// what they hold there beyond the filling's size, and their texture at about that size.
///
/// A pixel the pictures cover takes its own (`taken` 0), the second only as far as the filling lacks it. A
/// filled-in one takes another place's: their texture then stands in for the filling's own of that size
/// (`drop`: how much of its own to take out, 0...1), which enlarged is a smear beside theirs; unless the filling
/// has far more there than they do, which is a thing's edge and not its texture, and stays.
static inline void detail_at(const finish_job *job, int qx, int qy, double px, double py, int taken, float usual, float out[3], float *drop) {
    const iv_detail *d = job->d;
    double sx = (qx + 0.5 - job->left) / job->scale - 0.5, sy = (qy + 0.5 - job->up) / job->scale - 0.5;
    const uint8_t *full = job->top + ((size_t)qy * job->width + qx) * 4;
    float small[3], mid[3];
    sample_cubic(d->real, d->w, d->h, sx, sy, small);
    sample_mid(d, d->mid, sx, sy, mid);
    float theirs = energy_at(d->realEnergy, d, sx, sy), own = energy_at(d->fillEnergy, d, px, py);
    if (!taken) {
        float lack = theirs > 0.25f ? clampf(1 - own / theirs, 0, 1) : 0;
        for (int k = 0; k < 3; k++) out[k] = full[k] - small[k] + lack * mid[k];
        return;
    }
    // (Twice as strong as the place's texture is on the whole is a thing in it, a leaf or a painted line: turned
    // down, the more the stronger it is, so that it's texture that's taken and not things, copied.)
    float most = 2 * usual + 0.5f, plain = theirs > most ? (most / theirs) * (most / theirs) : 1;
    theirs *= plain;
    // (All of the filling's own goes while it's no more than half again as strong as theirs; none once it's three times.)
    float u = clampf((own / fmaxf(theirs, 0.5f) - 1.5f) / 1.5f, 0, 1), keep = u * u * (3 - 2 * u);
    // (Texture is as strong as what it's on is bright: taken to somewhere darker, it's turned down to suit.)
    float level = plain * clampf(energy_at(d->fillLevel, d, px, py) / fmaxf(energy_at(d->realLevel, d, sx, sy), 4), 0.2f, 1.25f);

    for (int k = 0; k < 3; k++) out[k] = level * (full[k] - small[k] + (1 - keep) * mid[k]);
    *drop = 1 - keep;
}

/// How far across a square of the grid (0...1) a pixel has gone over to the far side's point: all one point's
/// for most of the way, changing over in the middle.
static inline float handover(float t) {
    float u = clampf((t - 0.4f) / 0.2f, 0, 1);
    return u * u * (3 - 2 * u);
}

static void finish_row(void *context, size_t index) {
    const finish_job *job = context;
    const iv_detail *d = job->d;
    int y = job->firstRow + (int)index, S = d->spacing;
    const uint8_t *t = job->top + (size_t)y * job->width * 4;
    uint8_t *o = job->out + (size_t)y * job->width * 4;
    double py = (y + 0.5 - job->up) / job->scale - 0.5;
    for (int x = 0; x < job->width; x++, t += 4, o += 4) {
        double px = (x + 0.5 - job->left) / job->scale - 0.5;
        int covered = t[3] == 255;
        float show = covered ? sample_show(d, px, py) : 0;
        o[3] = 255;
        if (show >= 0.999f) { o[0] = t[0]; o[1] = t[1]; o[2] = t[2]; continue; }
        float under[3];
        sample_cubic(d->fill, d->w, d->h, px, py, under);
        if (job->texture) {
            float detail[3] = { 0, 0, 0 };
            if (covered) {
                float unused = 0;
                detail_at(job, x, y, px, py, 0, 0, detail, &unused);
            } else {
                // The four grid points around it: each one's shift leads to a place in the pictures.
                double fx = px / S, fy = py / S;
                int gx = clampi((int)floor(fx), 0, d->gw - 2), gy = clampi((int)floor(fy), 0, d->gh - 2);
                float ux = handover(clampf((float)(fx - gx), 0, 1)), uy = handover(clampf((float)(fy - gy), 0, 1));
                float weights[4] = { (1 - ux) * (1 - uy), ux * (1 - uy), (1 - ux) * uy, ux * uy };
                int qx[4], qy[4], count = 0;
                float share[4], usual[4];
                for (int k = 0; k < 4; k++) {
                    if (weights[k] <= 0) continue;
                    size_t point = (size_t)(gy + (k >> 1)) * d->gw + gx + (k & 1);
                    const int16_t *shift = d->shift + point * 2;
                    if (shift[0] == SHRT_MIN) continue;
                    int sx = x + (int)lround(shift[0] * job->scale), sy = y + (int)lround(shift[1] * job->scale);
                    if (sx < 0 || sy < 0 || sx >= job->width || sy >= job->height) continue;
                    if (job->top[((size_t)sy * job->width + sx) * 4 + 3] != 255) continue;
                    int same = -1;
                    for (int j = 0; j < count; j++) if (qx[j] == sx && qy[j] == sy) same = j;
                    if (same >= 0) { share[same] += weights[k]; continue; }
                    qx[count] = sx; qy[count] = sy; share[count] = weights[k]; usual[count] = d->usual[point]; count++;
                }
                // (Textures from different places are unrelated: mixed by their shares alone they'd cancel a
                // little and go flat where regions meet, so the mix is brought back to full strength.)
                float total = 0, squares = 0;
                for (int j = 0; j < count; j++) total += share[j];
                for (int j = 0; j < count; j++) { share[j] /= total; squares += share[j] * share[j]; }
                float drop = 0;
                for (int j = 0; j < count; j++) {
                    float one[3], dropped = 0;
                    detail_at(job, qx[j], qy[j], px, py, 1, usual[j], one, &dropped);
                    float s = share[j] / sqrtf(squares);
                    detail[0] += s * one[0]; detail[1] += s * one[1]; detail[2] += s * one[2];
                    drop += share[j] * dropped;
                }
                if (drop > 0) {
                    float own[3];
                    sample_mid(d, d->fillMid, px, py, own);
                    detail[0] -= drop * own[0]; detail[1] -= drop * own[1]; detail[2] -= drop * own[2];
                }
            }
            under[0] += detail[0]; under[1] += detail[1]; under[2] += detail[2];
        }
        for (int k = 0; k < 3; k++) {
            float v = covered ? under[k] + (t[k] - under[k]) * show : under[k];
            o[k] = (uint8_t)lroundf(clampf(v, 0, 255));
        }
    }
}

int iv_detail_finish(const iv_detail *d, const uint8_t *top, int topWidth, int topHeight, double scale, double left, double up,
                     int texture, uint8_t *out, iv_fill_progress progress, void *context) {
    if (!d || !top || !out || topWidth <= 0 || topHeight <= 0 || scale <= 0) return IV_FILL_BAD_INPUT;
    finish_job job = { d, top, out, topWidth, topHeight, texture, 0, scale, left, up };
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    enum { BAND = 64 };
    for (int y = 0; y < topHeight; y += BAND) {
        int rows = topHeight - y < BAND ? topHeight - y : BAND;
        job.firstRow = y;
        dispatch_apply_f((size_t)rows, queue, &job, finish_row);
        if (progress && progress(context, (double)(y + rows) / topHeight)) return IV_FILL_CANCELLED;
    }
    return IV_FILL_OK;
}
