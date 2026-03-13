#!/bin/bash

set -exuo pipefail

if [[ "${PKG_NAME}" == *'-novec'* ]]; then
    DONT_VECTORIZE="ON"
else
    DONT_VECTORIZE="OFF"
fi

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == '1' || "${cuda_compiler_version:-None}" != "None" ]]; then
    echo "Tests are disabled"
    BUILD_UNIT_TESTS="OFF"
else
    echo "Tests are enabled"
    BUILD_UNIT_TESTS="ON"
fi

# Work around transient macOS dyld bug where hardlinked binaries resolve
# @rpath against the pkgs cache instead of the environment (conda-forge/cmake-feedstock#230).
if [[ "$(uname)" == "Darwin" ]]; then
    export DYLD_FALLBACK_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
fi

if [[ "${target_platform}" == "linux-64" || "${target_platform}" == "linux-aarch64" ]]; then
    # https://github.com/conda-forge/ctng-compiler-activation-feedstock/issues/143
    # Explicitly force non-executable stack to fix compatibility with glibc 2.41, due to:
    # onnxruntime/capi/onnxruntime_pybind11_state.so: cannot enable executable stack as shared object requires: Invalid argument
    LDFLAGS+=" -Wl,-z,noexecstack"
fi

# Collect cmake defines, starting with flags that deviate from onnxruntime defaults.
cmake_defines=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_PREFIX_PATH="$PREFIX"
    -DCMAKE_CXX_STANDARD=17
    -DCMAKE_INSTALL_LIBDIR=lib
    -DONNX_CUSTOM_PROTOC_EXECUTABLE="$BUILD_PREFIX/bin/protoc"
    -DPython_EXECUTABLE="$PREFIX/bin/python"
    # Non-default onnxruntime options
    -Donnxruntime_BUILD_SHARED_LIB=ON
    -Donnxruntime_DISABLE_RTTI=OFF
    # -Donnxruntime_ENABLE_LTO=ON TODO: re-enable lto
    -Donnxruntime_ENABLE_PYTHON=ON
    -Donnxruntime_USE_KLEIDIAI=ON
    -Donnxruntime_USE_SVE=ON
    -Donnxruntime_BUILD_UNIT_TESTS="OFF"  # "$BUILD_UNIT_TESTS"
    -Donnxruntime_DONT_VECTORIZE="$DONT_VECTORIZE"
    # License compliance / conda-forge specifics
    -DEIGEN_MPL2_ONLY=ON
    -DFLATBUFFERS_BUILD_FLATC=OFF
)

if [[ "${target_platform:-other}" == 'osx-arm64' ]]; then
    cmake_defines+=( -DCMAKE_OSX_ARCHITECTURES=arm64 )
fi

# CUDA configuration
if [[ ! -z "${cuda_compiler_version+x}" && "${cuda_compiler_version}" != "None" ]]; then
    case ${cuda_compiler_version} in
        12.9)
            CUDA_ARCH_LIST="70-real;75-real;80-real;86-real;89-real;90-real;100-real;120"
            ;;
        13.0)
            CUDA_ARCH_LIST="75-real;80-real;86-real;89-real;90-real;100-real;120"
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
    export NINJAJOBS=1
    cmake_defines+=(
        -Donnxruntime_USE_CUDA=ON
        -Donnxruntime_CUDA_HOME="$CUDA_HOME"
        -Donnxruntime_CUDNN_HOME="$PREFIX"
        -DCMAKE_CUDA_COMPILER="$BUILD_PREFIX/bin/nvcc"
        -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH_LIST"
    )
fi

case "${PKG_NAME}" in
  onnxruntime*-cpp)
    # ============================================================
    # C++ build (runs once with Python 3.12)
    # ============================================================

    # Configure
    cmake -S cmake -B build-ci/Release \
        -G Ninja \
        --compile-no-warning-as-error \
        ${CMAKE_ARGS} \
        "${cmake_defines[@]}"

    # Build
    cmake --build build-ci/Release --config Release -j${CPU_COUNT}

    # Run tests (only for native, non-CUDA builds)
    if [[ "$BUILD_UNIT_TESTS" == "ON" ]]; then
        ctest -V -C Release --test-dir build-ci/Release/
    fi

    # Export cmake targets (for install-ci/lib/cmake/onnxruntime)
    cmake --install build-ci/Release --prefix "install-ci"

    # Save CMake cache for Python rebuilds
    cp build-ci/Release/CMakeCache.txt build-ci/Release/CMakeCache.txt.orig

    # Install C++ artifacts to $PREFIX
    mkdir -p "${PREFIX}/include"
    mkdir -p "${PREFIX}/lib/cmake"
    cp -pr include/onnxruntime "${PREFIX}/include/"
    cp -pr install-ci/lib/cmake/onnxruntime "${PREFIX}/lib/cmake/"

    if [[ -n "${OSX_ARCH:+yes}" ]]; then
        install build-ci/Release/libonnxruntime.*dylib "${PREFIX}/lib"
    else
        install build-ci/Release/libonnxruntime.so* "${PREFIX}/lib"
        if [[ ! -z "${cuda_compiler_version+x}" && "${cuda_compiler_version}" != "None" ]]; then
            install build-ci/Release/libonnxruntime_providers_shared.so* "${PREFIX}/lib"
            install build-ci/Release/libonnxruntime_providers_cuda.so* "${PREFIX}/lib"
        fi
    fi
    ;;

  onnxruntime*)
    # ============================================================
    # Python rebuild (runs per Python version)
    # ============================================================

    # Determine target Python version
    PY_VER=$(python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    PY_MAJOR="${PY_VER%.*}"
    PY_MINOR="${PY_VER#*.}"

    # Make a copy to avoid polluting the build dir with re-generated protobuf files
    zip -q -r build-ci.zip build-ci

    # Patch CMake cache: replace Python 3.12 references with target version
    sed "s/3\.12/${PY_VER}/g" build-ci/Release/CMakeCache.txt.orig > build-ci/Release/CMakeCache.txt
    sed -i.bak "s/3;12/${PY_MAJOR};${PY_MINOR}/g" build-ci/Release/CMakeCache.txt
    sed -i.bak "s/cpython-312/cpython-${PY_MAJOR}${PY_MINOR}/g" build-ci/Release/CMakeCache.txt

    # Delete old wheel
    rm -f build-ci/Release/dist/onnxruntime*.whl

    # Rebuild: ninja detects the patched CMakeCache.txt and automatically
    # triggers a cmake reconfigure before building. This uses the original
    # configure arguments stored in the cache, avoiding any re-checks that
    # a fresh cmake invocation with new -D flags would cause.
    cmake --build build-ci/Release --config Release -j${CPU_COUNT}

    # Build wheel
    pushd build-ci/Release
    python "${SRC_DIR}/setup.py" bdist_wheel
    popd

    # Install the rebuilt wheel
    for whl_file in build-ci/Release/dist/onnxruntime*.whl; do
        python -m pip install "$whl_file"
    done
    # restore the build dir from the -cpp stage
    rm -rf build-ci
    unzip -q build-ci.zip -d .

    ;;
esac
