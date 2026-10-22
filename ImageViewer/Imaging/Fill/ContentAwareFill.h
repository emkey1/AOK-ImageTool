#ifndef IV_CONTENT_AWARE_FILL_H
#define IV_CONTENT_AWARE_FILL_H

#include <stdint.h>

/// Called between stages with overall progress 0...1. Return nonzero to cancel.
typedef int (*iv_fill_progress)(void *context, double fraction);

enum {
    IV_FILL_OK = 0,
    IV_FILL_CANCELLED = 1,
    IV_FILL_NO_SOURCE = 2,
    IV_FILL_BAD_INPUT = 3,
};

/// Content-aware fill: replaces every pixel whose `known` byte is 0 with texture synthesized from the
/// known pixels (coarse-to-fine patch matching, copying real pixels so the result stays sharp).
///
/// - rgba:   width * height * 4 bytes, rows top to bottom. Unknown pixels are overwritten (alpha set to 255);
///           known pixels are left untouched.
/// - known:  width * height bytes, nonzero for original pixels.
/// - avoid:  optional (NULL for none), nonzero for known pixels that must not be copied (e.g. the subject).
///           Ignored if it would leave nothing to copy from.
/// - seed:   different seeds give different (equally valid) results.
int iv_content_aware_fill(uint8_t *rgba, const uint8_t *known, const uint8_t *avoid,
                          int width, int height, uint64_t seed,
                          iv_fill_progress progress, void *context);

/// Seam fix for content made elsewhere (a generated fill): keeps the detail of `rgba`'s unknown pixels but
/// shifts it smoothly (a membrane solve of the differences along the seam) so it meets `reference`'s known
/// pixels without a visible edge or color cast. Known pixels are set to `reference`.
///
/// - rgba:      width * height * 4 bytes, the fill everywhere (rows top to bottom).
/// - reference: width * height * 4 bytes, the original where `known` is nonzero.
int iv_seam_blend(uint8_t *rgba, const uint8_t *reference, const uint8_t *known, int width, int height);

#endif
