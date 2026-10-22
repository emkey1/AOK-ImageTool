// Content-aware fill for extending (outpainting) and healing images.
//
// Coarse to fine:
//   1. At the coarsest pyramid level, unknown pixels are synthesized one at a time in order of distance
//      from the known region (closest first). Each takes the known pixel whose neighborhood best matches
//      its already-filled neighbors, considering "coherent" candidates (continuing where a neighbor's
//      source came from) and random ones (after P. Harrison's texture resynthesis).
//   2. Each finer level inherits the coarse correspondences, then refines them with PatchMatch-style
//      propagation and random search (Barnes et al.), comparing full neighborhoods.
// Pixels are always copied from the original rather than averaged, so fills stay sharp.
//
// Compiled with optimization in every configuration (see GCC_OPTIMIZATION_LEVEL); it's hot code.

#include "ContentAwareFill.h"

#include <dispatch/dispatch.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#define MAX_LEVELS 7
#define SRC_RADIUS 3            // a source patch center needs this many known pixels around it
#define GATHER_RADIUS 3         // neighborhood used while growing the coarsest level
#define GATHER_MAX 24
#define GROW_RANDOM_TRIES 32
#define REFINE_RADIUS 2         // 5x5 neighborhoods while refining
#define REFINE_GLOBAL_TRIES 3

typedef struct {
    int w, h;
    uint8_t *rgb;       // 4 bytes per pixel (alpha unused)
    uint8_t *known;
    uint8_t *avoid;     // may be NULL
    uint8_t *usable;    // valid patch center to copy from
    int32_t *nnf;       // source pixel index (known pixels point at themselves)
    int32_t *sources;
    int nsources;
    int32_t *unknown;   // indices of pixels to fill
    int nunknown;
} Level;

// ---------------------------------------------------------------------------------------------- helpers

static inline uint64_t mix64(uint64_t x) {
    x += 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    return x ^ (x >> 31);
}

static inline uint64_t hash3(uint64_t seed, uint64_t a, uint64_t b) {
    return mix64(seed ^ mix64(a * 0xD6E8FEB86659FD93ULL ^ mix64(b + 0x2545F4914F6CDD1DULL)));
}

static inline int ssd(const uint8_t *a, const uint8_t *b) {
    int dr = (int)a[0] - (int)b[0], dg = (int)a[1] - (int)b[1], db = (int)a[2] - (int)b[2];
    return dr * dr + dg * dg + db * db;
}

static void free_level(Level *L) {
    free(L->rgb); free(L->known); free(L->avoid); free(L->usable);
    free(L->nnf); free(L->sources); free(L->unknown);
    memset(L, 0, sizeof(*L));
}

/// A pixel can be copied from when it and everything within SRC_RADIUS is known (and not avoided).
static void build_usable(Level *L, int useAvoid) {
    const int w = L->w, h = L->h, R = SRC_RADIUS;
    free(L->usable); free(L->sources);
    L->usable = calloc((size_t)w * h, 1);
    L->sources = malloc(sizeof(int32_t) * (size_t)w * h);
    L->nsources = 0;
    // Summed-area table of "bad" pixels.
    int32_t *sat = calloc((size_t)(w + 1) * (h + 1), sizeof(int32_t));
    for (int y = 0; y < h; y++) {
        int32_t row = 0;
        for (int x = 0; x < w; x++) {
            int i = y * w + x;
            int bad = !L->known[i] || (useAvoid && L->avoid && L->avoid[i]);
            row += bad;
            sat[(y + 1) * (w + 1) + (x + 1)] = sat[y * (w + 1) + (x + 1)] + row;
        }
    }
    for (int y = R; y < h - R; y++) {
        for (int x = R; x < w - R; x++) {
            int x0 = x - R, y0 = y - R, x1 = x + R + 1, y1 = y + R + 1;
            int32_t bad = sat[y1 * (w + 1) + x1] - sat[y0 * (w + 1) + x1] - sat[y1 * (w + 1) + x0] + sat[y0 * (w + 1) + x0];
            if (bad == 0) {
                int i = y * w + x;
                L->usable[i] = 1;
                L->sources[L->nsources++] = i;
            }
        }
    }
    free(sat);
}

static void collect_unknown(Level *L) {
    const int n = L->w * L->h;
    free(L->unknown);
    L->unknown = malloc(sizeof(int32_t) * (size_t)(n > 0 ? n : 1));
    L->nunknown = 0;
    for (int i = 0; i < n; i++) if (!L->known[i]) L->unknown[L->nunknown++] = i;
}

