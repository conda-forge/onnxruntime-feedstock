#!/bin/bash

set -exuo pipefail

BUILD_ARGS="--skip_pip_install --parallel=8"

if [[ "${PKG_NAME}" == 'onnxruntime-novec' ]]; then
    DONT_VECTORIZE="ON"
else
    DONT_VECTORIZE="OFF"
fi

# The C++ unit tests build an onnx_test_data_proto target that imports ONNX's
# .proto source files. The unvendored conda-forge libonnx package ships only
# the generated headers, not the .proto sources, so the unit tests cannot be
# built. Skip them; the recipe's own test section still exercises the Python
# package, the C++ consumer test and cmake-package-check.
echo "Compiled unit tests are disabled"
RUN_TESTS_BUILD_PY_OPTIONS=""
BUILD_UNIT_TESTS="OFF"

if [[ "${target_platform:-other}" == 'osx-arm64' ]]; then
    BUILD_ARGS="${BUILD_ARGS} --osx_arch arm64"
    # Enable the CoreML execution provider on Apple Silicon. This sets
    # onnxruntime_USE_COREML=ON; the CoreML EP is statically linked into
    # libonnxruntime and exposed as the "CoreMLExecutionProvider".
    BUILD_ARGS="${BUILD_ARGS} --use_coreml"
fi

if [[ "${target_platform}" == "linux-64" || "${target_platform}" == "linux-aarch64" ]]; then
    # https://github.com/conda-forge/ctng-compiler-activation-feedstock/issues/143
    # Explicitly force non-executable stack to fix compatibility with glibc 2.41, due to:
    # onnxruntime/capi/onnxruntime_pybind11_state.so: cannot enable executable stack as shared object requires: Invalid argument
    LDFLAGS+=" -Wl,-z,noexecstack"
fi

cmake_extra_defines=( "EIGEN_MPL2_ONLY=ON" \
                      "FLATBUFFERS_BUILD_FLATC=OFF" \
                      "onnxruntime_DONT_VECTORIZE=$DONT_VECTORIZE" \
                      "onnxruntime_BUILD_SHARED_LIB=ON" \
                      "onnxruntime_BUILD_UNIT_TESTS=$BUILD_UNIT_TESTS" \
                      "CMAKE_PREFIX_PATH=$PREFIX" \
                      "CMAKE_CXX_STANDARD=20" \
		      "CMAKE_INSTALL_LIBDIR=lib" \
                      `# The conda-forge libonnx (and libprotobuf) are full` \
                      `# protobuf builds, so onnxruntime must link the full` \
                      `# libprotobuf too, not libprotobuf-lite.` \
                      "onnxruntime_USE_FULL_PROTOBUF=ON"
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

# nvcc is at $BUILD_PREFIX/bin, not $CUDA_HOME/bin in conda-forge CUDA 12
if [[ ! -z "${cuda_compiler_version+x}" && "${cuda_compiler_version}" != "None" ]]; then
    case ${cuda_compiler_version} in
	12.9)
            export CUDA_ARCH_LIST="70-real;75-real;80-real;86-real;89-real;90-real;100-real;120"
            ;;
	13.0)
            export CUDA_ARCH_LIST="75-real;80-real;86-real;89-real;90-real;100-real;120"
            ;;
	*)
            echo "No CUDA architecture list exists for CUDA v${cuda_compiler_version}. See build.sh for information on adding one."
	    exit 1
    esac
    case ${target_platform} in
	linux-64)
            CUDA_TARGET=x86_64-linux
            ;;
	linux-aarch64)
            CUDA_TARGET=sbsa-linux
            ;;
	*)
            echo "unknown CUDA arch, edit build.sh"
            exit 1
    esac
    export CUDA_HOME="${BUILD_PREFIX}/targets/${CUDA_TARGET}"
    BUILD_ARGS="${BUILD_ARGS} --use_cuda --cuda_home ${CUDA_HOME} --cudnn_home ${PREFIX} --nvcc_threads=2"
    export NINJAJOBS=1
    cmake_extra_defines+=( "CMAKE_CUDA_COMPILER=${BUILD_PREFIX}/bin/nvcc" \
			   "CMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH_LIST}"
			 )

fi

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
    --path_to_protoc_exe $BUILD_PREFIX/bin/protoc \
    ${BUILD_ARGS}

# Install the project into cwd.
# This is needed only to produce the exported CMake targets.
cmake --install build-ci/Release --prefix "install-ci"

for whl_file in build-ci/Release/dist/onnxruntime*.whl; do
    python -m pip install "$whl_file"
done
