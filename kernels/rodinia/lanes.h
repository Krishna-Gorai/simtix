/* lanes.h  -  the lane count the application kernels are assembled for.
 *
 * build.py --lanes L passes -DLANES=L; without it the kernels are built for the
 * default 8-lane accelerator. A warp is LANES threads and a line LANES words. */
#ifndef LANES
#define LANES 8
#endif
#if LANES == 4
#define LOG2L 2
#elif LANES == 8
#define LOG2L 3
#elif LANES == 16
#define LOG2L 4
#else
#error "LANES must be 4, 8 or 16"
#endif
