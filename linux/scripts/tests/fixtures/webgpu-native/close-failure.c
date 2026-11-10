// SPDX-License-Identifier: MIT
// A failing loader cleanup must prevent the native proof's success sentinel.
int dlclose(void *handle) { (void)handle; return 1; }
