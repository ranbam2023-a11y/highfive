#include <stdint.h>
#include <stddef.h>

/*
 * Minimal declarations for Apple's private MultitouchSupport.framework.
 * We only need the layout of MTTouch so Swift can read contact frames.
 * (Linked at runtime with dlopen/dlsym, so no framework symbols are required.)
 */

typedef struct { float x; float y; } MTPoint;
typedef struct { MTPoint position; MTPoint velocity; } MTVector;

typedef struct {
    int32_t  frame;
    double   timestamp;
    int32_t  pathIndex;
    int32_t  state;       /* 3 = MakeTouch, 4 = Touching, 5 = BreakTouch */
    int32_t  fingerID;
    int32_t  handID;
    MTVector normalizedVector;   /* position in 0..1 */
    float    zTotal;
    int32_t  field9;
    float    angle;
    float    majorAxis;
    float    minorAxis;
    MTVector absoluteVector;     /* position in mm */
    int32_t  field14;
    int32_t  field15;
    float    zDensity;
} MTTouch;
