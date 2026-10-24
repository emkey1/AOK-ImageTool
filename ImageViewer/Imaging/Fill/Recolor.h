#ifndef IV_RECOLOR_H
#define IV_RECOLOR_H

#include <stdint.h>

/// Recolors every pixel `weight` covers (nonzero) to `target` (sRGB, 0...255), keeping its shading: the area's
/// average lightness (CIE L*) becomes the target's, each pixel keeping its own difference from that average
/// (narrowed toward black or white, so it doesn't run off the end), and
/// the target's hue and saturation follow the lightness (fading toward black and white at the ends). The area is
/// what `core` covers more than half (NULL: `weight`); pixels `weight` covers outside it, around its edges, change
/// only as much as they're the area's color. Pixels outside are left alone; blending by `weight` is left to the
/// caller.
///
/// - rgba:   width * height * 4 bytes, sRGB, rows top to bottom (alpha untouched).
/// - weight, core: width * height bytes.
void iv_recolor(uint8_t *rgba, const uint8_t *weight, const uint8_t *core, int width, int height,
                uint8_t red, uint8_t green, uint8_t blue);

/// Picks one colored thing (a shirt) out of a rougher selection: `out` = `mask` × how close each pixel is to
/// `seed` (sRGB) in L*a*b*, by hue and saturation more than lightness, so its shading stays in.
/// `tolerance` is the distance (in L*a*b* units) at which a pixel is about 85% in; much closer, it's all in.
void iv_select_color(const uint8_t *rgba, const uint8_t *mask, uint8_t *out, int width, int height,
                     uint8_t red, uint8_t green, uint8_t blue, double tolerance);

/// The typical color (per-channel median) of the pixels `mask` covers more than half, into `out` (sRGB).
/// Returns 0 when it covers none.
int iv_median_color(const uint8_t *rgba, const uint8_t *mask, int width, int height, uint8_t out[3]);

#endif
