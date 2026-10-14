#!/bin/bash

set -exuo pipefail

# onnxruntime looks for provider libraries next to the module that contains it,
# which for the statically linked Python bindings is onnxruntime/capi.
install -D -m 755 build-ci/Release/libonnxruntime_providers_tensorrt.so "${SP_DIR}/onnxruntime/capi/libonnxruntime_providers_tensorrt.so"
