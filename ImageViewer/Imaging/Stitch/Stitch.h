#ifndef IV_STITCH_H
#define IV_STITCH_H

#include <stdint.h>
#include "../Fill/ContentAwareFill.h"

/// A corner found in a picture, with what's around it described in 256 bits.
typedef struct {
    /// Where it is: pixels from the top left (a pixel's middle is at +0.5).
    float x, y;
    /// How bright the picture is around it (0...1).
    float level;
    uint64_t bits[4];
} iv_feature;

/// Finds corners in a picture, the strongest few in each cell of a grid so that they're spread over it, each
/// described so the same corner can be recognized in another picture taken beside this one (turned a little,
/// lighter or darker; not at another zoom).
///
/// - gray: width * height bytes, rows top to bottom.
///
/// Returns how many were written to `out` (at most `capacity`).
int iv_stitch_features(const uint8_t *gray, int width, int height, iv_feature *out, int capacity);

/// How picture b lies on picture a: the homography most of their matched corners agree on.
///
/// - tolerance: how far (pixels) a corner may land from its match and still agree.
/// - h:         set to the homography taking b's pixels onto a's (row-major, scaled so its determinant is 1).
/// - matched:   set to how many corners were paired at all.
/// - gain:      set to how much brighter b is than a where they show the same thing (1 = the same).
///
/// Returns how many pairs agree: 0 when the pictures don't show the same thing.
int iv_stitch_align(const iv_feature *a, int countA, const iv_feature *b, int countB, double tolerance, uint64_t seed,
                    double h[9], int *matched, double *gain);

/// A picture's broad light and color: it averaged down to lowWidth × lowHeight and blurred a little, as
/// lowWidth * lowHeight * 3 floats (0...255).
void iv_stitch_low(const uint8_t *rgba, int width, int height, float *low, int lowWidth, int lowHeight);

/// One of the pictures being stitched.
typedef struct {
    /// width * height * 4 bytes, rows top to bottom (alpha is ignored).
    const uint8_t *rgba;
    int width, height;
    /// From `iv_stitch_low`.
    const float *low;
    int lowWidth, lowHeight;
    /// Takes a direction seen from the view (x right, y down, z ahead) to this picture's pixels (row-major;
    /// the direction is behind this picture's camera where the third coordinate isn't positive).
    double toSource[9];
    /// Its pixels are multiplied by this (to even out the pictures' exposures).
    float gain;
} iv_stitch_source;

enum {
    /// A flat view: straight lines stay straight (wide views stretch toward the sides).
    IV_STITCH_FLAT = 0,
    /// The view wrapped on an upright cylinder: for wide views side to side.
    IV_STITCH_CYLINDER = 1,
    /// On a sphere: for views that reach far up and down as well.
    IV_STITCH_SPHERE = 2,
};

/// What of the view a stitched picture shows.
typedef struct {
    int projection;
    /// Pixels to one unit of the view: a radian around a cylinder or sphere, the focal length of a flat view.
    double scale;
    /// The picture's top left corner in the view, in its pixels (the view's middle is 0, 0).
    double left, top;
} iv_stitch_view;

/// Where the pictures fall in a view of this projection and scale: the pixel rectangle around all of them
/// (left, top, right, bottom; the view's middle is 0, 0). Parts of a picture too far round to show (more than
/// about 70° off the middle of a flat view, or behind it) are left out; `trimmed` is set to 1 when there are
/// any. Returns 0 when nothing of the pictures shows at all.
int iv_stitch_bounds(const iv_stitch_source *sources, int count, int projection, double scale, double bounds[4], int *trimmed);

/// The pictures laid over each other in the view: their broad light and color cross-faded where they overlap,
/// their detail taken from whichever picture has more of itself around that point (so nothing shows twice).
///
/// - out:     width * height * 4 bytes, rows top to bottom; alpha is 255 where a picture covers, 0 elsewhere.
/// - quality: 0 samples the pictures quickly (for a preview), 1 sharply.
///
/// Returns IV_FILL_OK, IV_FILL_CANCELLED or IV_FILL_BAD_INPUT.
int iv_stitch_render(const iv_stitch_source *sources, int count, const iv_stitch_view *view, uint8_t *out, int width, int height,
                     int quality, iv_fill_progress progress, void *context);

/// The largest upright rectangle of `rgba` (width * height * 4 bytes) that's covered everywhere (alpha 255),
/// as x, y, width, height from the top left. Returns 0 when nothing is covered.
int iv_stitch_covered_rect(const uint8_t *rgba, int width, int height, int rect[4]);

#endif
