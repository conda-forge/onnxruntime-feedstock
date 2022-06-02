#!/bin/bash

set -exuo pipefail

# When checking out onnxruntime using git, these would be put in cmake/external
# as submodules. We replicate that behavior using the "source"s from meta.yaml.
readonly external_dirs=( "eigen" "json" "onnx" "pytorch_cpuinfo" )
readonly external_root="cmake/external"
for external_dir in "${external_dirs[@]}"
do
    dest="${external_root}/${external_dir}"
    if [[ -e "${dest}" ]]; then
        rm -r "${dest}"
    fi
    mv "${external_dir}" "${dest}"
done


pushd "${external_root}/SafeInt/safeint"
ln -s $PREFIX/include/SafeInt.hpp
popd

if [[ "${PKG_NAME}" == 'onnxruntime-novec' ]]; then
    DONT_VECTORIZE="ON"
else
    DONT_VECTORIZE="OFF"
fi

cmake_extra_defines=( "Protobuf_PROTOC_EXECUTABLE=$BUILD_PREFIX/bin/protoc" \
                      "Protobuf_INCLUDE_DIR=$PREFIX/include" \
                      "onnxruntime_PREFER_SYSTEM_LIB=ON" \
                      "onnxruntime_USE_COREML=OFF" \
                      "onnxruntime_DONT_VECTORIZE=$DONT_VECTORIZE" \
                      "onnxruntime_BUILD_SHARED_LIB=ON" \
                      "CMAKE_PREFIX_PATH=$PREFIX" )

# Copy the defines from the "activate" script (e.g. activate-gcc_linux-aarch64.sh)
# into --cmake_extra_defines.
read -a CMAKE_ARGS_ARRAY <<< "${CMAKE_ARGS}"
for cmake_arg in "${CMAKE_ARGS_ARRAY[@]}"
do
    if [[ "${cmake_arg}" == -DCMAKE_SYSTEM_* ]]; then
        # Strip -D prefix
        cmake_extra_defines+=( "${cmake_arg#"-D"}" )
    fi
done


python tools/ci_build/build.py \
    --enable_lto \
    --build_dir build-ci \
    --use_full_protobuf \
    --cmake_extra_defines "${cmake_extra_defines[@]}" \
    --cmake_generator Ninja \
    --build_wheel \
    --config Release \
    --update \
    --build \
    --skip_submodule_sync

cp build-ci/Release/dist/onnxruntime-*.whl onnxruntime-${PKG_VERSION}-py3-none-any.whl
python -m pip install onnxruntime-${PKG_VERSION}-py3-none-any.whl
mkdir -p "${PREFIX}/include"
cp -pr include/onnxruntime "${PREFIX}/include/"

if [[ -n "${OSX_ARCH:+yes}" ]]; then
    install build-ci/Release/libonnxruntime.*dylib "${PREFIX}/lib"
else
    install build-ci/Release/libonnxruntime.so* "${PREFIX}/lib"
fi
