#ifndef IV_STRAIGHTEN_H
#define IV_STRAIGHTEN_H

#include <stdint.h>

/// How far a picture is turned from level, from its long straight lines: a horizon or other near-horizontal
/// lines, or near-vertical ones such as walls, doorways and building edges.
///
/// - gray:       width * height bytes, rows top to bottom.
/// - maxDegrees: the largest tilt to look for (lines further from level or plumb are ignored).
/// - degrees:    set to the lines' counterclockwise tilt as seen (turn the picture clockwise by this much to
///               level it).
/// - strength:   set to how convincing the lines are: the best line's length as a fraction of the picture's
///               width (or height, for vertical lines). Above about 0.3 is a clear line.
///
/// Returns 1 when it found lines (horizontal = 1, vertical = 2 in `*kind`), 0 when there are none.
int iv_estimate_tilt(const uint8_t *gray, int width, int height, double maxDegrees,
                     double *degrees, double *strength, int *kind);

/// Both families at once: the strongest near-horizontal line's tilt and strength, and the near-vertical lines'
/// (the middle of the strong ones). Same conventions as above; a strength of 0 means none. Returns 0 on
/// failure (too small, out of memory).
int iv_tilt_families(const uint8_t *gray, int width, int height, double maxDegrees,
                     double *hDegrees, double *hStrength, double *vDegrees, double *vStrength);

/// The strength of the strongest near-horizontal line tilted within `tolerance` of `degrees` (same convention
/// as above): whether there's a line in the picture to back up a horizon found some other way.
double iv_horizontal_strength_near(const uint8_t *gray, int width, int height, double degrees, double tolerance);

#endif