/// Half-size level. A coarse pixel is known only if all its children are; it averages its known children.
static int downsample(const Level *F, Level *C) {
    const int fw = F->w, fh = F->h, cw = (fw + 1) / 2, ch = (fh + 1) / 2;
    C->w = cw; C->h = ch;
    C->rgb = calloc((size_t)cw * ch * 4, 1);
    C->known = calloc((size_t)cw * ch, 1);
    C->avoid = F->avoid ? calloc((size_t)cw * ch, 1) : NULL;
    C->nnf = malloc(sizeof(int32_t) * (size_t)cw * ch);
    if (!C->rgb || !C->known || !C->nnf || (F->avoid && !C->avoid)) return 0;
    for (int y = 0; y < ch; y++) {
        for (int x = 0; x < cw; x++) {
            int sum[3] = {0, 0, 0}, count = 0, total = 0, avoid = 0;
            for (int dy = 0; dy < 2; dy++) {
                for (int dx = 0; dx < 2; dx++) {
                    int fx = 2 * x + dx, fy = 2 * y + dy;
                    if (fx >= fw || fy >= fh) continue;
                    int fi = fy * fw + fx;
                    total++;
                    if (F->known[fi]) {
                        count++;
                        for (int c = 0; c < 3; c++) sum[c] += F->rgb[fi * 4 + c];
                    }
                    if (F->avoid && F->avoid[fi]) avoid = 1;
                }
            }
            int ci = y * cw + x;
            C->known[ci] = (count == total);
            if (count > 0) for (int c = 0; c < 3; c++) C->rgb[ci * 4 + c] = (uint8_t)((sum[c] + count / 2) / count);
            if (C->avoid) C->avoid[ci] = (uint8_t)avoid;
            C->nnf[ci] = ci;
        }
    }
    return 1;
}

// ------------------------------------------------------------------------------- coarsest: grow outward

typedef struct { int dx, dy, d2; } Offset;

static int cmp_offset(const void *a, const void *b) {
    const Offset *p = a, *q = b;
    return p->d2 - q->d2;
}

