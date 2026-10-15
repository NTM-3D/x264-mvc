/* Two-view MVC encoding loop for the stock x264 CLI.
 * GPL-2.0-or-later; x264 project contributors. No JMVC code is included. */
#include "cli.h"
#include "nal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

typedef struct { x264_t *encoder; x264_param_t param; } mvc_view_t;

static int mvc_open( mvc_view_t *view, const x264_param_t *source, unsigned mask,
                     int dependent, int width, int height )
{
    view->param = *source;
    x264_param_t *p = &view->param;
    p->i_width = width;
    p->i_height = height;
    p->i_csp = X264_CSP_I420;
    p->i_sps_id = dependent ? 1 : 0;
    p->b_mvc_force_high = 1;
    p->b_mvc_inter_view = dependent && mask;
    p->b_mvc_inter_view_i = dependent && !!(mask & 1);
    p->b_mvc_inter_view_p = dependent && !!(mask & 2);
    p->b_mvc_inter_view_b = dependent && !!(mask & 4);
    p->b_full_recon = !dependent && !!mask;
    p->b_annexb = 1;
    p->b_repeat_headers = 0;
    p->b_open_gop = 0;
    p->i_bframe_adaptive = X264_B_ADAPT_NONE;
    p->i_scenecut_threshold = 0;
    if( mask ) p->b_sliced_threads = 1;
    if( dependent && mask ) p->analyse.i_weighted_pred = X264_WEIGHTP_NONE;
    if( p->b_interlaced || p->b_fake_interlaced ||
        p->i_frame_reference > 8 || p->i_dpb_size > 8 ||
        x264_param_apply_profile( p, "high" ) )
        return -1;
    view->encoder = x264_encoder_open( p );
    return view->encoder ? 0 : -1;
}

