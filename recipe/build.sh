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

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == '1' || (! -z "${cuda_compiler_version+x}" && "${cuda_compiler_version}" != "None") ]]; then
    echo "Tests are disabled"
    RUN_TESTS_BUILD_PY_OPTIONS=""
else
    echo "Tests are enabled"
    RUN_TESTS_BUILD_PY_OPTIONS="--test"
fi

if [[ "${target_platform:-other}" == 'osx-arm64' ]]; then
    OSX_ARCH="arm64"
else
    OSX_ARCH="x86_64"
fi

if [[ ! -z "${cuda_compiler_version+x}" && "${cuda_compiler_version}" != "None" ]]; then
  BUILD_ARGS="--use_cuda --cuda_home ${CUDA_HOME} --cudnn_home ${PREFIX}"
else
  BUILD_ARGS=""
fi

cmake_extra_defines=( "EIGEN_MPL2_ONLY=ON" \
		      "FLATBUFFERS_BUILD_FLATC=OFF" \
	              "onnxruntime_USE_COREML=OFF" \
                      "onnxruntime_DONT_VECTORIZE=$DONT_VECTORIZE" \
                      "onnxruntime_BUILD_SHARED_LIB=ON" \
                      "onnxruntime_BUILD_UNIT_TESTS=$BUILD_UNIT_TESTS" \
                      "CMAKE_PREFIX_PATH=$PREFIX"
		    )

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
    --build ${RUN_TESTS_BUILD_PY_OPTIONS} \
    --skip_submodule_sync \
    --osx_arch $OSX_ARCH \
    --path_to_protoc_exe $BUILD_PREFIX/bin/protoc \
    ${BUILD_ARGS}

for whl_file in build-ci/Release/dist/onnxruntime*.whl; do
    python -m pip install "$whl_file"
done
