// Host C API linkage and observable pipeline construction do not prove numerical GPU execution.
#include <mlir-c/Dialect/MIGraphX.h>
#include <mlir-c/IR.h>
#include <mlir-c/RegisterRocMLIR.h>

#include <iostream>
#include <string>
#include <string_view>

static_assert(MLIR_MIGRAPHX_DIALECT_API_VERSION == ROCMLIR_REQUIRED_API_VERSION);

static void append_pipeline(MlirStringRef text, void *output) {
  if (text.length > 0)
    static_cast<std::string *>(output)->append(text.data, static_cast<std::size_t>(text.length));
}

int main() {
  const auto registry = mlirDialectRegistryCreate();
  if (registry.ptr == nullptr)
    return 3;
  mlirRegisterRocMLIRDialects(registry);
  mlirRegisterRocMLIRPasses();
  const auto context = mlirContextCreateWithRegistry(registry, false);
  mlirDialectRegistryDestroy(registry);
  if (mlirContextIsNull(context))
    return 3;
  const auto dialect = mlirDialectHandleLoadDialect(mlirGetDialectHandle__migraphx__(), context);
  bool valid = !mlirDialectIsNull(dialect);
  std::string pipeline;
  if (valid) {
    const auto name = mlirDialectGetNamespace(dialect);
    valid = name.data != nullptr && name.length == 8 && std::string_view(name.data, 8) == "migraphx";
  }
  if (valid) {
    const auto manager = mlirPassManagerCreate(context);
    valid = !mlirPassManagerIsNull(manager);
    if (valid) {
      mlirMIGraphXAddHighLevelPipeline(manager);
      mlirPrintPassPipeline(mlirPassManagerGetAsOpPassManager(manager), append_pipeline, &pipeline);
      mlirPassManagerDestroy(manager);
    }
  }
  mlirContextDestroy(context);
  if (!valid || pipeline.find("migraphx-to-tosa") == std::string::npos)
    return 3;
  std::cout << "ROCMLIR API: version=" << MLIR_MIGRAPHX_DIALECT_API_VERSION
            << " dialect=migraphx pipeline=migraphx-to-tosa\n" << std::flush;
  return std::cout ? 0 : 4;
}
