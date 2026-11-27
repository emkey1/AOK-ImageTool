#ifndef IV_STITCH_DETAIL_H
#define IV_STITCH_DETAIL_H

#include <stdint.h>
#include "../Fill/ContentAwareFill.h"

/// What finishes a filled stitched picture at any size: the filling, the pictures as they are at the filling's
/// size, and where each filled-in place takes its fine texture from.
///
/// A filling is made smaller than the pictures (a generated one at about 1,000 pixels across) and enlarged, so
/// on its own it's smooth beside them: asphalt, grass and grain stop at the pictures' edges. So the filled-in
/// places borrow the pictures' own texture: for each, a place in the pictures that looks alike at a coarse
/// scale and is near, whose detail (what the pictures have there beyond what the filling's size can hold, and
/// what the filling lacks of their texture at its own size) is added to the enlarged filling.
typedef struct iv_detail iv_detail;

/// - filling:  width * height * 4 bytes: the whole view, filled (rows top to bottom).
/// - pictures: the same view with only the pictures in it: alpha 255 where they cover.
/// - band:     how far inside the pictures' edges (pixels) the filling was made to carry on from them: the
///             pictures fade into the filling over that.
/// Returns NULL if there's no memory for it. Free with `iv_detail_free`.
iv_detail *iv_detail_make(const uint8_t *filling, const uint8_t *pictures, int width, int height, int band);
void iv_detail_free(iv_detail *detail);

/// The finished picture: `top` (the stitched pictures at any size: alpha 255 where they cover, nothing
/// elsewhere) with the rest from the filling, enlarged and given the pictures' texture.
///
/// - scale:    `top`'s pixels to one of the filling's.
/// - left, up: where the filling's top left corner is, in `top`'s pixels.
/// - texture:  0 leaves the enlarged filling as it is (as it was before this existed).
/// - out:      topWidth * topHeight * 4 bytes, opaque.
/// Returns IV_FILL_OK, IV_FILL_CANCELLED or IV_FILL_BAD_INPUT.
int iv_detail_finish(const iv_detail *detail, const uint8_t *top, int topWidth, int topHeight, double scale, double left, double up,
                     int texture, uint8_t *out, iv_fill_progress progress, void *context);

/// (For tests.) How many of the grid's points take their texture from somewhere else, and how many found
/// nowhere to take it from.
void iv_detail_counts(const iv_detail *detail, int *moved, int *none);

#endif