static int grow(Level *L, uint64_t seed, iv_fill_progress progress, void *context, double base, double span) {
    const int w = L->w, h = L->h, n = w * h;
    // Order: by 8-connected distance from the known region, shuffled within each distance.
    int32_t *dist = malloc(sizeof(int32_t) * (size_t)n);
    int32_t *queue = malloc(sizeof(int32_t) * (size_t)n);
    uint8_t *filled = malloc((size_t)n);
    if (!dist || !queue || !filled) { free(dist); free(queue); free(filled); return IV_FILL_BAD_INPUT; }
    int head = 0, tail = 0, maxDist = 0;
    for (int i = 0; i < n; i++) {
        filled[i] = L->known[i] ? 1 : 0;
        dist[i] = L->known[i] ? 0 : -1;
        if (L->known[i]) queue[tail++] = i;
    }
    while (head < tail) {
        int i = queue[head++], x = i % w, y = i / w;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            int nx = x + dx, ny = y + dy;
            if ((dx | dy) == 0 || nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            int j = ny * w + nx;
            if (dist[j] < 0) {
                dist[j] = dist[i] + 1;
                if (dist[j] > maxDist) maxDist = dist[j];
                queue[tail++] = j;
            }
        }
    }
    // Counting sort of unknown pixels by distance, then shuffle each bucket.
    int32_t *bucketStart = calloc((size_t)maxDist + 2, sizeof(int32_t));
    int32_t *order = malloc(sizeof(int32_t) * (size_t)(L->nunknown > 0 ? L->nunknown : 1));
    for (int k = 0; k < L->nunknown; k++) {
        int d = dist[L->unknown[k]];
        bucketStart[(d < 0 ? maxDist + 1 : d)]++;
    }
    int running = 0;
    for (int d = 0; d <= maxDist + 1; d++) { int c = bucketStart[d]; bucketStart[d] = running; running += c; }
    int32_t *cursor = malloc(sizeof(int32_t) * ((size_t)maxDist + 2));
    memcpy(cursor, bucketStart, sizeof(int32_t) * ((size_t)maxDist + 2));
    for (int k = 0; k < L->nunknown; k++) {
        int d = dist[L->unknown[k]];
        order[cursor[(d < 0 ? maxDist + 1 : d)]++] = L->unknown[k];
    }
    uint64_t rng = mix64(seed ^ 0xA5A5A5A5ULL);
    for (int d = 0; d <= maxDist + 1; d++) {
        int s = bucketStart[d], e = (d == maxDist + 1) ? L->nunknown : bucketStart[d + 1];
        for (int k = e - 1; k > s; k--) {
            rng = mix64(rng);
            int j = s + (int)(rng % (uint64_t)(k - s + 1));
            int32_t t = order[k]; order[k] = order[j]; order[j] = t;
        }
    }
    free(cursor); free(bucketStart); free(queue); free(dist);

    // Neighborhood offsets, nearest first.
    Offset offs[(2 * GATHER_RADIUS + 1) * (2 * GATHER_RADIUS + 1)];
    int noffs = 0;
    for (int dy = -GATHER_RADIUS; dy <= GATHER_RADIUS; dy++) for (int dx = -GATHER_RADIUS; dx <= GATHER_RADIUS; dx++) {
        if ((dx | dy) == 0) continue;
        offs[noffs++] = (Offset){dx, dy, dx * dx + dy * dy};
    }
    qsort(offs, (size_t)noffs, sizeof(Offset), cmp_offset);

    int gdx[GATHER_MAX], gdy[GATHER_MAX], gw[GATHER_MAX];
    for (int k = 0; k < L->nunknown; k++) {
        const int p = order[k], px = p % w, py = p / w;
        int ng = 0;
        for (int o = 0; o < noffs && ng < GATHER_MAX; o++) {
            int qx = px + offs[o].dx, qy = py + offs[o].dy;
            if (qx < 0 || qy < 0 || qx >= w || qy >= h) continue;
            int q = qy * w + qx;
            if (!filled[q]) continue;
            gdx[ng] = offs[o].dx; gdy[ng] = offs[o].dy; gw[ng] = L->known[q] ? 2 : 1;
            ng++;
        }
        int best = -1;
        long bestCost = LONG_MAX;
#define EVAL(cand) do { \
            int c_ = (cand); \
            if (c_ >= 0 && L->usable[c_] && c_ != best) { \
                int cx_ = c_ % w, cy_ = c_ / w; long cost_ = 0; \
                for (int g_ = 0; g_ < ng && cost_ < bestCost; g_++) { \
                    cost_ += (long)gw[g_] * ssd(&L->rgb[((py + gdy[g_]) * w + px + gdx[g_]) * 4], \
                                                &L->rgb[((cy_ + gdy[g_]) * w + cx_ + gdx[g_]) * 4]); \
                } \
                if (cost_ < bestCost) { bestCost = cost_; best = c_; } \
            } \
        } while (0)
        // Coherent candidates: continue each filled neighbor's source.
        for (int g = 0; g < ng; g++) {
            int q = (py + gdy[g]) * w + px + gdx[g];
            int s = L->nnf[q], sx = s % w - gdx[g], sy = s / w - gdy[g];
            if (sx >= 0 && sy >= 0 && sx < w && sy < h) EVAL(sy * w + sx);
        }
        // Inward candidates: the texture just inside the original, behind each original neighbor (a white
        // background corner continues as white even when it's only a few pixels at this scale).
        for (int g = 0; g < ng && g < 8; g++) {
            int q = (py + gdy[g]) * w + px + gdx[g];
            if (!L->known[q]) continue;
            for (int step = SRC_RADIUS + 1; step <= 4 * (SRC_RADIUS + 1); step *= 2) {
                int cx = px + gdx[g] * step, cy = py + gdy[g] * step;
                if (cx >= 0 && cy >= 0 && cx < w && cy < h) EVAL(cy * w + cx);
            }
        }
        for (int t = 0; t < GROW_RANDOM_TRIES; t++) {
            EVAL(L->sources[hash3(seed, (uint64_t)p, (uint64_t)t) % (uint64_t)L->nsources]);
        }
        // Shrinking random search around the best so far, and around p itself: p sits next to the known
        // texture it should continue, which neighbors that are original pixels can't point to.
        {
            const int maxSearch = (w > h ? w : h) / 2;
            int t = 0;
            for (int r = maxSearch; r >= 1; r /= 2, t++) {
                if (best >= 0) {
                    uint64_t z = hash3(seed, (uint64_t)p, (uint64_t)(200 + t));
                    int bx = best % w + (int)(z % (uint64_t)(2 * r + 1)) - r;
                    int by = best / w + (int)((z >> 32) % (uint64_t)(2 * r + 1)) - r;
                    if (bx >= 0 && by >= 0 && bx < w && by < h) EVAL(by * w + bx);
                }
                uint64_t z2 = hash3(seed, (uint64_t)p, (uint64_t)(300 + t));
                int lx = px + (int)(z2 % (uint64_t)(2 * r + 1)) - r;
                int ly = py + (int)((z2 >> 32) % (uint64_t)(2 * r + 1)) - r;
                if (lx >= 0 && ly >= 0 && lx < w && ly < h) EVAL(ly * w + lx);
            }
        }
#undef EVAL
        if (best < 0) best = L->sources[hash3(seed, (uint64_t)p, 999) % (uint64_t)L->nsources];
        L->nnf[p] = best;
        memcpy(&L->rgb[p * 4], &L->rgb[best * 4], 3);
        filled[p] = 1;
        if (progress && (k & 4095) == 4095) {
            if (progress(context, base + span * (double)k / (double)L->nunknown)) { free(order); free(filled); return IV_FILL_CANCELLED; }
        }
    }
    free(order);
    free(filled);
    return IV_FILL_OK;
}

