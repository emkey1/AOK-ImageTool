#include "Stitch.h"

#include <dispatch/dispatch.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// Stitching pictures taken from one spot, the camera turned between them.
//
// Two such pictures of the same things differ by a homography (a 3 × 3 matrix taking one's pixels to the
// other's), whatever is in them and however far away. It's found from corners: each picture's are described by
// what's around them, a corner in one is paired with the corner most like it in the other, and the homography
// that most pairs agree on is taken (RANSAC: wrong pairs are common, and agree on nothing).
//
// The pictures are then looked at from one view, each through its own homography, and blended in two bands:
// broad light and color cross-fade over the whole overlap, which hides differences in exposure; detail comes
// from one picture at a time, which keeps it sharp and keeps things that moved from showing twice.

// MARK: - Small things

static inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

static uint64_t next_random(uint64_t *state) {
    uint64_t x = *state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    return *state = x;
}

static double unit_random(uint64_t *state) { return (double)(next_random(state) >> 11) / 9007199254740992.0; }

/// A Gaussian blur, edges extended. `tmp` is scratch of the same size; `src` and `dst` may be the same.
static void blur(const float *src, float *dst, float *tmp, int w, int h, float sigma) {
    int r = (int)ceilf(3 * sigma);
    float kernel[64], sum = 0;
    if (r > 31) r = 31;
    for (int i = -r; i <= r; i++) { kernel[i + r] = expf(-(float)(i * i) / (2 * sigma * sigma)); sum += kernel[i + r]; }
    for (int i = 0; i <= 2 * r; i++) kernel[i] /= sum;
    for (int y = 0; y < h; y++) {
        const float *row = src + (size_t)y * w;
        float *out = tmp + (size_t)y * w;
        for (int x = 0; x < w; x++) {
            float s = 0;
            if (x >= r && x + r < w) {
                for (int i = -r; i <= r; i++) s += kernel[i + r] * row[x + i];
            } else {
                for (int i = -r; i <= r; i++) s += kernel[i + r] * row[clampi(x + i, 0, w - 1)];
            }
            out[x] = s;
        }
    }
    for (int y = 0; y < h; y++) {
        float *out = dst + (size_t)y * w;
        memset(out, 0, sizeof(float) * (size_t)w);
        for (int i = -r; i <= r; i++) {
            const float *row = tmp + (size_t)clampi(y + i, 0, h - 1) * w;
            float k = kernel[i + r];
            for (int x = 0; x < w; x++) out[x] += k * row[x];
        }
    }
}

// MARK: - Corners

enum { MARGIN = 20, PER_CELL = 3, PAIRS = 256 };

/// The pairs of points a descriptor compares around its corner (x1, y1, x2, y2), the same every time.
static float pattern[PAIRS][4];

static void make_pattern(void *unused) {
    (void)unused;
    uint64_t state = 0x2545F4914F6CDD1DULL;
    for (int i = 0; i < PAIRS; i++) {
        for (int k = 0; k < 4; k++) {
            double g = sqrt(-2 * log(fmax(unit_random(&state), 1e-12))) * cos(2 * M_PI * unit_random(&state));
            pattern[i][k] = clampf((float)(g * 5.5), -13, 13);
        }
    }
}

typedef struct { float value; int x, y; } peak;

