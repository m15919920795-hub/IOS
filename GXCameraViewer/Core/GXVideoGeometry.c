#include "GXVideoGeometry.h"
#include <math.h>
#include <stddef.h>

static bool finiteRect(GXVideoRect rect) {
    return isfinite(rect.x) && isfinite(rect.y) && isfinite(rect.width) && isfinite(rect.height) &&
        rect.width > 0 && rect.height > 0 && isfinite(rect.x + rect.width) && isfinite(rect.y + rect.height);
}

bool GXVideoMapRect(GXVideoRect box, double videoWidth, double videoHeight,
                    GXVideoRect viewport, bool aspectFill, GXVideoRect *mapped) {
    if (!mapped) return false;
    *mapped = (GXVideoRect){0};
    if (!finiteRect(box) || !finiteRect(viewport) || !isfinite(videoWidth) || !isfinite(videoHeight) ||
        videoWidth <= 0 || videoHeight <= 0) return false;

    double left = fmax(0, box.x), top = fmax(0, box.y);
    double right = fmin(videoWidth, box.x + box.width), bottom = fmin(videoHeight, box.y + box.height);
    if (right <= left || bottom <= top) return false;

    double sx = viewport.width / videoWidth, sy = viewport.height / videoHeight;
    double scale = aspectFill ? fmax(sx, sy) : fmin(sx, sy);
    double offsetX = viewport.x + (viewport.width - videoWidth * scale) * 0.5;
    double offsetY = viewport.y + (viewport.height - videoHeight * scale) * 0.5;
    if (!isfinite(scale) || scale <= 0 || !isfinite(offsetX) || !isfinite(offsetY)) return false;

    left = fmax(viewport.x, offsetX + left * scale);
    top = fmax(viewport.y, offsetY + top * scale);
    right = fmin(viewport.x + viewport.width, offsetX + right * scale);
    bottom = fmin(viewport.y + viewport.height, offsetY + bottom * scale);
    GXVideoRect visible = {left, top, right - left, bottom - top};
    if (!finiteRect(visible)) return false;
    *mapped = visible;
    return true;
}
