// These stateful C API doubles use original declarations and cannot prove vendor implementation or GPU behavior.
#include <mlir-c/Dialect/MIGraphX.h>
#include <mlir-c/IR.h>
#include <mlir-c/RegisterRocMLIR.h>

#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string_view>

namespace {
int token;
bool dialects = false;
bool passes = false;
bool pipeline = false;

bool fault(const char *name) {
  const char *value = std::getenv("ROCMLIR_FIXTURE_FAULT");
  return value != nullptr && std::strcmp(value, name) == 0;
}

void trace(const char *name) {
  if (const char *path = std::getenv("ROCMLIR_FIXTURE_TRACE")) {
    std::ofstream output(path, std::ios::app);
    output << name << '\n';
    output.flush();
    if (!output)
      std::abort();
  }
}
}

extern "C" {
MlirDialectRegistry mlirDialectRegistryCreate() {
  trace("registry");
  return {fault("registry") ? nullptr : &token};
}

void mlirRegisterRocMLIRDialects(MlirDialectRegistry registry) {
  trace("dialects");
  dialects = registry.ptr != nullptr;
}

void mlirRegisterRocMLIRPasses() {
  trace("passes");
  passes = true;
}

MlirContext mlirContextCreateWithRegistry(MlirDialectRegistry registry, bool threaded) {
  trace(threaded ? "threaded-context" : "context");
  return {registry.ptr != nullptr && dialects && passes && !threaded && !fault("context") ? &token : nullptr};
}

void mlirDialectRegistryDestroy(MlirDialectRegistry) { trace("registry-destroy"); }

MlirDialectHandle mlirGetDialectHandle__migraphx__() {
  trace("handle");
  return {&token};
}

MlirDialect mlirDialectHandleLoadDialect(MlirDialectHandle, MlirContext context) {
  trace("load");
  return {context.ptr != nullptr && !fault("dialect") ? &token : nullptr};
}

MlirStringRef mlirDialectGetNamespace(MlirDialect) {
  trace("namespace");
  return {fault("null-name") ? nullptr : (fault("namespace") ? "foreignx" : "migraphx"),
          fault("length") ? 7 : 8};
}

MlirPassManager mlirPassManagerCreate(MlirContext) {
  trace("manager");
  return {fault("manager") ? nullptr : &token};
}

void mlirMIGraphXAddHighLevelPipeline(MlirPassManager) {
  trace("pipeline");
  pipeline = true;
}

MlirOpPassManager mlirPassManagerGetAsOpPassManager(MlirPassManager) {
  trace("as-op");
  return {&token};
}

void mlirPrintPassPipeline(MlirOpPassManager, MlirStringCallback callback, void *state) {
  trace("print");
  for (std::string_view chunk : {"builtin.module(", pipeline && !fault("pipeline") ? "migraphx-to-tosa" : "", ")"})
    callback({chunk.data(), static_cast<std::size_t>(chunk.size())}, state);
}

void mlirPassManagerDestroy(MlirPassManager) { trace("manager-destroy"); }

void mlirContextDestroy(MlirContext) {
  trace("context-destroy");
  if (const char *path = std::getenv("ROCMLIR_FIXTURE_MUTATE_LIBRARY")) {
    std::ofstream output(path, std::ios::app);
    output << "changed by fixture\n";
  }
}
}
