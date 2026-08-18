
# [LiteRTLM-winfix model_building-friend] see build-litert-lm-from-source.ps1
include("${CMAKE_CURRENT_LIST_DIR}/patch-assert.cmake")
set(_lrtlm_mb "${TENSORFLOW_SOURCE_DIR}/tensorflow/lite/core/model_building.h")
if(EXISTS "${_lrtlm_mb}")
    file(READ "${_lrtlm_mb}" _lrtlm_mbc)
    patch_replace_required(_lrtlm_mbc "class [[nodiscard]] Buffer {" "class Helper;\nclass Tensor;\nclass [[nodiscard]] Buffer {" "tflite model_building.h: forward-declare Helper/Tensor before Buffer")
    file(WRITE "${_lrtlm_mb}" "${_lrtlm_mbc}")
    message(STATUS "[LiteRTLM-winfix] forward-declared Helper/Tensor before Buffer in model_building.h")
endif()
