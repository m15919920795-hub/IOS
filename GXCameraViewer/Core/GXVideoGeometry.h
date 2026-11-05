#ifndef GX_VIDEO_GEOMETRY_H
#define GX_VIDEO_GEOMETRY_H
#include <stdbool.h>

typedef struct {
    double x, y, width, height;
} GXVideoRect;

/* Top-left video pixels -> view points. Match centered aspect-fit/fill and clip
 * to both the source image and viewport. Return false for invalid/invisible boxes. */
bool GXVideoMapRect(GXVideoRect box, double videoWidth, double videoHeight,
                    GXVideoRect viewport, bool aspectFill, GXVideoRect *mapped);
#endif
