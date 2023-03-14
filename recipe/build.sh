#!/bin/bash

set -exuo pipefail

if [[ "${PKG_NAME}" == 'onnxruntime-novec' ]]; then
    DONT_VECTORIZE="ON"
else
    DONT_VECTORIZE="OFF"
fi

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == '1' ]]; then
    BUILD_UNIT_TESTS="OFF"
else
    BUILD_UNIT_TESTS="ON"
fi

if [[ "${target_platform:-other}" == 'osx-arm64' ]]; then
    ARM_CMAKE="CMAKE_OSX_ARCHITECTURES=arm64"
else
    ARM_CMAKE=""
fi

cmake_extra_defines=( "ONNX_CUSTOM_PROTOC_EXECUTABLE=$BUILD_PREFIX/bin/protoc" \
                      "onnxruntime_USE_COREML=OFF" \
                      "onnxruntime_DONT_VECTORIZE=$DONT_VECTORIZE" \
                      "onnxruntime_BUILD_SHARED_LIB=ON" \
                      "onnxruntime_BUILD_UNIT_TESTS=$BUILD_UNIT_TESTS" \
		      ${ARM_CMAKE}
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
    --compile_no_warning_as_error \
    --enable_lto \
    --build_dir build-ci \
    --cmake_extra_defines "${cmake_extra_defines[@]}" \
    --cmake_generator Ninja \
    --build_wheel \
    --config Release \
    --update \
    --build \
    --skip_submodule_sync \
    --path_to_protoc_exe $BUILD_PREFIX/bin/protoc


cp build-ci/Release/dist/onnxruntime-*.whl onnxruntime-${PKG_VERSION}-py3-none-any.whl
python -m pip install onnxruntime-${PKG_VERSION}-py3-none-any.whl