int iv_stitch_features(const uint8_t *gray, int w, int h, iv_feature *out, int capacity) {
    static dispatch_once_t once;
    dispatch_once_f(&once, NULL, make_pattern);
    if (!gray || !out || capacity <= 0 || w < 3 * MARGIN || h < 3 * MARGIN) return 0;
    size_t n = (size_t)w * h;
    float *g = malloc(sizeof(float) * n), *tmp = malloc(sizeof(float) * n), *soft = malloc(sizeof(float) * n);
    float *ixx = malloc(sizeof(float) * n), *iyy = malloc(sizeof(float) * n), *ixy = malloc(sizeof(float) * n);
    int cell = w > h ? w / 44 : h / 44;
    if (cell < 16) cell = 16;
    int cols = (w + cell - 1) / cell, rows = (h + cell - 1) / cell;
    peak *best = calloc((size_t)cols * rows * PER_CELL, sizeof(peak));
    int count = 0;
    if (!g || !tmp || !soft || !ixx || !iyy || !ixy || !best) goto done;

    for (size_t i = 0; i < n; i++) g[i] = gray[i] / 255.0f;
    blur(g, g, tmp, w, h, 1);
    blur(g, soft, tmp, w, h, 2);
    memset(ixx, 0, sizeof(float) * n); memset(iyy, 0, sizeof(float) * n); memset(ixy, 0, sizeof(float) * n);
    for (int y = 1; y < h - 1; y++) {
        for (int x = 1; x < w - 1; x++) {
            size_t i = (size_t)y * w + x;
            float gx = (g[i + 1] - g[i - 1]) * 0.5f, gy = (g[i + w] - g[i - w]) * 0.5f;
            ixx[i] = gx * gx; iyy[i] = gy * gy; ixy[i] = gx * gy;
        }
    }
    blur(ixx, ixx, tmp, w, h, 2); blur(iyy, iyy, tmp, w, h, 2); blur(ixy, ixy, tmp, w, h, 2);
    // Harris: how much the picture changes in every direction around a point (into `g`, no longer needed).
    float top = 0;
    for (size_t i = 0; i < n; i++) {
        float t = ixx[i] + iyy[i];
        g[i] = ixx[i] * iyy[i] - ixy[i] * ixy[i] - 0.05f * t * t;
        if (g[i] > top) top = g[i];
    }
    if (top <= 0) goto done;

    // The strongest few peaks in each cell.
    for (int y = MARGIN; y < h - MARGIN; y++) {
        for (int x = MARGIN; x < w - MARGIN; x++) {
            float v = g[(size_t)y * w + x];
            if (v <= top * 2e-5f) continue;
            int isPeak = 1;
            for (int dy = -2; dy <= 2 && isPeak; dy++) {
                const float *row = g + (size_t)(y + dy) * w + x;
                for (int dx = -2; dx <= 2; dx++) if (row[dx] > v) { isPeak = 0; break; }
            }
            if (!isPeak) continue;
            peak *list = best + ((size_t)(y / cell) * cols + x / cell) * PER_CELL;
            for (int k = 0; k < PER_CELL; k++) {
                if (v > list[k].value) {
                    for (int m = PER_CELL - 1; m > k; m--) list[m] = list[m - 1];
                    list[k] = (peak){ v, x, y };
                    break;
                }
            }
        }
    }

    for (int c = 0; c < cols * rows * PER_CELL && count < capacity; c++) {
        if (best[c].value <= 0) continue;
        int x = best[c].x, y = best[c].y;
        size_t i = (size_t)y * w + x;
        // Its direction: from its middle to where the light around it is weighted.
        float m10 = 0, m01 = 0;
        for (int dy = -12; dy <= 12; dy++) {
            for (int dx = -12; dx <= 12; dx++) {
                if (dx * dx + dy * dy > 144) continue;
                float v = soft[i + (ptrdiff_t)dy * w + dx];
                m10 += dx * v; m01 += dy * v;
            }
        }
        float angle = atan2f(m01, m10), ca = cosf(angle), sa = sinf(angle);
        iv_feature *f = out + count++;
        memset(f->bits, 0, sizeof(f->bits));
        for (int k = 0; k < PAIRS; k++) {
            const float *p = pattern[k];
            int x1 = x + (int)lroundf(p[0] * ca - p[1] * sa), y1 = y + (int)lroundf(p[0] * sa + p[1] * ca);
            int x2 = x + (int)lroundf(p[2] * ca - p[3] * sa), y2 = y + (int)lroundf(p[2] * sa + p[3] * ca);
            if (soft[(size_t)y1 * w + x1] < soft[(size_t)y2 * w + x2]) f->bits[k / 64] |= 1ULL << (k % 64);
        }
        // Where the peak is between pixels (a parabola through it and its neighbors each way).
        float cx = g[i], dx = 0, dy = 0;
        float ddx = g[i - 1] - 2 * cx + g[i + 1], ddy = g[i - w] - 2 * cx + g[i + w];
        if (ddx < 0) dx = clampf(0.5f * (g[i - 1] - g[i + 1]) / ddx, -0.5f, 0.5f);
        if (ddy < 0) dy = clampf(0.5f * (g[i - w] - g[i + w]) / ddy, -0.5f, 0.5f);
        f->x = x + 0.5f + dx; f->y = y + 0.5f + dy;
        f->level = soft[i];
    }

done:
    free(g); free(tmp); free(soft); free(ixx); free(iyy); free(ixy); free(best);
    return count;
}

