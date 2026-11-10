// SPDX-License-Identifier: MIT
// This fake core records real dlopen/C API calls; no ORT implementation or device is exercised.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "onnxruntime_c_api.h"
struct OrtEnv { int calls; };
struct OrtStatus { OrtErrorCode code; const char *message; };
static OrtEnv environment;
static OrtStatus failure = {ORT_FAIL, "fixture operation failed"};
static OrtStatus missing = {ORT_FAIL, "Execution provider library: WebGpuExecutionProvider was not registered."};
static int scenario(const char *name) {
  const char *value = getenv("WEBGPU_NATIVE_SCENARIO");
  return value && strcmp(value, name) == 0;
}
static void record(const char *value) {
  const char *path = getenv("WEBGPU_NATIVE_LOG");
  if (!path) abort();
  FILE *output = fopen(path, "a");
  if (!output) abort();
  fprintf(output, "%s\n", value);
  if (fclose(output) != 0) abort();
}
static OrtErrorCode code(const OrtStatus *status) { return status->code; }
static const char *message(const OrtStatus *status) { return scenario("null-message") ? NULL : status->message; }
static void release_status(OrtStatus *status) { (void)status; record("RELEASESTATUS"); }
static OrtStatus *create(OrtLoggingLevel level, const char *id, OrtEnv **result) {
  record("CREATEENV");
  if (level != ORT_LOGGING_LEVEL_WARNING || strcmp(id, "webgpu-factory-probe") != 0) return &failure;
  if (scenario("create-failure")) return &failure;
  *result = scenario("null-env") ? NULL : &environment;
  return NULL;
}
static void release_env(OrtEnv *env) { if (env != &environment) abort(); record("RELEASEENV"); }
static OrtStatus *providers(char ***result, int *count) {
  static char *normal[] = {"CPUExecutionProvider"};
  static char *legacy[] = {"CPUExecutionProvider", "WebGpuExecutionProvider"};
  static char *duplicate[] = {"CPUExecutionProvider", "CPUExecutionProvider"};
  static char *foreign[] = {"SomethingExecutionProvider"};
  static char *empty[] = {NULL};
  static char *oversized[1025];
  record("PROVIDERS");
  if (scenario("provider-failure")) return &failure;
  *result = normal; *count = 1;
  if (scenario("legacy")) { *result = legacy; *count = 2; }
  if (scenario("duplicate-cpu")) { *result = duplicate; *count = 2; }
  if (scenario("no-cpu")) *result = foreign;
  if (scenario("null-providers")) *result = NULL;
  if (scenario("empty-list")) *count = 0;
  if (scenario("empty-entry")) *result = empty;
  if (scenario("too-many")) {
    for (int index = 0; index < 1025; ++index) oversized[index] = index == 0 ? normal[0] : foreign[0];
    *result = oversized; *count = 1025;
  }
  return NULL;
}
static OrtStatus *release_providers(char **items, int count) {
  (void)items; (void)count; record("RELEASEPROVIDERS");
  return scenario("release-failure") ? &failure : NULL;
}
static OrtStatus *unregister_factory(OrtEnv *env, const char *name) {
  if (env != &environment || strcmp(name, "WebGpuExecutionProvider") != 0) return &failure;
  record("UNREGISTER");
  ++env->calls;
  if (scenario("off") || scenario("first-missing")) return &missing;
  if (env->calls == 1 || scenario("repeat-success")) return NULL;
  if (scenario("wrong-message")) return &failure;
  if (scenario("wrong-code")) missing.code = ORT_INVALID_ARGUMENT;
  return &missing;
}
static const OrtApi api = {code, message, release_status, create, release_env, providers, release_providers, unregister_factory};
static const OrtApi *get_api(uint32_t version) {
  record("GETAPI");
  if (version != ORT_API_VERSION || scenario("no-api")) return NULL;
  if (scenario("no-unregister")) { static OrtApi broken; broken = api; broken.UnregisterExecutionProviderLibrary = NULL; return &broken; }
  return &api;
}
static const char *version(void) { return scenario("no-version") ? "" : "1.31.1-fixture"; }
const OrtApiBase *OrtGetApiBase(void) {
  static const OrtApiBase base = {get_api, version};
  return scenario("no-base") ? NULL : &base;
}
__attribute__((destructor)) static void closed(void) { record("DLCLOSE"); }