// ------------------------------------------------------------------- finer levels: inherit and refine

static void upsample(const Level *C, Level *F) {
    const int cw = C->w, fw = F->w, fh = F->h;
    for (int k = 0; k < F->nunknown; k++) {
        int p = F->unknown[k], x = p % fw, y = p / fw;
        int cx = x / 2, cy = y / 2;
        if (cx >= cw) cx = cw - 1;
        if (cy >= C->h) cy = C->h - 1;
        int s = C->nnf[cy * cw + cx];
        int fx = 2 * (s % cw) + (x & 1), fy = 2 * (s / cw) + (y & 1);
        if (fx >= fw) fx = fw - 1;
        if (fy >= fh) fy = fh - 1;
        int c = fy * fw + fx;
        if (!F->usable[c]) {
            // Nearest usable pixel nearby, else any source.
            int found = -1;
            for (int r = 1; r <= 4 && found < 0; r++) {
                for (int dy = -r; dy <= r && found < 0; dy++) for (int dx = -r; dx <= r; dx++) {
                    int nx = fx + dx, ny = fy + dy;
                    if (nx < 0 || ny < 0 || nx >= fw || ny >= fh) continue;
                    if (F->usable[ny * fw + nx]) { found = ny * fw + nx; break; }
                }
            }
            c = found >= 0 ? found : F->sources[(uint64_t)mix64((uint64_t)p) % (uint64_t)F->nsources];
        }
        F->nnf[p] = c;
        memcpy(&F->rgb[p * 4], &F->rgb[c * 4], 3);
    }
}

typedef struct {
    const Level *L;
    const uint8_t *rgbIn;
    const int32_t *nnfIn;
    uint8_t *rgbOut;
    int32_t *nnfOut;
    uint64_t seed;
    int chunk;
} RefineJob;

static void refine_chunk(void *ctx, size_t index) {
    const RefineJob *J = ctx;
    const Level *L = J->L;
    const int w = L->w, h = L->h, R = REFINE_RADIUS;
    const int start = (int)index * J->chunk;
    const int end = start + J->chunk < L->nunknown ? start + J->chunk : L->nunknown;
    const int maxSearch = (w > h ? w : h) / 2;
    for (int k = start; k < end; k++) {
        const int p = L->unknown[k], px = p % w, py = p / w;
        int best = J->nnfIn[p];
        long bestCost = LONG_MAX;
#define COST(cand, out) do { \
            int cx_ = (cand) % w, cy_ = (cand) / w; long cost_ = 0; \
            for (int dy_ = -R; dy_ <= R && cost_ < bestCost; dy_++) { \
                int ty_ = py + dy_; if (ty_ < 0 || ty_ >= h) continue; \
                for (int dx_ = -R; dx_ <= R; dx_++) { \
                    int tx_ = px + dx_; if ((dx_ | dy_) == 0 || tx_ < 0 || tx_ >= w) continue; \
                    int t_ = ty_ * w + tx_; \
                    cost_ += (long)(L->known[t_] ? 2 : 1) * ssd(&J->rgbIn[t_ * 4], &J->rgbIn[((cy_ + dy_) * w + cx_ + dx_) * 4]); \
                } \
            } \
            (out) = cost_; \
        } while (0)
#define TRY(cand) do { \
            int c_ = (cand); \
            if (c_ >= 0 && c_ != best && L->usable[c_]) { long cc_; COST(c_, cc_); if (cc_ < bestCost) { bestCost = cc_; best = c_; } } \
        } while (0)
        COST(best, bestCost);
        // Propagation: neighbors' sources, shifted.
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            int qx = px + dx, qy = py + dy;
            if ((dx | dy) == 0 || qx < 0 || qy < 0 || qx >= w || qy >= h) continue;
            int q = qy * w + qx;
            if (L->known[q]) continue;
            int s = J->nnfIn[q], sx = s % w - dx, sy = s / w - dy;
            if (sx >= 0 && sy >= 0 && sx < w && sy < h) TRY(sy * w + sx);
        }
        // Random search around the best, shrinking.
        int t = 0;
        for (int r = maxSearch; r >= 1; r /= 2, t++) {
            uint64_t z = hash3(J->seed, (uint64_t)p, (uint64_t)t);
            int bx = best % w + (int)(z % (uint64_t)(2 * r + 1)) - r;
            int by = best / w + (int)((z >> 32) % (uint64_t)(2 * r + 1)) - r;
            if (bx >= 0 && by >= 0 && bx < w && by < h) TRY(by * w + bx);
        }
        for (int g = 0; g < REFINE_GLOBAL_TRIES; g++) {
            TRY(L->sources[hash3(J->seed, (uint64_t)p, (uint64_t)(100 + g)) % (uint64_t)L->nsources]);
        }
