#!/bin/bash

set -exuo pipefail

mkdir -p "${PREFIX}/include"
mkdir -p "${PREFIX}/lib"
cp -pr include/onnxruntime "${PREFIX}/include/"

if [[ -n "${OSX_ARCH:+yes}" ]]; then
    install build-ci/Release/libonnxruntime.*dylib "${PREFIX}/lib"
else
    install build-ci/Release/libonnxruntime.so* "${PREFIX}/lib"
fi