// MARK: - The homography

static inline int distance(const iv_feature *a, const iv_feature *b) {
    return __builtin_popcountll(a->bits[0] ^ b->bits[0]) + __builtin_popcountll(a->bits[1] ^ b->bits[1])
         + __builtin_popcountll(a->bits[2] ^ b->bits[2]) + __builtin_popcountll(a->bits[3] ^ b->bits[3]);
}

/// For each of `from`, the nearest of `to` and how near it and the runner-up are.
static void nearest(const iv_feature *from, int nf, const iv_feature *to, int nt, int *index, int *first, int *second) {
    for (int i = 0; i < nf; i++) {
        int d1 = 1 << 20, d2 = 1 << 20, j1 = -1;
        for (int j = 0; j < nt; j++) {
            int d = distance(from + i, to + j);
            if (d < d1) { d2 = d1; d1 = d; j1 = j; } else if (d < d2) { d2 = d; }
        }
        index[i] = j1; first[i] = d1; second[i] = d2;
    }
}

static inline int project(const double *h, double x, double y, double *u, double *v) {
    double z = h[6] * x + h[7] * y + h[8];
    if (z <= 1e-12) return 0;
    *u = (h[0] * x + h[1] * y + h[2]) / z;
    *v = (h[3] * x + h[4] * y + h[5]) / z;
    return 1;
}

static void multiply(const double *a, const double *b, double *out) {
    double m[9];
    for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) m[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c];
    memcpy(out, m, sizeof(m));
}

static double determinant(const double *m) {
    return m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
}

static int invert(const double *m, double *out) {
    double d = determinant(m);
    if (fabs(d) < 1e-300) return 0;
    double r[9] = {
        (m[4] * m[8] - m[5] * m[7]) / d, (m[2] * m[7] - m[1] * m[8]) / d, (m[1] * m[5] - m[2] * m[4]) / d,
        (m[5] * m[6] - m[3] * m[8]) / d, (m[0] * m[8] - m[2] * m[6]) / d, (m[2] * m[3] - m[0] * m[5]) / d,
        (m[3] * m[7] - m[4] * m[6]) / d, (m[1] * m[6] - m[0] * m[7]) / d, (m[0] * m[4] - m[1] * m[3]) / d,
    };
    memcpy(out, r, sizeof(r));
    return 1;
}

/// Solves the 8 × 8 system a·x = b in place (Gaussian elimination, the largest pivot first).
static int solve8(double a[8][8], double b[8], double x[8]) {
    for (int c = 0; c < 8; c++) {
        int p = c;
        for (int r = c + 1; r < 8; r++) if (fabs(a[r][c]) > fabs(a[p][c])) p = r;
        if (fabs(a[p][c]) < 1e-12) return 0;
        if (p != c) {
            for (int k = 0; k < 8; k++) { double t = a[c][k]; a[c][k] = a[p][k]; a[p][k] = t; }
            double t = b[c]; b[c] = b[p]; b[p] = t;
        }
        for (int r = c + 1; r < 8; r++) {
            double f = a[r][c] / a[c][c];
            if (f == 0) continue;
            for (int k = c; k < 8; k++) a[r][k] -= f * a[c][k];
            b[r] -= f * b[c];
        }
    }
    for (int r = 7; r >= 0; r--) {
        double s = b[r];
        for (int k = r + 1; k < 8; k++) s -= a[r][k] * x[k];
        x[r] = s / a[r][r];
    }
    return 1;
}

