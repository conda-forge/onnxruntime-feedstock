#!/bin/bash
# Build the CPU-only onnxruntime Python package with upstream's build.py
# driver (same flow the conda-build recipe used). CUDA support is provided by
# the separate onnxruntime-ep-cuda plugin package, so there is no CUDA branch
# here and each Python variant is a comparatively cheap CPU-only build.

set -exuo pipefail

# Use every core: the namespace runners kill sessions at 8h and the previous
# hard-coded --parallel=8 left half of the 16-core runners idle.
BUILD_ARGS="--skip_pip_install --parallel=${CPU_COUNT:-0}"

if [[ "${PKG_NAME}" == onnxruntime-novec* ]]; then
    DONT_VECTORIZE="ON"
else
    DONT_VECTORIZE="OFF"
fi

# The RegexFullMatch.NonUtf8Pattern gtest deliberately writes invalid UTF-8
# to stderr, which kills rattler-build's output reader ("Error reading
# output: stream did not contain valid UTF-8") and stalls the test process
# on a full pipe — the job then hangs until the runner's session cap.
# Same workaround the megabuild recipe used.
export GTEST_FILTER="-RegexFullMatch.NonUtf8Pattern"

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == '1' ]]; then
    echo "Tests are disabled"
    RUN_TESTS_BUILD_PY_OPTIONS=""
    BUILD_UNIT_TESTS="OFF"
else
    echo "Tests are enabled"
    RUN_TESTS_BUILD_PY_OPTIONS="--test"
    BUILD_UNIT_TESTS="ON"
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

cmake_extra_defines=( "EIGEN_MPL2_ONLY=ON" \
                      "FLATBUFFERS_BUILD_FLATC=OFF" \
                      "onnxruntime_DONT_VECTORIZE=$DONT_VECTORIZE" \
                      "onnxruntime_BUILD_SHARED_LIB=ON" \
                      "onnxruntime_BUILD_UNIT_TESTS=$BUILD_UNIT_TESTS" \
                      "CMAKE_PREFIX_PATH=$PREFIX" \
                      "CMAKE_CXX_STANDARD=20" \
                      "CMAKE_INSTALL_LIBDIR=lib"
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

# --enable_lto matches the binaries main ships and keeps the pybind11
# bindings reasonably sized (pybind11 depends on LTO for that, per the
# nanobind docs). It roughly triples unix build times, which is affordable
# now that the invalid-UTF-8 gtest hang is fixed.
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

for whl_file in build-ci/Release/dist/onnxruntime*.whl; do
    python -m pip install "$whl_file" --no-deps --no-build-isolation
done
