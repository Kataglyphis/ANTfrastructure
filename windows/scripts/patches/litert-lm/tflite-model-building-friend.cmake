
# [LiteRTLM-winfix model_building-friend] see build-litert-lm-from-source.ps1
set(_lrtlm_mb "${TENSORFLOW_SOURCE_DIR}/tensorflow/lite/core/model_building.h")
if(EXISTS "${_lrtlm_mb}")
    file(READ "${_lrtlm_mb}" _lrtlm_mbc)
    string(REPLACE "class [[nodiscard]] Buffer {" "class Helper;\nclass Tensor;\nclass [[nodiscard]] Buffer {" _lrtlm_mbc "${_lrtlm_mbc}")
    file(WRITE "${_lrtlm_mb}" "${_lrtlm_mbc}")
    message(STATUS "[LiteRTLM-winfix] forward-declared Helper/Tensor before Buffer in model_building.h")
endif()
