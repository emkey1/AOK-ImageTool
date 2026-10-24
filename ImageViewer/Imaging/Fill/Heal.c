#include "Heal.h"

#include <stdlib.h>

// The difference between destination and source (3 channels), and which of it is known (outside the mask).
typedef struct {
    int w, h;
    float *d;
    uint8_t *known;
} Level;

// Gauss-Seidel with over-relaxation: each unknown value moves toward the average of its neighbors.
static void relax(Level *l, int iterations, float omega) {
    int w = l->w, h = l->h;
    for (int it = 0; it < iterations; it++) {
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                long i = (long)y * w + x;
                if (l->known[i]) continue;
                float s0 = 0, s1 = 0, s2 = 0;
                int n = 0;
                long nb[4];
                if (x > 0) nb[n++] = i - 1;
                if (x < w - 1) nb[n++] = i + 1;
                if (y > 0) nb[n++] = i - w;
                if (y < h - 1) nb[n++] = i + w;
                for (int k = 0; k < n; k++) {
                    s0 += l->d[nb[k] * 3];
                    s1 += l->d[nb[k] * 3 + 1];
                    s2 += l->d[nb[k] * 3 + 2];
                }
                if (n == 0) continue;
                float *v = l->d + i * 3;
                v[0] += omega * (s0 / n - v[0]);
                v[1] += omega * (s1 / n - v[1]);
                v[2] += omega * (s2 / n - v[2]);
            }
        }
    }
}

// Half the size: a cell is known if any of its four is, with their average.
static int halve(const Level *f, Level *c) {
    c->w = (f->w + 1) / 2;
    c->h = (f->h + 1) / 2;
    long n = (long)c->w * c->h;
    c->d = calloc(n * 3, sizeof(float));
    c->known = calloc(n, 1);
    if (!c->d || !c->known) return 0;
    for (int y = 0; y < c->h; y++) {
        for (int x = 0; x < c->w; x++) {
            float s[3] = { 0, 0, 0 };
            int count = 0;
            for (int dy = 0; dy < 2; dy++) {
                for (int dx = 0; dx < 2; dx++) {
                    int fx = 2 * x + dx, fy = 2 * y + dy;
                    if (fx >= f->w || fy >= f->h) continue;
                    long fi = (long)fy * f->w + fx;
                    if (!f->known[fi]) continue;
                    for (int ch = 0; ch < 3; ch++) s[ch] += f->d[fi * 3 + ch];
                    count++;
                }
            }
            if (count) {
                long ci = (long)y * c->w + x;
                c->known[ci] = 1;
                for (int ch = 0; ch < 3; ch++) c->d[ci * 3 + ch] = s[ch] / count;
            }
        }
    }
    return 1;
}

int iv_heal(uint8_t *dst, const uint8_t *src, const uint8_t *mask, int width, int height) {
    enum { maxLevels = 16 };
    Level levels[maxLevels];
    int count = 0;
    long n = (long)width * height;
    Level *top = &levels[count++];
    top->w = width;
    top->h = height;
    top->d = calloc(n * 3, sizeof(float));
    top->known = calloc(n, 1);
    if (!top->d || !top->known) { free(top->d); free(top->known); return 0; }
    double mean[3] = { 0, 0, 0 };
    long knownCount = 0;
    for (long i = 0; i < n; i++) {
        if (mask[i]) continue;
        top->known[i] = 1;
        for (int c = 0; c < 3; c++) {
            float v = (float)dst[i * 4 + c] - (float)src[i * 4 + c];
            top->d[i * 3 + c] = v;
            mean[c] += v;
        }
        knownCount++;
    }
    int ok = knownCount > 0 && knownCount < n;
    // Coarser and coarser, down to a few cells across.
    while (ok && count < maxLevels && (levels[count - 1].w > 16 || levels[count - 1].h > 16)) {
        if (!halve(&levels[count - 1], &levels[count])) { count++; ok = 0; break; }
        count++;
    }
    if (ok) {
        // The coarsest, from the average difference; then each finer one from the one below it.
        Level *c = &levels[count - 1];
        for (long i = 0; i < (long)c->w * c->h; i++) {
            if (c->known[i]) continue;
            for (int ch = 0; ch < 3; ch++) c->d[i * 3 + ch] = (float)(mean[ch] / knownCount);
        }
        relax(c, 400, 1.6f);
        for (int k = count - 2; k >= 0; k--) {
            Level *f = &levels[k], *below = &levels[k + 1];
            for (int y = 0; y < f->h; y++) {
                for (int x = 0; x < f->w; x++) {
                    long i = (long)y * f->w + x;
                    if (f->known[i]) continue;
                    long j = (long)(y / 2) * below->w + x / 2;
                    for (int ch = 0; ch < 3; ch++) f->d[i * 3 + ch] = below->d[j * 3 + ch];
                }
            }
            relax(f, k == 0 ? 40 : 60, 1.8f);
        }
        for (long i = 0; i < n; i++) {
            if (!mask[i]) continue;
            for (int c = 0; c < 3; c++) {
                float v = (float)src[i * 4 + c] + top->d[i * 3 + c];
                dst[i * 4 + c] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v + 0.5f);
            }
        }
    }
    for (int k = 0; k < count; k++) {
        free(levels[k].d);
        free(levels[k].known);
    }
    return ok;
}
