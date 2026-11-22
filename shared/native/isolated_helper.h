#ifndef ANT_ISOLATED_HELPER_H
#define ANT_ISOLATED_HELPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct ant_helper_outcome {
  int32_t worker;
  int32_t status;
  int32_t timed_out;
  int32_t externally_reaped;
};

// A private worker receipt survives external supervisor reaping.
int ant_run_isolated_helper(const char *path, char *const arguments[],
                            uint32_t timeout_ms,
                            struct ant_helper_outcome *outcome);

#ifdef __cplusplus
}
#endif
#endif
