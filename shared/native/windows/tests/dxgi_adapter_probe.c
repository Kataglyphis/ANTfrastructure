#include "../dxgi_adapter.h"

#include <stdio.h>

int main(void) {
  uint32_t index = 0;
  int status = kg_dxgi_select_vendor(0x1002, &index);
  if (status != KG_DXGI_OK) {
    fprintf(stderr, "AMD adapter selection failed: %d\n", status);
    return 1;
  }
  printf("%u\n", index);
  return 0;
}
