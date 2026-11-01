# Native DirectML adapter selection

`dxgi_adapter.c` exposes a C ABI usable by C++ and Rust launchers. Pass a PCI
vendor ID (`0x1002` AMD, `0x10de` NVIDIA) to `kg_dxgi_select_vendor`. It returns
the physical matching DXGI `EnumAdapters1` index with the largest dedicated
video memory; ties keep the lowest index. It fails if enumeration is incomplete
or more than 32 adapters are present. Compile the file into the application and
link Windows `dxgi.lib`; C++-only CMake projects may compile it as C++ via the
source `LANGUAGE` property. Non-Windows calls return an error. The selection is
read-only and does not activate devices.

Call this only when a vendor-specific package chooses its default. Preserve an
explicit user index, and do not change vendor-neutral DirectML or CPU selection.
The API does not validate that the chosen adapter can execute a particular
model; a real DirectML inference profile is still required.

`tests/dxgi_adapter_test.c` exercises the selection with a supplied enumerator;
for example, in a MinGW environment:

```sh
gcc -std=c11 -Wall -Wextra -Werror shared/native/windows/dxgi_adapter.c \
  shared/native/windows/tests/dxgi_adapter_test.c -ldxgi -o dxgi-adapter-test.exe
./dxgi-adapter-test.exe
```

`tests/dxgi_adapter_probe.c` provides an optional read-only AMD hardware
enumeration check; it does not execute inference.
