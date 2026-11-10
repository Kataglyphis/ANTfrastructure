// SPDX-License-Identifier: MIT
// Isolated registration and legacy-mode checks cannot prove adapter availability or inference.
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include WEBGPU_ORT_C_API_HEADER

#define PROVIDER "WebGpuExecutionProvider"
#define MISSING "Execution provider library: " PROVIDER " was not registered."

typedef struct {
  void *library;
  const OrtApi *api;
  OrtEnv *env;
  char version[128];
} Probe;

static int error(const char *message) {
  fprintf(stderr, "WEBGPU-NATIVE FAIL: %s\n", message);
  return 1;
}

static int status_error(Probe *probe, OrtStatus *status, const char *operation) {
  if (!status) return 0;
  const char *message = probe->api->GetErrorMessage(status);
  fprintf(stderr, "WEBGPU-NATIVE FAIL: %s: %s\n", operation, message ? message : "missing status message");
  probe->api->ReleaseStatus(status);
  return 1;
}

static int require_missing(Probe *probe, OrtStatus *status) {
  if (!status) return error("negative control unexpectedly unregistered a factory");
  const char *message = probe->api->GetErrorMessage(status);
  int failed = probe->api->GetErrorCode(status) != ORT_FAIL || !message || strcmp(message, MISSING) != 0;
  if (failed) fprintf(stderr, "WEBGPU-NATIVE FAIL: unexpected negative control: %s\n", message ? message : "missing message");
  probe->api->ReleaseStatus(status);
  return failed;
}

static int required_api(const OrtApi *api) {
  return api && api->GetErrorCode && api->GetErrorMessage && api->ReleaseStatus && api->CreateEnv &&
    api->ReleaseEnv && api->GetAvailableProviders && api->ReleaseAvailableProviders &&
    api->UnregisterExecutionProviderLibrary;
}

static int open_core(Probe *probe, const char *path) {
  probe->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!probe->library) return error(dlerror());
  void *symbol = dlsym(probe->library, "OrtGetApiBase");
  if (!symbol) return error("the explicit core has no OrtGetApiBase");
  const OrtApiBase *(*entry)(void) = NULL;
  _Static_assert(sizeof(entry) == sizeof(symbol), "Linux function pointers must match dlsym pointers");
  memcpy(&entry, &symbol, sizeof(entry));
  const OrtApiBase *base = entry();
  if (!base || !base->GetApi || !base->GetVersionString) return error("missing C API base");
  probe->api = base->GetApi(ORT_API_VERSION);
  if (!required_api(probe->api)) return error("missing required C API exports");
  const char *version = base->GetVersionString();
  if (!version || !*version || strlen(version) >= sizeof(probe->version)) return error("invalid core version");
  memcpy(probe->version, version, strlen(version) + 1);
  return 0;
}

static int compiled_providers(Probe *probe) {
  char **providers = NULL;
  int count = 0, cpu = 0, failed = 0;
  if (status_error(probe, probe->api->GetAvailableProviders(&providers, &count), "GetAvailableProviders")) return 1;
  if (!providers || count <= 0 || count > 1024) {
    failed = error("invalid compiled-provider list");
  } else {
    for (int index = 0; index < count; ++index) {
      if (!providers[index] || !*providers[index]) { failed = error("empty compiled-provider entry"); continue; }
      if (strcmp(providers[index], "CPUExecutionProvider") == 0) ++cpu;
      if (strcmp(providers[index], PROVIDER) == 0) failed = error("legacy internal WebGPU provider is still compiled in");
    }
    if (cpu != 1) failed = error("compiled-provider list must retain exactly one CPU provider");
  }
  if (providers && status_error(probe, probe->api->ReleaseAvailableProviders(providers, count), "ReleaseAvailableProviders")) failed = 1;
  return failed;
}

static int registration(Probe *probe, int enabled) {
  if (status_error(probe, probe->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "webgpu-factory-probe", &probe->env), "CreateEnv")) return 1;
  if (!probe->env) return error("CreateEnv returned no environment");
  OrtStatus *status = probe->api->UnregisterExecutionProviderLibrary(probe->env, PROVIDER);
  if (enabled) {
    if (status_error(probe, status, "first UnregisterExecutionProviderLibrary")) return 1;
  } else if (require_missing(probe, status)) {
    return 1;
  }
  return require_missing(probe, probe->api->UnregisterExecutionProviderLibrary(probe->env, PROVIDER));
}

static int cleanup(Probe *probe, int failed) {
  if (probe->env) probe->api->ReleaseEnv(probe->env);
  if (probe->library && dlclose(probe->library) != 0) { error("dlclose failed"); failed = 1; }
  return failed;
}

int main(int argc, char **argv) {
  if (argc != 3 || argv[1][0] != '/' || (strcmp(argv[2], "ON") != 0 && strcmp(argv[2], "OFF") != 0)) {
    fprintf(stderr, "Usage: ort-webgpu-factory-probe /absolute/core.so ON|OFF\n");
    return 2;
  }
  Probe probe = {0};
  int failed = open_core(&probe, argv[1]);
  if (!failed) failed = compiled_providers(&probe);
  if (!failed) failed = registration(&probe, strcmp(argv[2], "ON") == 0);
  failed = cleanup(&probe, failed);
  if (!failed && printf("WEBGPU-NATIVE OK: mode=%s api=%u version=%s\n", argv[2], (unsigned)ORT_API_VERSION, probe.version) < 0) return 1;
  return failed;
}
