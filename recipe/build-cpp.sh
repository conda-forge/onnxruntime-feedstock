#!/bin/bash
# Build the CPU-only libonnxruntime C++ package with upstream's build.py
# driver. This is a standalone build (no staging/cache sharing with the
# Python variants): Python bindings and unit tests are disabled, so it is
# considerably cheaper than the python builds. CUDA support is provided by
# the separate onnxruntime-ep-cuda plugin package, loadable from C++ via
# Env::RegisterExecutionProviderLibrary.

set -exuo pipefail

# Use every core: the namespace runners kill sessions at 8h and the previous
# hard-coded --parallel=8 left half of the 16-core runners idle.
BUILD_ARGS="--skip_pip_install --parallel=${CPU_COUNT:-0}"

if [[ "${PKG_NAME}" == onnxruntime-novec* ]]; then
    DONT_VECTORIZE="ON"
else
    DONT_VECTORIZE="OFF"
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
    LDFLAGS+=" -Wl,-z,noexecstack"
fi

cmake_extra_defines=( "EIGEN_MPL2_ONLY=ON" \
                      "FLATBUFFERS_BUILD_FLATC=OFF" \
                      "onnxruntime_DONT_VECTORIZE=$DONT_VECTORIZE" \
                      "onnxruntime_BUILD_SHARED_LIB=ON" \
                      "onnxruntime_BUILD_UNIT_TESTS=OFF" \
                      "CMAKE_PREFIX_PATH=$PREFIX" \
                      "CMAKE_CXX_STANDARD=20" \
                      "CMAKE_INSTALL_LIBDIR=lib"
)

# Make the core aware of the TensorRT provider-bridge entry points
# (SessionOptionsAppendExecutionProvider_TensorRT_V2, CreateTensorRTProviderOptions,
# and "TensorrtExecutionProvider" in the Python providers= list). This costs nothing:
# it pulls in no TensorRT headers or libraries, only in-tree ones, and does not build
# the EP. Without it the onnxruntime-ep-tensorrt package is reachable only through the
# newer auto-EP selection API; with it the familiar
# providers=["TensorrtExecutionProvider"] spelling works too, once the EP library has
# been registered once (which is what puts its directory on the bridge search path).
# Gated to linux to match where onnxruntime-ep-tensorrt is actually built.
if [[ "${target_platform}" == linux-* ]]; then
    cmake_extra_defines+=( "onnxruntime_USE_TENSORRT_INTERFACE=ON" )
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

# --enable_lto matches the binaries main ships and keeps the pybind11
# bindings reasonably sized (pybind11 depends on LTO for that, per the
# nanobind docs). It roughly triples unix build times, which is affordable
# now that the invalid-UTF-8 gtest hang is fixed.
# Since 1.29.0 telemetry is opt-out rather than opt-in. On non-Windows it pulls the
# Microsoft 1DS SDK (plus vendored curl/mbedTLS) into libonnxruntime and reports usage
# to Microsoft, neither of which belongs in a conda-forge package. Without a vcpkg
# manifest the 1DS target is missing entirely, so the link of libonnxruntime fails.
python tools/ci_build/build.py \
    --compile_no_warning_as_error \
    --no_telemetry \
    --enable_lto \
    --build_dir build-ci \
    --cmake_extra_defines "${cmake_extra_defines[@]}" \
    --cmake_generator Ninja \
    --config Release \
    --update \
    --build \
    --skip_submodule_sync \
    --path_to_protoc_exe $BUILD_PREFIX/bin/protoc \
    ${BUILD_ARGS}

# Install the project into cwd.
# This is needed only to produce the exported CMake targets.
cmake --install build-ci/Release --prefix "install-ci"

# Package the C++ library, headers (nested upstream layout, same as the
# previous conda-build packages) and exported CMake targets.
mkdir -p "${PREFIX}/include"
mkdir -p "${PREFIX}/lib/cmake"
cp -pr include/onnxruntime "${PREFIX}/include/"
cp -pr install-ci/lib/cmake/onnxruntime "${PREFIX}/lib/cmake/"

if [[ -n "${OSX_ARCH:+yes}" ]]; then
    install build-ci/Release/libonnxruntime.*dylib "${PREFIX}/lib"
else
    install build-ci/Release/libonnxruntime.so* "${PREFIX}/lib"
fi

# libonnxruntime_providers_shared is how any "provider bridge" execution provider
# (the TensorRT EP, for one) reaches onnxruntime's internals: the core dlopens it and
# hands it the ProviderHost through Provider_SetHost, and the EP library resolves its
# undefined symbols against it. It is looked up next to the onnxruntime binary, so the
# C++ package has to carry it -- the Python wheel already ships its own copy in capi/.
# Not built on macOS (see onnxruntime_providers_cpu.cmake).
if [[ -z "${OSX_ARCH:+yes}" ]]; then
    install build-ci/Release/libonnxruntime_providers_shared.so "${PREFIX}/lib"
fi