/// The homography taking the `from` points onto the `to` points (least squares; four pairs or more, chosen by
/// `pick`), scaled so its determinant is 1. The points are centered and scaled first, which keeps the sums even.
static int fit(const double *from, const double *to, const int *pick, int n, double *h) {
    double fc[2] = { 0, 0 }, tc[2] = { 0, 0 }, fd = 0, td = 0;
    for (int i = 0; i < n; i++) {
        int k = pick[i];
        fc[0] += from[k * 2]; fc[1] += from[k * 2 + 1]; tc[0] += to[k * 2]; tc[1] += to[k * 2 + 1];
    }
    fc[0] /= n; fc[1] /= n; tc[0] /= n; tc[1] /= n;
    for (int i = 0; i < n; i++) {
        int k = pick[i];
        fd += hypot(from[k * 2] - fc[0], from[k * 2 + 1] - fc[1]);
        td += hypot(to[k * 2] - tc[0], to[k * 2 + 1] - tc[1]);
    }
    if (fd < 1e-9 || td < 1e-9) return 0;
    double fs = M_SQRT2 * n / fd, ts = M_SQRT2 * n / td;
    double a[8][8] = { { 0 } }, b[8] = { 0 }, s[8];
    for (int i = 0; i < n; i++) {
        int k = pick[i];
        double x = (from[k * 2] - fc[0]) * fs, y = (from[k * 2 + 1] - fc[1]) * fs;
        double u = (to[k * 2] - tc[0]) * ts, v = (to[k * 2 + 1] - tc[1]) * ts;
        double rows[2][8] = { { x, y, 1, 0, 0, 0, -u * x, -u * y }, { 0, 0, 0, x, y, 1, -v * x, -v * y } };
        double rhs[2] = { u, v };
        for (int e = 0; e < 2; e++) {
            for (int p = 0; p < 8; p++) {
                b[p] += rows[e][p] * rhs[e];
                for (int q = 0; q < 8; q++) a[p][q] += rows[e][p] * rows[e][q];
            }
        }
    }
    if (!solve8(a, b, s)) return 0;
    // Back from the centered, scaled points to pixels.
    double hn[9] = { s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], 1 };
    double tf[9] = { fs, 0, -fs * fc[0], 0, fs, -fs * fc[1], 0, 0, 1 };
    double ti[9] = { 1 / ts, 0, tc[0], 0, 1 / ts, tc[1], 0, 0, 1 };
    multiply(hn, tf, h);
    multiply(ti, h, h);
    double d = determinant(h);
    if (!isfinite(d) || fabs(d) < 1e-30) return 0;
    double scale = cbrt(d);
    for (int i = 0; i < 9; i++) h[i] /= scale;
    return 1;
}

static int agreeing(const double *h, const double *from, const double *to, int n, double tolerance, int *list) {
    int count = 0;
    double t2 = tolerance * tolerance;
    for (int i = 0; i < n; i++) {
        double u, v;
        if (!project(h, from[i * 2], from[i * 2 + 1], &u, &v)) continue;
        double dx = u - to[i * 2], dy = v - to[i * 2 + 1];
        if (dx * dx + dy * dy < t2) list[count++] = i;
    }
    return count;
}

