#ifndef KATAGLYPHIS_DXGI_ADAPTER_H
#define KATAGLYPHIS_DXGI_ADAPTER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum kg_dxgi_status {
  KG_DXGI_OK = 0,
  KG_DXGI_NO_MATCH = 1,
  KG_DXGI_ERROR = 2
};

struct kg_dxgi_adapter {
  uint32_t vendor_id;
  uint32_t flags;
  uint64_t dedicated_video_memory;
};

/* Returns 1 for a row, 0 for end, and -1 for an enumeration failure. */
typedef int (*kg_dxgi_enumerate)(void *context, uint32_t index, struct kg_dxgi_adapter *adapter);

/* The output is written only after a complete enumeration succeeds. */
int kg_dxgi_select(kg_dxgi_enumerate enumerate, void *context, uint32_t vendor_id, uint32_t *index);

/* Uses EnumAdapters1, the same index space as DirectML's explicit device ID. */
int kg_dxgi_select_vendor(uint32_t vendor_id, uint32_t *index);

#ifdef __cplusplus
}
#endif
#endif
