// C 降噪库给 Swift 用的接口声明
#include <stddef.h>
#include "rnnoise.h"

// DeepFilterNet libDF 的 C API（见 ThirdParty/DeepFilterNet/libDF/src/capi.rs）
typedef struct DFState DFState;
DFState *df_create(const char *path, float atten_lim, const char *log_level);
size_t df_get_frame_length(DFState *st);
void df_set_atten_lim(DFState *st, float lim_db);
void df_set_post_filter_beta(DFState *st, float beta);
float df_process_frame(DFState *st, float *input, float *output);
void df_free(DFState *st);
// 清听补丁（见 capi.rs 末尾）
void df_set_gain_release(DFState *st, float db_per_frame);