#undef TRY
#undef COST
        J->nnfOut[p] = best;
        memcpy(&J->rgbOut[p * 4], &J->rgbIn[best * 4], 3);
    }
}

/// Jacobi-style refinement passes, parallel across cores.
static int refine(Level *L, int passes, uint64_t seed, iv_fill_progress progress, void *context, double base, double span) {
    if (L->nunknown == 0) return IV_FILL_OK;
    const size_t n = (size_t)L->w * L->h;
    uint8_t *rgb2 = malloc(n * 4);
    int32_t *nnf2 = malloc(sizeof(int32_t) * n);
    if (!rgb2 || !nnf2) { free(rgb2); free(nnf2); return IV_FILL_BAD_INPUT; }
    for (int pass = 0; pass < passes; pass++) {
        memcpy(rgb2, L->rgb, n * 4);
        memcpy(nnf2, L->nnf, sizeof(int32_t) * n);
        RefineJob job = {L, L->rgb, L->nnf, rgb2, nnf2, mix64(seed + (uint64_t)pass * 7919u), 2048};
        size_t chunks = ((size_t)L->nunknown + (size_t)job.chunk - 1) / (size_t)job.chunk;
        dispatch_apply_f(chunks, DISPATCH_APPLY_AUTO, &job, refine_chunk);
        uint8_t *tr = L->rgb; L->rgb = rgb2; rgb2 = tr;
        int32_t *tn = L->nnf; L->nnf = nnf2; nnf2 = tn;
        if (progress && progress(context, base + span * (double)(pass + 1) / (double)passes)) {
            free(rgb2); free(nnf2);
            return IV_FILL_CANCELLED;
        }
    }
    free(rgb2);
    free(nnf2);
    return IV_FILL_OK;
}

// ---------------------------------------------------------------------- gradient-domain (Poisson) blend
//
// Copying patches reproduces texture, but not smooth gradients (skies): a copied patch can be slightly
// lighter or darker than where it lands, leaving a step at the original's edge and where copied patches
// meet. So keep the copied pixels' *gradients* and solve for the colors: f = g + c, where g is the copy
// and the correction c is smooth, matches the original along the edge, and cancels jumps at patch seams.
//
//   For unknown p and each 4-neighbor q (d = q - p), with sources np = nnf[p], nq = nnf[q]:
//     known q:    the edge condition  c_p ≈ I(q) - S(np + d)   (what p's source predicts q should be)
//     unknown q:  guidance gradient   v = ½[(S(np) - S(np+d)) + (S(nq-d) - S(nq))]   (each source's own
//                 local gradient; equals g_p - g_q where the copy is continuous), adding v - (g_p - g_q).
//
// A pull-push pyramid gives a good smooth starting correction from the edge values; SOR sweeps then solve
// the local equations (seams).

#define POISSON_SWEEPS 60

static void pull_push(float *val[3], float *wgt, int w, int h) {
    if (w <= 1 && h <= 1) return;
    int cw = (w + 1) / 2, ch = (h + 1) / 2;
    size_t cn = (size_t)cw * ch;
    float *cv[3] = {calloc(cn, sizeof(float)), calloc(cn, sizeof(float)), calloc(cn, sizeof(float))};
    float *cwgt = calloc(cn, sizeof(float));
    if (!cv[0] || !cv[1] || !cv[2] || !cwgt) { free(cv[0]); free(cv[1]); free(cv[2]); free(cwgt); return; }
    // Pull: weighted average of children.
    for (int y = 0; y < ch; y++) for (int x = 0; x < cw; x++) {
        float W = 0, V[3] = {0, 0, 0};
        for (int dy = 0; dy < 2; dy++) for (int dx = 0; dx < 2; dx++) {
            int fx = 2 * x + dx, fy = 2 * y + dy;
            if (fx >= w || fy >= h) continue;
            int i = fy * w + fx;
            W += wgt[i];
            for (int c = 0; c < 3; c++) V[c] += wgt[i] * val[c][i];
        }
        int ci = y * cw + x;
        cwgt[ci] = W > 1 ? 1 : W;
        for (int c = 0; c < 3; c++) cv[c][ci] = W > 0 ? V[c] / W : 0;
    }
    pull_push(cv, cwgt, cw, ch);
    // Push: fill gaps from the (bilinearly sampled) coarser level.
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int i = y * w + x;
        if (wgt[i] >= 1) continue;
        float sx = (x + 0.5f) / 2 - 0.5f, sy = (y + 0.5f) / 2 - 0.5f;
        int x0 = sx < 0 ? 0 : (int)sx, y0 = sy < 0 ? 0 : (int)sy;
        int x1 = x0 + 1 < cw ? x0 + 1 : x0, y1 = y0 + 1 < ch ? y0 + 1 : y0;
        float fx = sx - x0, fy = sy - y0;
        if (fx < 0) fx = 0;
        if (fy < 0) fy = 0;
        for (int c = 0; c < 3; c++) {
            float up = (1 - fy) * ((1 - fx) * cv[c][y0 * cw + x0] + fx * cv[c][y0 * cw + x1])
                     + fy * ((1 - fx) * cv[c][y1 * cw + x0] + fx * cv[c][y1 * cw + x1]);
            val[c][i] = wgt[i] * val[c][i] + (1 - wgt[i]) * up;
        }
        wgt[i] = 1;
    }
    free(cv[0]); free(cv[1]); free(cv[2]); free(cwgt);
}

