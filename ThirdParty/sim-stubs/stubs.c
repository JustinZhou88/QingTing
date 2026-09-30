// 仅供模拟器预览界面：降噪库的空实现
#include <stddef.h>
typedef struct DFState DFState;
typedef struct DenoiseState DenoiseState;
typedef struct RNNModel RNNModel;
static char dummy[16];
DFState *df_create(const char *p, float a, const char *l) { return (DFState *)dummy; }
size_t df_get_frame_length(DFState *s) { return 480; }
void df_set_atten_lim(DFState *s, float d) {}
void df_set_post_filter_beta(DFState *s, float b) {}
float df_process_frame(DFState *s, float *in, float *out) { for (int i = 0; i < 480; i++) out[i] = in[i]; return 0; }
void df_free(DFState *s) {}
void df_set_gain_release(DFState *s, float d) {}
int rnnoise_get_frame_size(void) { return 480; }
DenoiseState *rnnoise_create(RNNModel *m) { return (DenoiseState *)dummy; }
void rnnoise_destroy(DenoiseState *s) {}
float rnnoise_process_frame(DenoiseState *s, float *out, const float *in) { for (int i = 0; i < 480; i++) out[i] = in[i]; return 0; }
