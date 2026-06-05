#!/bin/bash

set -exuo pipefail

BUILD_ARGS="--skip_pip_install --parallel=8"

if [[ "${PKG_NAME}" == 'onnxruntime-novec' ]]; then
    DONT_VECTORIZE="ON"
else
    DONT_VECTORIZE="OFF"
fi

# The C++ unit tests build an onnx_test_data_proto target whose tml.proto
# imports ONNX's .proto source files (onnx/onnx-ml.proto). onnxruntime locates
# them via the cmake variable onnx_SOURCE_DIR. The unvendored conda libonnx
# package ships only the generated headers, but the conda-forge `onnx` (Python)
# package ships the .proto sources under
# $PREFIX/lib/pythonX.Y/site-packages/onnx/, so point onnx_SOURCE_DIR there
# instead of re-vendoring onnx. Disabled only when cross compiling or for the
# CUDA build (no GPU available to run the suite), matching the pre-unvendoring
# behaviour.
ONNX_PROTO_ROOT="$(dirname "$(dirname "$(find "${PREFIX}" -path '*/onnx/onnx-ml.proto' 2>/dev/null | head -1)")")"
# We build and run the C++ unit tests (ctest) but NOT build.py's python test
# phase: that phase runs ONNX conformance + onnxruntime.quantization tooling
# tests which are brittle against the unvendored external onnx (e.g. onnx 1.21
# raises NotImplementedError on a BatchNormalization op shared across the '' and
# 'com.ms.internal.nhwc' domains, and the onnx backend series expects vendored
# test data). The C++ ctest suite is the meaningful unit-test coverage and
# passes against the unvendored onnx. Tests are skipped entirely when cross
# compiling or for the CUDA build (no GPU to run them).
RUN_TESTS_BUILD_PY_OPTIONS=""   # never let build.py run its (python) test phase
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == '1' || "${cuda_compiler_version:-None}" != "None" || -z "${ONNX_PROTO_ROOT}" ]]; then
    echo "Compiled unit tests are disabled"
    BUILD_UNIT_TESTS="OFF"
    RUN_CPP_CTEST="no"
else
    echo "Compiled unit tests are enabled (onnx .proto from ${ONNX_PROTO_ROOT})"
    BUILD_UNIT_TESTS="ON"
    RUN_CPP_CTEST="yes"
fi

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

if [[ "${target_platform}" == "linux-64" ]]; then
    # Enable the OpenVINO execution provider for Intel CPU / iGPU / NPU.
    # onnxruntime locates OpenVINO via find_package(OpenVINO REQUIRED COMPONENTS
    # Runtime ONNX), satisfied by the conda libopenvino-dev package on
    # CMAKE_PREFIX_PATH (=$PREFIX). The "CPU" argument only sets the *default*
    # device; the resulting libonnxruntime_providers_openvino.so is a separately
    # loadable module and the device is chosen at runtime via
    # provider_options={"device_type": "CPU"|"GPU"|"NPU"|"AUTO:GPU,CPU"|...}.
    BUILD_ARGS="${BUILD_ARGS} --use_openvino CPU"
fi

cmake_extra_defines=( "EIGEN_MPL2_ONLY=ON" \
                      "FLATBUFFERS_BUILD_FLATC=OFF" \
                      "onnxruntime_DONT_VECTORIZE=$DONT_VECTORIZE" \
                      "onnxruntime_BUILD_SHARED_LIB=ON" \
                      "onnxruntime_BUILD_UNIT_TESTS=$BUILD_UNIT_TESTS" \
                      "CMAKE_PREFIX_PATH=$PREFIX" \
                      "CMAKE_CXX_STANDARD=20" \
		      "CMAKE_INSTALL_LIBDIR=lib" \
                      "onnxruntime_USE_FULL_PROTOBUF=ON"
)

# When building the unit tests, tell onnxruntime where to find ONNX's .proto
# sources (shipped by the conda `onnx` package) so the onnx_test_data_proto
# target can be generated against the unvendored onnx.
if [[ "${BUILD_UNIT_TESTS}" == "ON" ]]; then
    cmake_extra_defines+=( "onnx_SOURCE_DIR=${ONNX_PROTO_ROOT}" )
fi

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

# regenerate with conda-forge flatc
python onnxruntime/core/flatbuffers/schema/compile_schema.py --flatc "${BUILD_PREFIX}/bin/flatc" --language cpp
python onnxruntime/lora/adapter_format/compile_schema.py --flatc "${BUILD_PREFIX}/bin/flatc"

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

# Run the C++ unit tests directly via ctest (build.py's python test phase is
# intentionally not invoked; see the BUILD_UNIT_TESTS block above). The test
# binaries link the just-built and host shared libs.
if [[ "${RUN_CPP_CTEST}" == "yes" ]]; then
    LD_LIBRARY_PATH="${PREFIX}/lib:${SRC_DIR}/build-ci/Release:${LD_LIBRARY_PATH:-}" \
        ctest --test-dir build-ci/Release --output-on-failure --parallel "${CPU_COUNT:-4}"
fi

# Install the project into cwd.
# This is needed only to produce the exported CMake targets.
cmake --install build-ci/Release --prefix "install-ci"

for whl_file in build-ci/Release/dist/onnxruntime*.whl; do
    python -m pip install "$whl_file"
done
