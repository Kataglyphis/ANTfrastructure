// This tiny binding checks the selected headers and interpreter, not MIGraphX or GPU inference.
#include <pybind11/pybind11.h>

PYBIND11_MODULE(migraphx_python_probe, module) {
  module.def("constant_value", []() { return 42; });
}
