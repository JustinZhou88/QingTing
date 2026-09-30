// C declarations of the noise reduction libraries, for Swift
#include <stddef.h>
#include "rnnoise.h"

// C API of DeepFilterNet libDF (see ThirdParty/DeepFilterNet/libDF/src/capi.rs)
typedef struct DFState DFState;
DFState *df_create(const char *path, float atten_lim, const char *log_level);
size_t df_get_frame_length(DFState *st);
void df_set_atten_lim(DFState *st, float lim_db);
void df_set_post_filter_beta(DFState *st, float beta);
float df_process_frame(DFState *st, float *input, float *output);
void df_free(DFState *st);
// QingTing patch (see the end of capi.rs)
void df_set_gain_release(DFState *st, float db_per_frame);