typedef struct {
    const Level *L;
    const int32_t *list;   // unknown-list indices of one color (red-black ordering)
    int count;
    int chunk;
    const float *edge, *rhs;
    const uint8_t *counts;
    const int32_t *nb;
    float **c;
    float omega;
} SORJob;

/// One red-black half sweep: every pixel of one color depends only on the other color, so chunks can run
/// in parallel without races.
static void sor_chunk(void *ctx, size_t index) {
    const SORJob *J = ctx;
    const int start = (int)index * J->chunk;
    const int end = start + J->chunk < J->count ? start + J->chunk : J->count;
    for (int i = start; i < end; i++) {
        const int k = J->list[i];
        if (J->counts[k] == 0) continue;
        const int p = J->L->unknown[k];
        for (int ch = 0; ch < 3; ch++) {
            float sum = J->edge[k * 3 + ch] + J->rhs[k * 3 + ch];
            for (int j = 0; j < 4; j++) {
                int s = J->nb[k * 4 + j];
                if (s >= 0) sum += J->c[ch][J->L->unknown[s]];
            }
            float target = sum / (float)J->counts[k];
            J->c[ch][p] += J->omega * (target - J->c[ch][p]);
        }
    }
}

static void poisson_blend(Level *L) {
    const int w = L->w, h = L->h, n = w * h, m = L->nunknown;
    if (m == 0) return;
    // Sources (np, nq) are usable pixels, so S(np ± d) is always a known pixel within SRC_RADIUS.
    float *rhs = calloc((size_t)m * 3, sizeof(float));
    float *edge = calloc((size_t)m * 3, sizeof(float));
    uint8_t *count = calloc((size_t)m, 1);
    int32_t *nb = malloc(sizeof(int32_t) * (size_t)m * 4);
    int32_t *slot = malloc(sizeof(int32_t) * (size_t)n);      // pixel → index in unknown list, or -1
    float *c[3] = {calloc((size_t)n, sizeof(float)), calloc((size_t)n, sizeof(float)), calloc((size_t)n, sizeof(float))};
    float *wgt = calloc((size_t)n, sizeof(float));
    if (!rhs || !edge || !count || !nb || !slot || !c[0] || !c[1] || !c[2] || !wgt) goto done;
    for (int i = 0; i < n; i++) slot[i] = -1;
    for (int k = 0; k < m; k++) slot[L->unknown[k]] = k;

    static const int DX[4] = {1, -1, 0, 0}, DY[4] = {0, 0, 1, -1};
    const uint8_t *S = L->rgb;   // known pixels are the original
    for (int k = 0; k < m; k++) {
        const int p = L->unknown[k], px = p % w, py = p / w, np = L->nnf[p];
        int edges = 0;
        float edgeSum[3] = {0, 0, 0};
        for (int j = 0; j < 4; j++) {
            nb[k * 4 + j] = -1;
            const int qx = px + DX[j], qy = py + DY[j];
            if (qx < 0 || qy < 0 || qx >= w || qy >= h) continue;
            const int q = qy * w + qx, d = DY[j] * w + DX[j];
            count[k]++;
            if (L->known[q]) {
                for (int ch = 0; ch < 3; ch++) {
                    float e = (float)S[q * 4 + ch] - (float)S[(np + d) * 4 + ch];
                    edge[k * 3 + ch] += e;
                    edgeSum[ch] += e;
                }
                edges++;
            } else {
                const int nq = L->nnf[q];
                nb[k * 4 + j] = slot[q];
                for (int ch = 0; ch < 3; ch++) {
                    float v = 0.5f * (((float)S[np * 4 + ch] - (float)S[(np + d) * 4 + ch])
                                    + ((float)S[(nq - d) * 4 + ch] - (float)S[nq * 4 + ch]));
                    float jump = (float)L->rgb[p * 4 + ch] - (float)L->rgb[q * 4 + ch];
                    rhs[k * 3 + ch] += v - jump;
                }
            }
        }
        if (edges > 0) {
            wgt[p] = 1;
            for (int ch = 0; ch < 3; ch++) c[ch][p] = edgeSum[ch] / (float)edges;
        }
    }

    // Smooth starting point from the edge values, then red-black SOR on the local equations.
    pull_push(c, wgt, w, h);
    {
        int32_t *colors[2] = {malloc(sizeof(int32_t) * (size_t)m), malloc(sizeof(int32_t) * (size_t)m)};
        int ncolor[2] = {0, 0};
        if (colors[0] && colors[1]) {
            for (int k = 0; k < m; k++) {
                const int p = L->unknown[k], parity = ((p % w) + (p / w)) & 1;
                colors[parity][ncolor[parity]++] = k;
            }
            for (int sweep = 0; sweep < POISSON_SWEEPS; sweep++) {
                for (int color = 0; color < 2; color++) {
                    SORJob job = {L, colors[color], ncolor[color], 4096, edge, rhs, count, nb, c, 1.85f};
                    size_t chunks = ((size_t)job.count + (size_t)job.chunk - 1) / (size_t)job.chunk;
                    if (chunks > 0) dispatch_apply_f(chunks, DISPATCH_APPLY_AUTO, &job, sor_chunk);
                }
            }
        }
        free(colors[0]);
        free(colors[1]);
    }
    for (int k = 0; k < m; k++) {
        const int p = L->unknown[k];
        for (int ch = 0; ch < 3; ch++) {
            float f = (float)L->rgb[p * 4 + ch] + c[ch][p];
            L->rgb[p * 4 + ch] = (uint8_t)(f < 0 ? 0 : f > 255 ? 255 : f + 0.5f);
        }
    }
done:
    free(rhs); free(edge); free(count); free(nb); free(slot);
    free(c[0]); free(c[1]); free(c[2]); free(wgt);
}