static void mvc_copy_region( x264_picture_t *dst, const x264_picture_t *src,
                             int x, int y, int w, int h )
{
    for( int p = 0; p < 3; ++p )
    {
        int div = p ? 2 : 1;
        for( int row = 0; row < h/div; ++row )
            memcpy( dst->img.plane[p] + row * dst->img.i_stride[p],
                    src->img.plane[p] + (row + y/div) * src->img.i_stride[p] + x/div,
                    w/div );
    }
}
static int mvc_headers( mvc_view_t *view, FILE *out, int dependent, unsigned mask )
{
    x264_nal_t *nals = NULL;
    int count = 0, level = 40;
    if( x264_encoder_headers( view->encoder, &nals, &count ) < 0 ) return -1;
    for( int i = 0; i < count; ++i ) if( nals[i].i_type == 7 )
    {
        const uint8_t *p = nals[i].p_payload;
        int sc = p[2] == 1 ? 3 : 4;
        if( nals[i].i_payload > sc + 3 ) level = p[sc+3];
    }
    return x264_mvc_write_nals( out, nals, count, dependent, level, mask );
}
static int mvc_encode_pair( mvc_view_t *base, mvc_view_t *dep, FILE *out, FILE *depout,
                            unsigned mask, x264_picture_t *left, x264_picture_t *right,
                            int64_t *written )
{
    x264_nal_t *base_nal = NULL, *dep_nal = NULL;
    int base_count = 0, dep_count = 0;
    x264_picture_t out_base = {0}, out_dep = {0};
    int base_size = x264_encoder_encode( base->encoder, &base_nal, &base_count, left, &out_base );
    if( base_size < 0 ) return -1;
    if( mask && base_size && x264_encoder_mvc_reference( dep->encoder, &out_base ) ) return -1;
    int dep_size = x264_encoder_encode( dep->encoder, &dep_nal, &dep_count, right, &out_dep );
    if( dep_size < 0 || !!base_size != !!dep_size ) return -1;
    if( base_size )
    {
        if( out_base.i_pts != out_dep.i_pts || out_base.i_dts != out_dep.i_dts ||
            out_base.i_type != out_dep.i_type || out_base.b_keyframe != out_dep.b_keyframe )
            return -1;
        if( x264_mvc_write_nals( out, base_nal, base_count, 0, 40, mask ) ||
            x264_mvc_write_nals( depout, dep_nal, dep_count, 1, 40, mask ) )
            return -1;
        ++*written;
    }
    return 0;
}
int x264_mvc_cli_encode( const x264_param_t *param, const x264_mvc_cli_opts_t *opt,
                         x264_mvc_read_picture reader, void *opaque )
{
    int result = -1;
    int allocated = 0;
    int srcw = 0, srch = 0, w = 0, h = 0;
    int64_t submitted = 0, written = 0;
    FILE *output = NULL, *dependent_output = NULL;
    mvc_view_t base = {0}, dependent = {0};
    x264_picture_t src = {0}, src_right = {0}, left = {0}, right = {0};
    x264_param_t settings;
    if( !param || !opt || !reader || !opt->enabled ) goto done;
    /* Multi-pass rate control requires independent per-eye stats files. */
    if( param->rc.b_stat_write || param->rc.b_stat_read ) goto done;
    srcw = param->i_width;
    srch = param->i_height;
    if( param->i_bitdepth != 8 || (param->i_csp & X264_CSP_MASK) != X264_CSP_I420 ||
        srcw <= 0 || srch <= 0 || (srcw & 1) || (srch & 1) || param->b_vfr_input ||
        !param->i_fps_den || !param->i_fps_num ) goto done;
    if( opt->dependent_filename && !strcmp( opt->output_filename, opt->dependent_filename ) ) goto done;
    w = opt->layout == 0 ? srcw/2 : srcw;
    h = opt->layout == 1 ? srch/2 : srch;
    if( (w & 1) || (h & 1) ) goto done;
    settings = *param;
    if( opt->layout == 2 && !opt->user_fps )
    {
        if( settings.i_fps_den > UINT32_MAX/2 ) goto done;
        settings.i_fps_den *= 2;
        settings.i_timebase_num = settings.i_fps_den;
        settings.i_timebase_den = settings.i_fps_num;
    }
    if( opt->requested_frames ) settings.i_frame_total = opt->requested_frames;
    else if( opt->layout == 2 && settings.i_frame_total > 0 ) settings.i_frame_total /= 2;
    if( !opt->output_filename ) goto done;
    output = !strcmp( opt->output_filename, "-" ) ? stdout : fopen( opt->output_filename, "wb" );
    if( !output ) goto done;
    dependent_output = output;
    if( opt->dependent_filename )
    {
        dependent_output = !strcmp( opt->dependent_filename, "-" ) ? stdout :
            fopen( opt->dependent_filename, "wb" );
        if( !dependent_output || dependent_output == output ) goto done;
    }
    if( mvc_open( &base, &settings, opt->prediction_mask, 0, w, h ) ||
        mvc_open( &dependent, &settings, opt->prediction_mask, 1, w, h ) ) goto done;
    if( x264_picture_alloc( &src, X264_CSP_I420, srcw, srch ) ) goto done;
    allocated = 1;
    if( x264_picture_alloc( &src_right, X264_CSP_I420, srcw, srch ) ) goto done;
    allocated = 2;
    if( x264_picture_alloc( &left, X264_CSP_I420, w, h ) ) goto done;
    allocated = 3;
    if( x264_picture_alloc( &right, X264_CSP_I420, w, h ) ) goto done;
    allocated = 4;
    if( mvc_headers( &base, output, 0, opt->prediction_mask ) ||
        mvc_headers( &dependent, dependent_output, 1, opt->prediction_mask ) ) goto done;
    while( !settings.i_frame_total || submitted < settings.i_frame_total )
    {
        int a = reader( opaque, &src, opt->layout == 2 ? 2 * submitted : submitted, 0 );
        if( a < 0 ) goto done;
        if( a > 0 ) break;
        if( opt->layout == 3 || opt->layout == 2 )
        {
            int b = reader( opaque, &src_right, opt->layout == 2 ? 2 * submitted + 1 : submitted,
                            opt->layout == 3 );
            if( b ) goto done;
        }
        if( opt->layout == 0 )
        {
            mvc_copy_region( &left, &src, 0, 0, w, h );
            mvc_copy_region( &right, &src, w, 0, w, h );
        }
        else if( opt->layout == 1 )
        {
            mvc_copy_region( &left, &src, 0, 0, w, h );
            mvc_copy_region( &right, &src, 0, h, w, h );
        }
        else
        {
            mvc_copy_region( &left, &src, 0, 0, w, h );
            mvc_copy_region( &right, &src_right, 0, 0, w, h );
        }
        left.i_pts = right.i_pts = submitted;
        if( mvc_encode_pair( &base, &dependent, output, dependent_output,
                             opt->prediction_mask, &left, &right, &written ) ) goto done;
        submitted++;
    }
    while( x264_encoder_delayed_frames( base.encoder ) )
        if( mvc_encode_pair( &base, &dependent, output, dependent_output,
                             opt->prediction_mask, NULL, NULL, &written ) ) goto done;
    if( x264_encoder_delayed_frames( dependent.encoder ) || written != submitted ||
        fflush( output ) || (dependent_output != output && fflush( dependent_output )) ) goto done;
    fprintf( stderr, "x264 MVC: %" PRId64 " stereo pairs encoded\n", written );
    result = 0;
done:
    if( result ) fprintf( stderr, "x264 [error]: MVC encode failed; verify input layouts and constraints\n" );
    if( allocated >= 4 ) x264_picture_clean( &right );
    if( allocated >= 3 ) x264_picture_clean( &left );
    if( allocated >= 2 ) x264_picture_clean( &src_right );
    if( allocated >= 1 ) x264_picture_clean( &src );
    if( dependent.encoder ) x264_encoder_close( dependent.encoder );
    if( base.encoder ) x264_encoder_close( base.encoder );
    if( dependent_output && dependent_output != stdout && dependent_output != output ) fclose( dependent_output );
    if( output && output != stdout ) fclose( output );
    return result;
}
