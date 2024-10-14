#!/bin/bash

set -exuo pipefail

if [[ "${PKG_NAME}" == 'onnxruntime-novec' ]]; then
    DONT_VECTORIZE="ON"
else
    DONT_VECTORIZE="OFF"
fi

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == '1' || "${cuda_compiler_version:-None}" != "None" ]]; then
    echo "Tests are disabled"
    RUN_TESTS_BUILD_PY_OPTIONS=""
    BUILD_UNIT_TESTS="OFF"
else
    echo "Tests are disabled for speed"
    RUN_TESTS_BUILD_PY_OPTIONS=""
    BUILD_UNIT_TESTS="OFF"
    # echo "Tests are enabled"
    # RUN_TESTS_BUILD_PY_OPTIONS="--test"
    # BUILD_UNIT_TESTS="ON"
fi

if [[ "${target_platform:-other}" == 'osx-arm64' ]]; then
    OSX_ARCH="arm64"
else
    OSX_ARCH="x86_64"
fi

if [[ "${target_platform}" == "osx-64" ]]; then
    export CXXFLAGS="${CXXFLAGS} -D_LIBCPP_DISABLE_AVAILABILITY"
fi


if [[ ! -z "${cuda_compiler_version+x}" && "${cuda_compiler_version}" != "None" ]]; then
  if [[ "${cuda_compiler_version}" == 12* ]]; then
    if [[ "${target_platform}" == "linux-64" ]]; then
      export CUDA_HOME="${BUILD_PREFIX}/targets/x86_64-linux"
    elif [[ "${target_platform}" == "linux-aarch64" ]]; then
      export CUDA_HOME="${BUILD_PREFIX}/targets/sbsa-linux"
    else
      echo "CUDA 12 has not been configured for this architecture"
      exit 1
    fi
  fi
  BUILD_ARGS="--use_cuda --cuda_home ${CUDA_HOME} --cudnn_home ${PREFIX} --parallel=1"
  export NINJAJOBS=1
else
  BUILD_ARGS=""
fi

cmake_extra_defines=( "EIGEN_MPL2_ONLY=ON" \
                      "FLATBUFFERS_BUILD_FLATC=OFF" \
                      "onnxruntime_USE_COREML=OFF" \
                      "onnxruntime_DONT_VECTORIZE=$DONT_VECTORIZE" \
                      "onnxruntime_BUILD_SHARED_LIB=ON" \
                      "onnxruntime_BUILD_UNIT_TESTS=$BUILD_UNIT_TESTS" \
                      "CMAKE_PREFIX_PATH=$PREFIX" \
                      "CMAKE_CUDA_ARCHITECTURES=all-major"
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

if [[ "$PKG_NAME" != *cpp ]]; then
    echo "CMakeCache.txt.orig -----------------------------------------"
    cat build-ci/Release/CMakeCache.txt.orig
    echo "CMakeCache.txt.orig -----------------------------------------"
    sed  "s/python3\.12/python${PY_VER}/g" build-ci/Release/CMakeCache.txt.orig > build-ci/Release/CMakeCache.txt
    sed -i.bak "s/v3\.12/v${PY_VER}/g" build-ci/Release/CMakeCache.txt
    sed -i.bak "s/PYTHON_VERSION_MINOR:INTERNAL=12/PYTHON_VERSION_MINOR:INTERNAL=${PY_VER#*.}/g" build-ci/Release/CMakeCache.txt
    sed -i.bak "s/PYTHON_VERSION:INTERNAL=3.12/PYTHON_VERSION:INTERNAL=${PY_VER}/g" build-ci/Release/CMakeCache.txt
    sed -i.bak "s/cpython-312/cpython-${PY_VER%.*}${PY_VER#*.}/g" build-ci/Release/CMakeCache.txt

    echo "CMakeCache.txt ----------------------------------------------"
    cat build-ci/Release/CMakeCache.txt
    echo "CMakeCache.txt ----------------------------------------------"
fi

BUILD_ARGS="--compile_no_warning_as_error ${BUILD_ARGS}"
BUILD_ARGS="--enable_lto ${BUILD_ARGS}"
BUILD_ARGS="--build_dir build-ci ${BUILD_ARGS}"
BUILD_ARGS="--cmake_generator Ninja ${BUILD_ARGS}"
BUILD_ARGS="--build_wheel ${BUILD_ARGS}"
BUILD_ARGS="--config Release ${BUILD_ARGS}"
BUILD_ARGS="--update ${BUILD_ARGS}"
BUILD_ARGS="--build ${RUN_TESTS_BUILD_PY_OPTIONS} ${BUILD_ARGS}"
BUILD_ARGS="--skip_submodule_sync ${BUILD_ARGS}"
BUILD_ARGS="--osx_arch $OSX_ARCH ${BUILD_ARGS}"
BUILD_ARGS="--path_to_protoc_exe $BUILD_PREFIX/bin/protoc ${BUILD_ARGS}"


# Repeating the command twice seems to resolve things for megabuilds...
# So if it fails the first time, run it again
python tools/ci_build/build.py \
    --cmake_extra_defines "${cmake_extra_defines[@]}" \
    ${BUILD_ARGS} || \
python tools/ci_build/build.py \
    --cmake_extra_defines "${cmake_extra_defines[@]}" \
    ${BUILD_ARGS}

if [[ "$PKG_NAME" == *cpp ]]; then
    # Copy the original build-ci/Release/CMakeCache.txt so we can modify it
    cp build-ci/Release/CMakeCache.txt build-ci/Release/CMakeCache.txt.orig
    mkdir -p "${PREFIX}/include"
    mkdir -p "${PREFIX}/lib"
    cp -pr include/onnxruntime "${PREFIX}/include/"

    if [[ "${target_platform}" == osx-* ]]; then
            install build-ci/Release/libonnxruntime.*dylib "${PREFIX}/lib"
    else
        install build-ci/Release/libonnxruntime.so* "${PREFIX}/lib"
        if [[ ! -z "${cuda_compiler_version+x}" && "${cuda_compiler_version}" != "None" ]]; then
            install build-ci/Release/libonnxruntime_providers_shared.so* "${PREFIX}/lib"
            install build-ci/Release/libonnxruntime_providers_cuda.so* "${PREFIX}/lib"
        fi
    fi
fi
