#include "../dxgi_adapter.h"

#include <assert.h>
#include <stddef.h>

struct fake {
  const struct kg_dxgi_adapter *rows;
  uint32_t count;
  int fail_at;
};

static int enumerate(void *context, uint32_t index, struct kg_dxgi_adapter *out) {
  struct fake *fake = (struct fake *)context;
  if ((int)index == fake->fail_at) return -1;
  if (index >= fake->count) return 0;
  *out = fake->rows[index];
  return 1;
}

int main(void) {
  const struct kg_dxgi_adapter rows[] = {
      {0x8086, 0, 100}, {0x1002, 0, 128}, {0x1002, 2, 999},
      {0x1002, 0, 4096}, {0x1002, 0, 4096}, {0x10de, 0, 8000}};
  struct fake fake = {rows, 6, -1};
  uint32_t index = 99;
  assert(kg_dxgi_select(enumerate, &fake, 0x1002, &index) == KG_DXGI_OK && index == 3);
  assert(kg_dxgi_select(enumerate, &fake, 0x10de, &index) == KG_DXGI_OK && index == 5);
  index = 99;
  assert(kg_dxgi_select(enumerate, &fake, 0x1234, &index) == KG_DXGI_NO_MATCH && index == 99);
  fake.fail_at = 5;
  assert(kg_dxgi_select(enumerate, &fake, 0x1002, &index) == KG_DXGI_ERROR && index == 99);
  assert(kg_dxgi_select(NULL, &fake, 0x1002, &index) == KG_DXGI_ERROR);
  assert(kg_dxgi_select(enumerate, &fake, 0, &index) == KG_DXGI_ERROR);
  assert(kg_dxgi_select(enumerate, &fake, 0x1002, NULL) == KG_DXGI_ERROR);
  struct kg_dxgi_adapter many[33] = {{0, 0, 0}};
  many[0].vendor_id = 0x1002;
  fake.rows = many;
  fake.count = 33;
  fake.fail_at = -1;
  index = 99;
  assert(kg_dxgi_select(enumerate, &fake, 0x1002, &index) == KG_DXGI_ERROR && index == 99);
  fake.count = 32;
  assert(kg_dxgi_select(enumerate, &fake, 0x1002, &index) == KG_DXGI_OK && index == 0);
  return 0;
}
