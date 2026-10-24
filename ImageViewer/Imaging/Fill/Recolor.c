#include "Recolor.h"

#include <math.h>

// sRGB ↔ CIE L*a*b* (D65).

static double decode(double v) { return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }
static double encode(double v) { return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055; }
static double f(double t) { return t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0; }
static double finv(double t) { return t > 0.206893 ? t * t * t : (t - 16.0 / 116.0) / 7.787; }

static void to_lab(const double lin[3], double lab[3]) {
    double x = (0.4124564 * lin[0] + 0.3575761 * lin[1] + 0.1804375 * lin[2]) / 0.95047;
    double y = 0.2126729 * lin[0] + 0.7151522 * lin[1] + 0.0721750 * lin[2];
    double z = (0.0193339 * lin[0] + 0.1191920 * lin[1] + 0.9503041 * lin[2]) / 1.08883;
    double fx = f(x), fy = f(y), fz = f(z);
    lab[0] = 116 * fy - 16;
    lab[1] = 500 * (fx - fy);
    lab[2] = 200 * (fy - fz);
}

static uint8_t byte(double v) {
    double e = encode(v < 0 ? 0 : v > 1 ? 1 : v) * 255;
    return (uint8_t)(e < 0 ? 0 : e > 255 ? 255 : e + 0.5);
}

static void from_lab(const double lab[3], uint8_t out[3]) {
    double fy = (lab[0] + 16) / 116;
    double x = 0.95047 * finv(fy + lab[1] / 500), y = finv(fy), z = 1.08883 * finv(fy - lab[2] / 200);
    out[0] = byte(3.2404542 * x - 1.5371385 * y - 0.4985314 * z);
    out[1] = byte(-0.9692660 * x + 1.8760108 * y + 0.0415560 * z);
    out[2] = byte(0.0556434 * x - 0.2040259 * y + 1.0572252 * z);
}

void iv_select_color(const uint8_t *rgba, const uint8_t *mask, uint8_t *out, int width, int height,
                     uint8_t red, uint8_t green, uint8_t blue, double tolerance) {
    double table[256];
    for (int i = 0; i < 256; i++) table[i] = decode(i / 255.0);
    double slin[3] = { table[red], table[green], table[blue] }, seed[3];
    to_lab(slin, seed);
    double k = 0.6931471805599453 / (tolerance * tolerance);   // half at `tolerance`
    double seed_c = hypot(seed[1], seed[2]), seed_s = seed_c / fmax(seed[0], 10);
    long n = (long)width * height;
    for (long i = 0; i < n; i++) {
        if (!mask[i]) { out[i] = 0; continue; }
        const uint8_t *p = rgba + i * 4;
        double lin[3] = { table[p[0]], table[p[1]], table[p[2]] }, lab[3];
        to_lab(lin, lab);
        // Shading changes a color's lightness, and how colorful it is with it, but hardly its hue or its
        // colorfulness for its lightness (saturation): those count most, lightness little. (The hue difference is
        // scaled by colorfulness, as in CIE94, so the noisy hue of near-grays counts little; saturation keeps
        // grays, such as hair or teeth, out of something colored.)
        double c = hypot(lab[1], lab[2]), sat = c / fmax(lab[0], 10);
        double dl = lab[0] - seed[0], dc = c - seed_c;
        double dab2 = (lab[1] - seed[1]) * (lab[1] - seed[1]) + (lab[2] - seed[2]) * (lab[2] - seed[2]);
        double dh2 = dab2 - dc * dc;
        if (dh2 < 0) dh2 = 0;
        double ds = 40 * (sat - seed_s) / fmax(seed_s, 0.15);
        double d2 = dh2 + ds * ds + 0.12 * dl * dl;
        // Clearly that color is all in, clearly another all out (a soft selection would leave some of the old color
        // inside it); the edge between stays soft.
        double t = (exp(-k * d2) - 0.2) / 0.4;
        t = t < 0 ? 0 : t > 1 ? 1 : t;
        out[i] = (uint8_t)(mask[i] * t * t * (3 - 2 * t) + 0.5);
    }
}

int iv_median_color(const uint8_t *rgba, const uint8_t *mask, int width, int height, uint8_t out[3]) {
    long hist[3][256] = {{0}};
    long count = 0, n = (long)width * height;
    for (long i = 0; i < n; i++) {
        if (mask[i] < 128) continue;
        for (int c = 0; c < 3; c++) hist[c][rgba[i * 4 + c]]++;
        count++;
    }
    if (count == 0) return 0;
    for (int c = 0; c < 3; c++) {
        long seen = 0;
        int v = 0;
        while (v < 255 && (seen += hist[c][v]) < (count + 1) / 2) v++;
        out[c] = (uint8_t)v;
    }
    return 1;
}

