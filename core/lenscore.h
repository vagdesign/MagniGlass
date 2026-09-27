/*
 * MagniGlass lens renderer: a hand magnifier (real glass + chrome rim and grip)
 * drawn into a premultiplied BGRA image. Shared by the Windows and macOS apps.
 *
 * Usage:
 *   ctx = lens_create(diameter, zoom, flags);
 *   allocate a lens_width() x lens_height() BGRA buffer, lens_draw_static() into it once;
 *   every frame: lens_draw_glass() with the screen pixels around the pointer, then show
 *   the buffer with its pixel (lens_center_x, lens_center_y) on the pointer.
 */
#ifndef LENSCORE_H
#define LENSCORE_H

#include <stdint.h>

#ifdef _WIN32
#define LENS_API __declspec(dllexport)
#else
#define LENS_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define LENS_HANDLE_LEFT 1 /* grip points to the lower left instead of the lower right */
#define LENS_NO_SHADOW   2 /* no drop shadow under the glass */

typedef struct LensCtx LensCtx;

/* diameter: of the glass, in device pixels (16..4096). zoom: 1..16. */
LENS_API LensCtx *lens_create(int diameter, float zoom, int flags);
LENS_API void lens_destroy(LensCtx *ctx);

/* Changes the magnification (cheap: rebuilds only the refraction table). */
LENS_API void lens_set_zoom(LensCtx *ctx, float zoom);

LENS_API int lens_width(const LensCtx *ctx);
LENS_API int lens_height(const LensCtx *ctx);
/* The pixel of the image that sits on the pointer (the centre of the glass). */
LENS_API int lens_center_x(const LensCtx *ctx);
LENS_API int lens_center_y(const LensCtx *ctx);
/* Farthest source pixel the glass reads, counted from the pointer pixel. Capture at
   least (2 * radius + 1) square pixels centred on the pointer. */
LENS_API int lens_source_radius(const LensCtx *ctx);
/* Rows [top, bottom) that lens_draw_glass() writes. */
LENS_API int lens_glass_top(const LensCtx *ctx);
LENS_API int lens_glass_bottom(const LensCtx *ctx);

/* Draws everything that does not change: shadow, chrome grip and rim. */
LENS_API void lens_draw_static(const LensCtx *ctx, uint8_t *dst, int dst_stride);

/*
 * Draws the magnified, refracted screen inside the rim for rows [y0, y1).
 * src: BGRA (alpha ignored), src_w x src_h, stride in bytes. (src_cx, src_cy) is the
 * pixel under the pointer. Reads outside src are clamped to its edge.
 * Row ranges are independent, so callers may split the work across threads.
 */
LENS_API void lens_draw_glass(const LensCtx *ctx, const uint8_t *src, int src_w, int src_h, int src_stride,
                              int src_cx, int src_cy, uint8_t *dst, int dst_stride, int y0, int y1);

#ifdef __cplusplus
}
#endif

#endif
