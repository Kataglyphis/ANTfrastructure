// Written by Write-HipMsvcCmathOverlay: MSVC's <cmath> owns these six.
#pragma push_macro("isgreater")
#undef isgreater
#define isgreater __hip_msvc_owned_isgreater
#pragma push_macro("isgreaterequal")
#undef isgreaterequal
#define isgreaterequal __hip_msvc_owned_isgreaterequal
#pragma push_macro("isless")
#undef isless
#define isless __hip_msvc_owned_isless
#pragma push_macro("islessequal")
#undef islessequal
#define islessequal __hip_msvc_owned_islessequal
#pragma push_macro("islessgreater")
#undef islessgreater
#define islessgreater __hip_msvc_owned_islessgreater
#pragma push_macro("isunordered")
#undef isunordered
#define isunordered __hip_msvc_owned_isunordered
#include_next <__clang_hip_cmath.h>
#undef isgreater
#pragma pop_macro("isgreater")
#undef isgreaterequal
#pragma pop_macro("isgreaterequal")
#undef isless
#pragma pop_macro("isless")
#undef islessequal
#pragma pop_macro("islessequal")
#undef islessgreater
#pragma pop_macro("islessgreater")
#undef isunordered
#pragma pop_macro("isunordered")
