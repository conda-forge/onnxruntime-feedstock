#!/bin/bash

set -exuo pipefail

mkdir -p "${PREFIX}/include"
mkdir -p "${PREFIX}/lib/cmake"
cp -pr include/onnxruntime "${PREFIX}/include/"
cp -pr install-ci/lib/cmake/onnxruntime "${PREFIX}/lib/cmake/"

# cp -P keeps the versioned symlinks instead of copying the library once per name.
if [[ -n "${OSX_ARCH:+yes}" ]]; then
    cp -P build-ci/Release/libonnxruntime.*dylib "${PREFIX}/lib"
else
    cp -P build-ci/Release/libonnxruntime.so* "${PREFIX}/lib"
    if [[ ! -z "${cuda_compiler_version+x}" && "${cuda_compiler_version}" != "None" ]]; then
        cp -P build-ci/Release/libonnxruntime_providers_shared.so* "${PREFIX}/lib"
        cp -P build-ci/Release/libonnxruntime_providers_cuda.so* "${PREFIX}/lib"
    fi
fi
