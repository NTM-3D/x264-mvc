/* x264 MVC CLI extension. GPL-2.0-or-later; x264 project contributors. */
#ifndef X264_MVC_CLI_H
#define X264_MVC_CLI_H
#include <stdint.h>
#include "x264.h"
#ifdef __cplusplus
extern "C" {
#endif
/* MVC options never change the default AVC encoding path. */
typedef struct {
    int enabled;
    int layout; /* 0=sbs, 1=top-bottom, 2=alternating frames, 3=separate */
    unsigned prediction_mask; /* I=1, P=2, B=4 */
    const char *right_filename;
    const char *dependent_filename;
    const char *output_filename;
    int user_fps;
    int requested_frames;
} x264_mvc_cli_opts_t;
/* Returns 0 (picture read), 1 (EOF), -1 (read error). */
typedef int (*x264_mvc_read_picture)( void *opaque, x264_picture_t *picture, int64_t frame, int right );
int x264_mvc_cli_encode( const x264_param_t *param, const x264_mvc_cli_opts_t *opt,
                         x264_mvc_read_picture read_picture, void *opaque );
#ifdef __cplusplus
}
#endif
#endif