// ----------------------------------------------------------------------------------------- seam blend

typedef struct {
    float *c[3];
    const uint8_t *known;
    int w, h, color, rowsPerChunk;
    float omega;
} MembraneJob;

/// One red-black half sweep of Laplace's equation over the unknown pixels (known ones are fixed values).
static void membrane_chunk(void *ctx, size_t index) {
    const MembraneJob *J = ctx;
    const int y0 = (int)index * J->rowsPerChunk;
    const int y1 = y0 + J->rowsPerChunk < J->h ? y0 + J->rowsPerChunk : J->h;
    const int w = J->w, h = J->h;
    for (int y = y0; y < y1; y++) {
        for (int x = (y + J->color) & 1; x < w; x += 2) {
            const int p = y * w + x;
            if (J->known[p]) continue;
            int count = 0;
            float sum[3] = {0, 0, 0};
            if (x > 0) { count++; for (int ch = 0; ch < 3; ch++) sum[ch] += J->c[ch][p - 1]; }
            if (x < w - 1) { count++; for (int ch = 0; ch < 3; ch++) sum[ch] += J->c[ch][p + 1]; }
            if (y > 0) { count++; for (int ch = 0; ch < 3; ch++) sum[ch] += J->c[ch][p - w]; }
            if (y < h - 1) { count++; for (int ch = 0; ch < 3; ch++) sum[ch] += J->c[ch][p + w]; }
            for (int ch = 0; ch < 3; ch++) J->c[ch][p] += J->omega * (sum[ch] / (float)count - J->c[ch][p]);
        }
    }
}

int iv_seam_blend(uint8_t *rgba, const uint8_t *reference, const uint8_t *known, int width, int height) {
    if (!rgba || !reference || !known || width < 2 || height < 2) return IV_FILL_BAD_INPUT;
    const int w = width, h = height, n = w * h;
    float *c[3] = {calloc((size_t)n, sizeof(float)), calloc((size_t)n, sizeof(float)), calloc((size_t)n, sizeof(float))};
    float *wgt = calloc((size_t)n, sizeof(float));
    uint8_t *fixed = calloc((size_t)n, 1);
    int status = IV_FILL_BAD_INPUT;
    if (!c[0] || !c[1] || !c[2] || !wgt || !fixed) goto done;

    // The correction is (reference - fill) on the known pixels; only those along the seam seed the starting guess.
    int unknown = 0;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        const int p = y * w + x;
        if (!known[p]) { unknown++; continue; }
        fixed[p] = 1;
        for (int ch = 0; ch < 3; ch++) c[ch][p] = (float)reference[p * 4 + ch] - (float)rgba[p * 4 + ch];
        const int seam = (x > 0 && !known[p - 1]) || (x < w - 1 && !known[p + 1])
                      || (y > 0 && !known[p - w]) || (y < h - 1 && !known[p + w]);
        if (seam) wgt[p] = 1;
    }
    if (unknown > 0 && unknown < n) {
        pull_push(c, wgt, w, h);
        // pull_push overwrote nothing it had a weight for; restore the exact values on every known pixel.
        for (int p = 0; p < n; p++) if (fixed[p]) for (int ch = 0; ch < 3; ch++)
            c[ch][p] = (float)reference[p * 4 + ch] - (float)rgba[p * 4 + ch];
        const int rows = 16;
        const size_t chunks = (size_t)((h + rows - 1) / rows);
        for (int sweep = 0; sweep < 2 * POISSON_SWEEPS; sweep++) {
            for (int color = 0; color < 2; color++) {
                MembraneJob job = {{c[0], c[1], c[2]}, fixed, w, h, color, rows, 1.9f};
                dispatch_apply_f(chunks, DISPATCH_APPLY_AUTO, &job, membrane_chunk);
            }
        }
    }
    for (int p = 0; p < n; p++) {
        if (known[p]) {
            memcpy(&rgba[p * 4], &reference[p * 4], 3);
        } else {
            for (int ch = 0; ch < 3; ch++) {
                float f = (float)rgba[p * 4 + ch] + c[ch][p];
                rgba[p * 4 + ch] = (uint8_t)(f < 0 ? 0 : f > 255 ? 255 : f + 0.5f);
            }
        }
        rgba[p * 4 + 3] = 255;
    }
    status = IV_FILL_OK;
