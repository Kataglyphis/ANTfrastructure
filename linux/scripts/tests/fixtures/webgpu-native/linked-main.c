// SPDX-License-Identifier: MIT
// A host-linked fake C ABI exercises the shared verdicts without Emscripten or real ORT.
#include <string.h>
int OrtWebGpuFactoryProbe(int enabled);
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  int mode = strcmp(argv[1], "ON") == 0 ? 1 : (strcmp(argv[1], "OFF") == 0 ? 0 : 2);
  return OrtWebGpuFactoryProbe(mode);
}
