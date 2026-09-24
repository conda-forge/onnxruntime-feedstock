#!/bin/bash

set -exuo pipefail

# onnxruntime looks for an in-tree execution provider library next to the
# libonnxruntime that loaded it (Env::GetRuntimePath()), which for the python
# package is site-packages/onnxruntime/capi. Installing it there is what makes
# InferenceSession(..., providers=["TensorrtExecutionProvider"]) work with no
# registration call and no patch to onnxruntime.
#
# build.sh removes this library from the core package's capi/ directory, so the
# two packages never both own the path.
install -d "${SP_DIR}/onnxruntime/capi"
install build-ci/Release/libonnxruntime_providers_tensorrt.so "${SP_DIR}/onnxruntime/capi/"
