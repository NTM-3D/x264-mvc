/* Annex B MVC NAL adaptation, GPL-2.0-or-later.
 * Original implementation using the published H.264 Annex H syntax. */
#ifndef X264_MVC_NAL_H
#define X264_MVC_NAL_H
#include <stdint.h>
#include <stdio.h>
#include "x264.h"
int x264_mvc_write_nals( FILE *out, const x264_nal_t *nal, int count,
                         int dependent, int level_idc, unsigned prediction_mask );
#endif