static int compare_doubles(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

int iv_stitch_align(const iv_feature *a, int na, const iv_feature *b, int nb, double tolerance, uint64_t seed,
                    double h[9], int *matched, double *gain) {
    if (matched) *matched = 0;
    if (gain) *gain = 1;
    if (!a || !b || na < 12 || nb < 12) return 0;
    int *ab = malloc(sizeof(int) * (size_t)na * 3), *ba = malloc(sizeof(int) * (size_t)nb * 3);
    int limit = na < nb ? na : nb, result = 0;
    double *pa = malloc(sizeof(double) * (size_t)limit * 2), *pb = malloc(sizeof(double) * (size_t)limit * 2);
    double *ratios = malloc(sizeof(double) * (size_t)limit);
    int *pairA = malloc(sizeof(int) * (size_t)limit), *pairB = malloc(sizeof(int) * (size_t)limit);
    int *found = malloc(sizeof(int) * (size_t)limit), *best = malloc(sizeof(int) * (size_t)limit);
    if (!ab || !ba || !pa || !pb || !ratios || !pairA || !pairB || !found || !best) goto done;

    // Pairs that are each other's nearest, and clearly nearer than the runner-up.
    nearest(a, na, b, nb, ab, ab + na, ab + 2 * na);
    nearest(b, nb, a, na, ba, ba + nb, ba + 2 * nb);
    int m = 0;
    for (int i = 0; i < na && m < limit; i++) {
        int j = ab[i], d1 = ab[na + i], d2 = ab[2 * na + i];
        if (j < 0 || d1 > 70 || d1 >= 0.86 * d2 || ba[j] != i) continue;
        pa[m * 2] = a[i].x; pa[m * 2 + 1] = a[i].y; pb[m * 2] = b[j].x; pb[m * 2 + 1] = b[j].y;
        pairA[m] = i; pairB[m] = j;
        m++;
    }
    if (matched) *matched = m;
    if (m < 12) goto done;

    uint64_t state = seed ? seed : 0x9E3779B97F4A7C15ULL;
    int bestCount = 0, rounds = 4000;
    double candidate[9];
    for (int round = 0; round < rounds; round++) {
        int pick[4];
        for (int k = 0; k < 4; ) {
            int i = (int)(next_random(&state) % (uint64_t)m), again = 0;
            for (int e = 0; e < k; e++) if (pick[e] == i) again = 1;
            if (!again) pick[k++] = i;
        }
        if (!fit(pb, pa, pick, 4, candidate)) continue;
        int count = agreeing(candidate, pb, pa, m, tolerance, found);
        if (count > bestCount) {
            bestCount = count;
            memcpy(best, found, sizeof(int) * (size_t)count);
            // Enough rounds that one of them has very likely picked four right pairs.
            double share = (double)count / m, miss = 1 - share * share * share * share;
            if (miss < 1e-9) break;
            double needed = ceil(log(1e-4) / log(miss)) + 50;
            if (needed < rounds) rounds = needed > round + 1 ? (int)needed : round + 1;
        }
    }
    if (bestCount < 8 || !fit(pb, pa, best, bestCount, candidate)) goto done;
    for (int pass = 0; pass < 4; pass++) {
        int count = agreeing(candidate, pb, pa, m, tolerance, found);
        double refit[9];
        if (count < 8 || !fit(pb, pa, found, count, refit)) break;
        memcpy(candidate, refit, sizeof(refit));
        memcpy(best, found, sizeof(int) * (size_t)count);
        bestCount = count;
    }
    bestCount = agreeing(candidate, pb, pa, m, tolerance, best);
    if (bestCount < 8) goto done;
    memcpy(h, candidate, sizeof(candidate));
    for (int i = 0; i < bestCount; i++) {
        float la = a[pairA[best[i]]].level, lb = b[pairB[best[i]]].level;
        ratios[i] = lb / (la > 0.02f ? la : 0.02f);
    }
    qsort(ratios, (size_t)bestCount, sizeof(double), compare_doubles);
    if (gain) *gain = ratios[bestCount / 2];
    result = bestCount;

done:
    free(ab); free(ba); free(pa); free(pb); free(ratios); free(pairA); free(pairB); free(found); free(best);
    return result;
}

// MARK: - Laying the pictures in a view

void iv_stitch_low(const uint8_t *rgba, int w, int h, float *low, int lw, int lh) {
    if (!rgba || !low || w <= 0 || h <= 0 || lw <= 0 || lh <= 0) return;
    for (int ly = 0; ly < lh; ly++) {
        int y0 = (int)((int64_t)ly * h / lh), y1 = (int)((int64_t)(ly + 1) * h / lh);
        if (y1 <= y0) y1 = y0 + 1;
        for (int lx = 0; lx < lw; lx++) {
            int x0 = (int)((int64_t)lx * w / lw), x1 = (int)((int64_t)(lx + 1) * w / lw);
            if (x1 <= x0) x1 = x0 + 1;
            uint64_t sum[3] = { 0, 0, 0 };
            for (int y = y0; y < y1; y++) {
                const uint8_t *p = rgba + ((size_t)y * w + x0) * 4;
                for (int x = x0; x < x1; x++, p += 4) { sum[0] += p[0]; sum[1] += p[1]; sum[2] += p[2]; }
            }
            double count = (double)(x1 - x0) * (y1 - y0);
            float *o = low + ((size_t)ly * lw + lx) * 3;
            o[0] = (float)(sum[0] / count); o[1] = (float)(sum[1] / count); o[2] = (float)(sum[2] / count);
        }
    }
    // Twice [1 2 1] each way.
    float *tmp = malloc(sizeof(float) * (size_t)lw * lh * 3);
    if (!tmp) return;
    for (int pass = 0; pass < 2; pass++) {
        for (int y = 0; y < lh; y++) {
            for (int x = 0; x < lw; x++) {
                const float *l = low + ((size_t)y * lw + clampi(x - 1, 0, lw - 1)) * 3, *c = low + ((size_t)y * lw + x) * 3,
                            *r = low + ((size_t)y * lw + clampi(x + 1, 0, lw - 1)) * 3;
                float *o = tmp + ((size_t)y * lw + x) * 3;
                for (int k = 0; k < 3; k++) o[k] = 0.25f * l[k] + 0.5f * c[k] + 0.25f * r[k];
            }
        }
        for (int y = 0; y < lh; y++) {
            for (int x = 0; x < lw; x++) {
                const float *u = tmp + ((size_t)clampi(y - 1, 0, lh - 1) * lw + x) * 3, *c = tmp + ((size_t)y * lw + x) * 3,
                            *d = tmp + ((size_t)clampi(y + 1, 0, lh - 1) * lw + x) * 3;
                float *o = low + ((size_t)y * lw + x) * 3;
                for (int k = 0; k < 3; k++) o[k] = 0.25f * u[k] + 0.5f * c[k] + 0.25f * d[k];
            }
        }
    }
    free(tmp);
}

/// The direction seen at a point of the view (its pixels, the middle 0, 0).
static inline void view_ray(int projection, double scale, double px, double py, double ray[3]) {
    double u = px / scale, v = py / scale;
    switch (projection) {
    case IV_STITCH_CYLINDER:
        ray[0] = sin(u); ray[1] = v; ray[2] = cos(u);
        break;
    case IV_STITCH_SPHERE:
        ray[0] = sin(u) * cos(v); ray[1] = sin(v); ray[2] = cos(u) * cos(v);
        break;
    default:
        ray[0] = u; ray[1] = v; ray[2] = 1;
    }
}

/// Where a direction shows in the view (its pixels), or 0 if it's too far round to.
static inline int view_point(int projection, double scale, const double ray[3], double *px, double *py) {
    double x = ray[0], y = ray[1], z = ray[2], flat = hypot(x, z);
    switch (projection) {
    case IV_STITCH_CYLINDER: {
        double u = atan2(x, z);
        if (flat < 1e-12 || fabs(u) > 175 * M_PI / 180 || fabs(y) > 3.73 * flat) return 0;
        *px = u * scale; *py = y / flat * scale;
        return 1;
    }
    case IV_STITCH_SPHERE: {
        double u = atan2(x, z), v = atan2(y, flat);
        if (fabs(u) > 175 * M_PI / 180 || fabs(v) > 88 * M_PI / 180) return 0;
        *px = u * scale; *py = v * scale;
        return 1;
    }
    default:
        // (No further than about 72° off the middle: beyond, a flat view stretches without end.)
        if (z <= 1e-12 || hypot(x, y) > 3.08 * z) return 0;
        *px = x / z * scale; *py = y / z * scale;
        return 1;
    }
}

int iv_stitch_bounds(const iv_stitch_source *sources, int count, int projection, double scale, double bounds[4], int *trimmed) {
    double lo[2] = { INFINITY, INFINITY }, hi[2] = { -INFINITY, -INFINITY };
    int cut = 0, any = 0;
    enum { STEPS = 96 };
    for (int s = 0; s < count; s++) {
        double back[9];
        if (!invert(sources[s].toSource, back)) continue;
        for (int iy = 0; iy <= STEPS; iy++) {
            for (int ix = 0; ix <= STEPS; ix++) {
                double x = (double)ix / STEPS * sources[s].width, y = (double)iy / STEPS * sources[s].height;
                double ray[3] = { back[0] * x + back[1] * y + back[2], back[3] * x + back[4] * y + back[5], back[6] * x + back[7] * y + back[8] };
                double px, py;
                if (!view_point(projection, scale, ray, &px, &py)) { cut = 1; continue; }
                if (px < lo[0]) lo[0] = px;
                if (py < lo[1]) lo[1] = py;
                if (px > hi[0]) hi[0] = px;
                if (py > hi[1]) hi[1] = py;
                any = 1;
            }
        }
    }
    if (trimmed) *trimmed = cut;
    if (!any) return 0;
    bounds[0] = lo[0]; bounds[1] = lo[1]; bounds[2] = hi[0]; bounds[3] = hi[1];
    return 1;
}

static inline void sample_near(const iv_stitch_source *s, double sx, double sy, float out[3]) {
    double fx = sx - 0.5, fy = sy - 0.5;
    int x0 = (int)floor(fx), y0 = (int)floor(fy);
    float ax = (float)(fx - x0), ay = (float)(fy - y0);
    int xa = clampi(x0, 0, s->width - 1), xb = clampi(x0 + 1, 0, s->width - 1);
    int ya = clampi(y0, 0, s->height - 1), yb = clampi(y0 + 1, 0, s->height - 1);
    const uint8_t *p00 = s->rgba + ((size_t)ya * s->width + xa) * 4, *p10 = s->rgba + ((size_t)ya * s->width + xb) * 4;
    const uint8_t *p01 = s->rgba + ((size_t)yb * s->width + xa) * 4, *p11 = s->rgba + ((size_t)yb * s->width + xb) * 4;
    for (int k = 0; k < 3; k++) {
        float top = p00[k] + (p10[k] - p00[k]) * ax, bottom = p01[k] + (p11[k] - p01[k]) * ax;
        out[k] = top + (bottom - top) * ay;
    }
}

/// Catmull-Rom weights for a point `t` of the way from the second of four samples to the third.
static inline void cubic_weights(float t, float w[4]) {
    float t2 = t * t, t3 = t2 * t;
    w[0] = -0.5f * t3 + t2 - 0.5f * t;
    w[1] = 1.5f * t3 - 2.5f * t2 + 1;
    w[2] = -1.5f * t3 + 2 * t2 + 0.5f * t;
    w[3] = 0.5f * t3 - 0.5f * t2;
}

static inline void sample_sharp(const iv_stitch_source *s, double sx, double sy, float out[3]) {
    double fx = sx - 0.5, fy = sy - 0.5;
    int x0 = (int)floor(fx), y0 = (int)floor(fy);
    float wx[4], wy[4];
    cubic_weights((float)(fx - x0), wx);
    cubic_weights((float)(fy - y0), wy);
    float sum[3] = { 0, 0, 0 };
    for (int j = 0; j < 4; j++) {
        const uint8_t *row = s->rgba + (size_t)clampi(y0 - 1 + j, 0, s->height - 1) * s->width * 4;
        float line[3] = { 0, 0, 0 };
        for (int i = 0; i < 4; i++) {
            const uint8_t *p = row + (size_t)clampi(x0 - 1 + i, 0, s->width - 1) * 4;
            line[0] += wx[i] * p[0]; line[1] += wx[i] * p[1]; line[2] += wx[i] * p[2];
        }
        sum[0] += wy[j] * line[0]; sum[1] += wy[j] * line[1]; sum[2] += wy[j] * line[2];
    }
    out[0] = sum[0]; out[1] = sum[1]; out[2] = sum[2];
}

static inline void sample_low(const iv_stitch_source *s, double sx, double sy, float out[3]) {
    double fx = sx * s->lowWidth / s->width - 0.5, fy = sy * s->lowHeight / s->height - 0.5;
    int x0 = (int)floor(fx), y0 = (int)floor(fy);
    float ax = (float)(fx - x0), ay = (float)(fy - y0);
    int xa = clampi(x0, 0, s->lowWidth - 1), xb = clampi(x0 + 1, 0, s->lowWidth - 1);
    int ya = clampi(y0, 0, s->lowHeight - 1), yb = clampi(y0 + 1, 0, s->lowHeight - 1);
    const float *p00 = s->low + ((size_t)ya * s->lowWidth + xa) * 3, *p10 = s->low + ((size_t)ya * s->lowWidth + xb) * 3;
    const float *p01 = s->low + ((size_t)yb * s->lowWidth + xa) * 3, *p11 = s->low + ((size_t)yb * s->lowWidth + xb) * 3;
    for (int k = 0; k < 3; k++) {
        float top = p00[k] + (p10[k] - p00[k]) * ax, bottom = p01[k] + (p11[k] - p01[k]) * ax;
        out[k] = top + (bottom - top) * ay;
    }
}

typedef struct {
    const iv_stitch_source *sources;
    int count;
    iv_stitch_view view;
    uint8_t *out;
    int width, quality, firstRow;
} render_job;

static void render_row(void *context, size_t index) {
    const render_job *job = context;
    int y = job->firstRow + (int)index;
    uint8_t *o = job->out + (size_t)y * job->width * 4;
    for (int x = 0; x < job->width; x++, o += 4) {
        double ray[3];
        view_ray(job->view.projection, job->view.scale, x + 0.5 + job->view.left, y + 0.5 + job->view.top, ray);
        // (Doubles: a weight goes down to 1e-4, whose 16th power is nothing at all as a float, and a picture's
        // outermost pixels, where no other picture covers, came out black.)
        double low[3] = { 0, 0, 0 }, high[3] = { 0, 0, 0 }, broad = 0, sharp = 0;
        for (int i = 0; i < job->count; i++) {
            const iv_stitch_source *s = job->sources + i;
            const double *m = s->toSource;
            double z = m[6] * ray[0] + m[7] * ray[1] + m[8] * ray[2];
            if (z <= 1e-12) continue;
            double sx = (m[0] * ray[0] + m[1] * ray[1] + m[2] * ray[2]) / z, sy = (m[3] * ray[0] + m[4] * ray[1] + m[5] * ray[2]) / z;
            if (sx < 0 || sy < 0 || sx > s->width || sy > s->height) continue;
            // A picture counts for more toward its middle than at its edges.
            double edge = fmin(fmin(sx, s->width - sx), fmin(sy, s->height - sy)) / (0.5 * (s->width < s->height ? s->width : s->height));
            double w = edge < 1e-4 ? 1e-4 : edge > 1 ? 1 : edge;
            double w2 = w * w, w4 = w2 * w2, w8 = w4 * w4, w16 = w8 * w8;
            float color[3], soft[3];
            if (job->quality > 0) sample_sharp(s, sx, sy, color); else sample_near(s, sx, sy, color);
            sample_low(s, sx, sy, soft);
            for (int k = 0; k < 3; k++) {
                low[k] += w * soft[k] * s->gain;
                high[k] += w16 * (color[k] - soft[k]) * s->gain;
            }
            broad += w; sharp += w16;
        }
        if (broad <= 0) { o[0] = o[1] = o[2] = o[3] = 0; continue; }
        for (int k = 0; k < 3; k++) {
            double v = low[k] / broad + (sharp > 0 ? high[k] / sharp : 0);
            o[k] = (uint8_t)lround(v < 0 ? 0 : v > 255 ? 255 : v);
        }
        o[3] = 255;
    }
}

int iv_stitch_render(const iv_stitch_source *sources, int count, const iv_stitch_view *view, uint8_t *out, int width, int height,
                     int quality, iv_fill_progress progress, void *context) {
    if (!sources || !view || !out || count <= 0 || width <= 0 || height <= 0 || view->scale <= 0) return IV_FILL_BAD_INPUT;
    for (int i = 0; i < count; i++) {
        if (!sources[i].rgba || !sources[i].low || sources[i].width <= 0 || sources[i].height <= 0
            || sources[i].lowWidth <= 0 || sources[i].lowHeight <= 0) return IV_FILL_BAD_INPUT;
    }
    render_job job = { sources, count, *view, out, width, quality, 0 };
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    enum { BAND = 64 };
    for (int y = 0; y < height; y += BAND) {
        int rows = height - y < BAND ? height - y : BAND;
        job.firstRow = y;
        dispatch_apply_f((size_t)rows, queue, &job, render_row);
        if (progress && progress(context, (double)(y + rows) / height)) return IV_FILL_CANCELLED;
    }
    return IV_FILL_OK;
}

// MARK: - The part that's covered

int iv_stitch_covered_rect(const uint8_t *rgba, int w, int h, int rect[4]) {
    if (!rgba || w <= 0 || h <= 0) return 0;
    int *heights = calloc((size_t)w + 1, sizeof(int)), *stack = malloc(sizeof(int) * ((size_t)w + 1));
    int64_t best = 0;
    if (!heights || !stack) { free(heights); free(stack); return 0; }
    for (int y = 0; y < h; y++) {
        const uint8_t *row = rgba + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) heights[x] = row[x * 4 + 3] == 255 ? heights[x] + 1 : 0;
        // The largest rectangle under this row's skyline (each column's run of covered pixels up to here).
        int top = 0;
        for (int x = 0; x <= w; x++) {
            int height = x < w ? heights[x] : 0;
            while (top > 0 && heights[stack[top - 1]] >= height) {
                int tall = heights[stack[--top]];
                int left = top > 0 ? stack[top - 1] + 1 : 0;
                int64_t area = (int64_t)tall * (x - left);
                if (area > best) {
                    best = area;
                    rect[0] = left; rect[1] = y - tall + 1; rect[2] = x - left; rect[3] = tall;
                }
            }
            stack[top++] = x;
        }
    }
    free(heights); free(stack);
    return best > 0;
}