void iv_recolor(uint8_t *rgba, const uint8_t *weight, const uint8_t *core, int width, int height,
                uint8_t red, uint8_t green, uint8_t blue) {
    double table[256];
    for (int i = 0; i < 256; i++) table[i] = decode(i / 255.0);
    long n = (long)width * height;
    if (!core) core = weight;

    // The area's average lightness (L*) and color (linear RGB), weighted, from what's surely in it.
    double sum = 0, sl[3] = { 0, 0, 0 }, total = 0;
    for (long i = 0; i < n; i++) {
        if (core[i] < 128) continue;
        const uint8_t *p = rgba + i * 4;
        double lin[3] = { table[p[0]], table[p[1]], table[p[2]] }, lab[3];
        to_lab(lin, lab);
        sum += lab[0] * core[i];
        for (int c = 0; c < 3; c++) sl[c] += lin[c] * core[i];
        total += core[i];
    }
    if (total <= 0) return;
    double mean = sum / total, s[3] = { sl[0] / total, sl[1] / total, sl[2] / total };
    // For how much a pixel is a mix of that color and something neutral (gray, white, black: hair, the ground):
    // the least-squares fit of pixel = a * color + b * (1, 1, 1).
    double ss = s[0] * s[0] + s[1] * s[1] + s[2] * s[2], s1 = s[0] + s[1] + s[2], det = 3 * ss - s1 * s1;

    double tlin[3] = { table[red], table[green], table[blue] }, target[3];
    to_lab(tlin, target);
    // Shading kept as differences from the average, but narrowed toward black or white when the new color is
    // darker or lighter, so shadows of something made dark don't go black (and highlights of something made
    // light don't go white).
    double below = fmin(1, target[0] / fmax(mean, 1)), above = fmin(1, (100 - target[0]) / fmax(100 - mean, 1));
    for (long i = 0; i < n; i++) {
        if (!weight[i]) continue;
        uint8_t *p = rgba + i * 4;
        double lin[3] = { table[p[0]], table[p[1]], table[p[2]] }, lab[3];
        to_lab(lin, lab);
        // Outside `core` (around its edge, between strands of hair over it): only as much as the pixel is a mix
        // of the area's color and something neutral; anything else (skin beside a brown jacket: "more than all
        // jacket"; beside a red shirt: a poor fit) not at all. Across `core`'s soft edge, from that to all.
        double share = 1, in = core[i] / 255.0;
        if (in < 1) {
            double mix = 0;
            if (det > 1e-9) {
                double sp = s[0] * lin[0] + s[1] * lin[1] + s[2] * lin[2], p1 = lin[0] + lin[1] + lin[2];
                double a = (3 * sp - s1 * p1) / det, b = (ss * p1 - s1 * sp) / det;
                if (a > 0 && a <= 1.15 && b >= -0.02) {
                    double r0 = lin[0] - a * s[0] - b, r1 = lin[1] - a * s[1] - b, r2 = lin[2] - a * s[2] - b;
                    double size = sqrt(lin[0] * lin[0] + lin[1] * lin[1] + lin[2] * lin[2]);
                    double off = sqrt(r0 * r0 + r1 * r1 + r2 * r2) / (size > 1e-4 ? size : 1e-4);
                    double fit = 1 - (off - 0.04) / 0.06;
                    fit = fit < 0 ? 0 : fit > 1 ? 1 : fit;
                    mix = (a < 1 ? a : 1) * fit;
                }
            }
            share = in + (1 - in) * mix;
            if (share <= 0) continue;
        }
        double l = target[0] + (lab[0] - mean) * (lab[0] < mean ? below : above);
        l = l < 0 ? 0 : l > 100 ? 100 : l;
        // Full color at the target's lightness, less toward black and white (shadows and highlights).
        double s = l <= target[0] ? l / (target[0] > 1 ? target[0] : 1) : (100 - l) / (100 - target[0] > 1 ? 100 - target[0] : 1);
        double out[3] = { l, target[1] * s, target[2] * s };
        for (int c = 0; c < 3; c++) out[c] = lab[c] + share * (out[c] - lab[c]);
        from_lab(out, p);
    }
}
