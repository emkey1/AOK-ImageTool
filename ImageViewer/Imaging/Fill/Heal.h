#ifndef IV_HEAL_H
#define IV_HEAL_H

#include <stdint.h>

/// The healing brush: where `mask` covers (nonzero), `dst` gets `src`'s detail in its own color and light. The
/// difference between the two just outside the mask is carried smoothly across it (a membrane: Laplace's
/// equation, solved coarse to fine) and added to `src`, so the result meets `dst` without an edge. Pixels
/// outside the mask, and alpha, are left alone; blending by `mask` is left to the caller.
///
/// - dst, src: width * height * 4 bytes, rows top to bottom; `src` is what to copy, already lined up with `dst`.
/// - mask: width * height bytes.
/// Returns 0 when nothing around the mask is outside it (nothing to take the color from).
int iv_heal(uint8_t *dst, const uint8_t *src, const uint8_t *mask, int width, int height);

#endif
