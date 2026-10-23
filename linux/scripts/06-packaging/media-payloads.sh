#!/usr/bin/env bash
# Copy and smoke observation use one optional-payload inventory while retaining their distinct coverage.
media_optional_payloads() {
  cat <<'PAYLOADS'
/usr/local/lib/onnxruntime-genai|observe
/usr/local/lib/onnxruntime-gpu|observe
/usr/local/include/tflite|observe
/usr/local/include/absl|copy
/usr/local/include/tensorflow|observe
/usr/local/include/flatbuffers|copy
/usr/local/include/c|copy
/usr/local/lib/pkgconfig/litert.pc|observe
/usr/local/lib/pkgconfig/tensorflow-lite.pc|copy
/usr/local/lib/pkgconfig/tensorflowlite_c.pc|copy
/usr/local/lib/pkgconfig/libvvdec.pc|copy
/usr/local/lib/litert-web|copy
/usr/local/lib/litert-lm-web|copy
/usr/local/lib/onnxruntime-web|copy
PAYLOADS
}
