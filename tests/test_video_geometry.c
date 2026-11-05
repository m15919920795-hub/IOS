#include "GXVideoGeometry.h"
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdio.h>

static unsigned cases;
static void expect(GXVideoRect box, double width, double height, GXVideoRect viewport,
                   bool fill, GXVideoRect expected) {
    GXVideoRect actual;
    assert(GXVideoMapRect(box, width, height, viewport, fill, &actual));
    assert(fabs(actual.x - expected.x) < 1e-9);
    assert(fabs(actual.y - expected.y) < 1e-9);
    assert(fabs(actual.width - expected.width) < 1e-9);
    assert(fabs(actual.height - expected.height) < 1e-9);
    cases++;
}
static void reject(GXVideoRect box, double width, double height, GXVideoRect viewport, bool fill) {
    GXVideoRect actual = {1, 2, 3, 4};
    assert(!GXVideoMapRect(box, width, height, viewport, fill, &actual));
    assert(actual.x == 0 && actual.y == 0 && actual.width == 0 && actual.height == 0);
    cases++;
}

int main(void) {
    const GXVideoRect screen = {0, 0, 320, 180}, box = {320, 180, 640, 360};
    expect(box, 1280, 720, screen, false, (GXVideoRect){80, 45, 160, 90});
    expect((GXVideoRect){480, 270, 960, 540}, 1920, 1080, screen, false,
           (GXVideoRect){80, 45, 160, 90});
    /* Black bars on top/bottom, then left/right; never scale against the whole view. */
    expect(box, 1280, 720, (GXVideoRect){0, 0, 320, 240}, false, (GXVideoRect){80, 75, 160, 90});
    expect(box, 1280, 720, (GXVideoRect){0, 0, 640, 180}, false, (GXVideoRect){240, 45, 160, 90});
    expect(box, 1280, 720, (GXVideoRect){0, 0, 180, 320}, false, (GXVideoRect){45, 134.6875, 90, 50.625});
    expect(box, 1280, 720, (GXVideoRect){10, 20, 320, 240}, false, (GXVideoRect){90, 95, 160, 90});
    /* Center cropping in aspect-fill, including boxes outside the visible crop. */
    expect(box, 1280, 720, (GXVideoRect){0, 0, 320, 240}, true, (GXVideoRect){160.0/3, 60, 640.0/3, 120});
    expect((GXVideoRect){0, 0, 320, 720}, 1280, 720, (GXVideoRect){0, 0, 320, 240}, true,
           (GXVideoRect){0, 0, 160.0/3, 240});
    reject((GXVideoRect){0, 0, 100, 100}, 1280, 720, (GXVideoRect){0, 0, 320, 240}, true);
    expect((GXVideoRect){0, 0, 1280, 720}, 1280, 720, (GXVideoRect){0, 0, 180, 320}, true,
           (GXVideoRect){0, 0, 180, 320});
    /* Partial boxes are clipped to the source before mapping; protocol sample is video pixels. */
    expect((GXVideoRect){-100, -50, 300, 200}, 1280, 720, screen, false, (GXVideoRect){0, 0, 50, 37.5});
    expect((GXVideoRect){1200, 700, 200, 100}, 1280, 720, screen, false, (GXVideoRect){300, 175, 20, 5});
    expect((GXVideoRect){201, 0, 966, 662}, 1280, 720, screen, false, (GXVideoRect){50.25, 0, 241.5, 165.5});
    reject((GXVideoRect){1280, 0, 10, 10}, 1280, 720, screen, false);
    reject((GXVideoRect){0, 720, 10, 10}, 1280, 720, screen, false);
    reject((GXVideoRect){0, 0, 0, 10}, 1280, 720, screen, false);
    reject((GXVideoRect){0, 0, 10, -1}, 1280, 720, screen, false);
    reject((GXVideoRect){NAN, 0, 10, 10}, 1280, 720, screen, false);
    reject((GXVideoRect){0, 0, INFINITY, 10}, 1280, 720, screen, false);
    reject((GXVideoRect){DBL_MAX, 0, DBL_MAX, 10}, 1280, 720, screen, false);
    reject(box, 0, 720, screen, false);
    reject(box, 1280, NAN, screen, false);
    reject(box, 1280, 720, (GXVideoRect){0, 0, 0, 180}, false);
    reject(box, 1280, 720, (GXVideoRect){0, INFINITY, 320, 180}, false);
    assert(!GXVideoMapRect(box, 1280, 720, screen, false, NULL)); cases++;
    printf("PASS: %u video geometry cases (720p/1080p, letterboxing, rotation sizes, cropping, clipping and invalid inputs).\n", cases);
    return 0;
}