done:
    free(c[0]); free(c[1]); free(c[2]); free(wgt); free(fixed);
    return status;
}

// ------------------------------------------------------------------------------------------- driver

int iv_content_aware_fill(uint8_t *rgba, const uint8_t *known, const uint8_t *avoid,
                          int width, int height, uint64_t seed,
                          iv_fill_progress progress, void *context) {
    if (!rgba || !known || width < 2 * SRC_RADIUS + 2 || height < 2 * SRC_RADIUS + 2) return IV_FILL_BAD_INPUT;
    const size_t n = (size_t)width * height;
    Level levels[MAX_LEVELS];
    memset(levels, 0, sizeof(levels));
    Level *L0 = &levels[0];
    L0->w = width; L0->h = height;
    L0->rgb = malloc(n * 4);
    L0->known = malloc(n);
    L0->nnf = malloc(sizeof(int32_t) * n);
    if (avoid) L0->avoid = malloc(n);
    if (!L0->rgb || !L0->known || !L0->nnf || (avoid && !L0->avoid)) { free_level(L0); return IV_FILL_BAD_INPUT; }
    memcpy(L0->rgb, rgba, n * 4);
    for (size_t i = 0; i < n; i++) {
        L0->known[i] = known[i] ? 1 : 0;
        L0->nnf[i] = (int32_t)i;
    }
    if (avoid) memcpy(L0->avoid, avoid, n);

    build_usable(L0, 1);
    int useAvoid = 1;
    if (L0->nsources == 0 && avoid) {
        useAvoid = 0;
        build_usable(L0, 0);
    }
    if (L0->nsources == 0) { free_level(L0); return IV_FILL_NO_SOURCE; }
    collect_unknown(L0);
    if (L0->nunknown == 0) { free_level(L0); return IV_FILL_OK; }

    // Pyramid down to roughly 80-160 px on the short side (while each level still has something to copy):
    // coarse enough for large-scale layout, fine enough that small regions don't vanish.
    int nlevels = 1;
    while (nlevels < MAX_LEVELS) {
        Level *F = &levels[nlevels - 1];
        if ((F->w < F->h ? F->w : F->h) < 160) break;
        Level *C = &levels[nlevels];
        if (!downsample(F, C)) { free_level(C); break; }
        build_usable(C, useAvoid);
        if (C->nsources < 64) { free_level(C); break; }
        collect_unknown(C);
        nlevels++;
    }

    // Progress weights: proportional to pixels filled per level.
    double total = 0, done = 0;
    for (int l = 0; l < nlevels; l++) total += (double)levels[l].nunknown;
    int status = IV_FILL_OK;
    for (int l = nlevels - 1; l >= 0 && status == IV_FILL_OK; l--) {
        Level *L = &levels[l];
        double span = total > 0 ? (double)L->nunknown / total : 1;
        uint64_t levelSeed = mix64(seed + (uint64_t)l * 0x9E37u);
        if (l == nlevels - 1) {
            status = grow(L, levelSeed, progress, context, done, span * 0.5);
            if (status == IV_FILL_OK) status = refine(L, 4, levelSeed, progress, context, done + span * 0.5, span * 0.5);
        } else {
            upsample(&levels[l + 1], L);
            status = refine(L, l == 0 ? 2 : 3, levelSeed, progress, context, done, span);
        }
        done += span;
    }

    if (status == IV_FILL_OK) {
        poisson_blend(L0);
        if (progress) progress(context, 1);
        for (int k = 0; k < L0->nunknown; k++) {
            int p = L0->unknown[k];
            memcpy(&rgba[p * 4], &L0->rgb[p * 4], 3);
            rgba[p * 4 + 3] = 255;
        }
    }
    for (int l = 0; l < nlevels; l++) free_level(&levels[l]);
    return status;
}
