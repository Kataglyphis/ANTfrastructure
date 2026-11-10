// SPDX-License-Identifier: MIT
// A deliberately small test ABI checks transport and verdicts, never compatibility with real ORT.
#ifndef WEBGPU_TEST_API
#define WEBGPU_TEST_API
#include <stdint.h>
#if WEBGPU_COMPILER_FIXTURE != 37 || WEBGPU_SECOND_FLAG != 41
#error The probe lost its owning C compiler flags
#endif
#define ORT_API_VERSION 31
typedef enum { ORT_OK, ORT_FAIL, ORT_INVALID_ARGUMENT } OrtErrorCode;
typedef enum { ORT_LOGGING_LEVEL_WARNING = 2 } OrtLoggingLevel;
typedef struct OrtEnv OrtEnv;
typedef struct OrtStatus OrtStatus;
typedef struct OrtApi {
  OrtErrorCode (*GetErrorCode)(const OrtStatus *);
  const char *(*GetErrorMessage)(const OrtStatus *);
  void (*ReleaseStatus)(OrtStatus *);
  OrtStatus *(*CreateEnv)(OrtLoggingLevel, const char *, OrtEnv **);
  void (*ReleaseEnv)(OrtEnv *);
  OrtStatus *(*GetAvailableProviders)(char ***, int *);
  OrtStatus *(*ReleaseAvailableProviders)(char **, int);
  OrtStatus *(*UnregisterExecutionProviderLibrary)(OrtEnv *, const char *);
} OrtApi;
typedef struct OrtApiBase {
  const OrtApi *(*GetApi)(uint32_t);
  const char *(*GetVersionString)(void);
} OrtApiBase;
#endif
