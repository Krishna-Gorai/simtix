/* lanes.h - warp width for the synchronisation kernels (C preprocessor, .S files).
   build.py passes -DLANES=<L> (default 8); LOG2L = log2(LANES). */
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
