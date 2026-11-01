#include "dxgi_adapter.h"

#include <stddef.h>

enum { KG_DXGI_SOFTWARE = 2, KG_DXGI_MAX_ADAPTERS = 32 };

int kg_dxgi_select(kg_dxgi_enumerate enumerate, void *context, uint32_t vendor_id, uint32_t *index) {
  uint32_t selected = 0;
  uint64_t most_memory = 0;
  int found = 0;
  if (enumerate == NULL || index == NULL || vendor_id == 0) return KG_DXGI_ERROR;
  for (uint32_t i = 0; i <= KG_DXGI_MAX_ADAPTERS; ++i) {
    struct kg_dxgi_adapter adapter = {0, 0, 0};
    int result = enumerate(context, i, &adapter);
    if (result == 0) {
      if (!found) return KG_DXGI_NO_MATCH;
      *index = selected;
      return KG_DXGI_OK;
    }
    if (result != 1 || i == KG_DXGI_MAX_ADAPTERS) return KG_DXGI_ERROR;
    if (adapter.vendor_id == vendor_id && !(adapter.flags & KG_DXGI_SOFTWARE) &&
        (!found || adapter.dedicated_video_memory > most_memory)) {
      found = 1;
      selected = i;
      most_memory = adapter.dedicated_video_memory;
    }
  }
  return KG_DXGI_ERROR;
}

#ifdef _WIN32
#define CINTERFACE
#define COBJMACROS
#include <windows.h>
#include <dxgi.h>

static int kg_dxgi_next(void *context, uint32_t index, struct kg_dxgi_adapter *out) {
  IDXGIFactory1 *factory = (IDXGIFactory1 *)context;
  IDXGIAdapter1 *adapter = NULL;
  HRESULT result = IDXGIFactory1_EnumAdapters1(factory, index, &adapter);
  if (result == DXGI_ERROR_NOT_FOUND) return 0;
  if (FAILED(result) || adapter == NULL) return -1;
  DXGI_ADAPTER_DESC1 desc;
  result = IDXGIAdapter1_GetDesc1(adapter, &desc);
  IDXGIAdapter1_Release(adapter);
  if (FAILED(result)) return -1;
  out->vendor_id = desc.VendorId;
  out->flags = desc.Flags;
  out->dedicated_video_memory = (uint64_t)desc.DedicatedVideoMemory;
  return 1;
}

int kg_dxgi_select_vendor(uint32_t vendor_id, uint32_t *index) {
  static const GUID factory_iid = {0x770aae78, 0xf26f, 0x4dba, {0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87}};
  IDXGIFactory1 *factory = NULL;
  if (vendor_id == 0 || index == NULL) return KG_DXGI_ERROR;
#ifdef __cplusplus
  HRESULT result = CreateDXGIFactory1(factory_iid, (void **)&factory);
#else
  HRESULT result = CreateDXGIFactory1(&factory_iid, (void **)&factory);
#endif
  if (FAILED(result) || factory == NULL) return KG_DXGI_ERROR;
  int status = kg_dxgi_select(kg_dxgi_next, factory, vendor_id, index);
  IDXGIFactory1_Release(factory);
  return status;
}
#else
int kg_dxgi_select_vendor(uint32_t vendor_id, uint32_t *index) {
  (void)vendor_id;
  (void)index;
  return KG_DXGI_ERROR;
}
#endif
