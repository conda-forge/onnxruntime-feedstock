# Build the TensorRT execution provider as a standalone, registerable EP.
#
# Unlike the CUDA EP, upstream has no "TensorRT EP as plugin" mode: not in 1.29.0 and
# not on main. onnxruntime_providers_tensorrt is instead a *provider bridge* library --
# the older mechanism, where the EP shared library resolves onnxruntime's internals at
# runtime through onnxruntime_providers_shared. Two consequences drive this script:
#
#  1. The bridge is an unversioned internal C++ ABI (a ProviderHost vtable handed over by
#     Provider_SetHost), so this package is pinned to the exact onnxruntime build it was
#     compiled against. There is no version negotiation the way the plugin EP API has.
#
#  2. The TensorRT EP does not implement its own CUDA allocator, pinned allocator, GPU
#     data transfer, cast kernels or CUDA error checking -- it calls ProviderHost, which
#     forwards to ProviderInfo_CUDA and dlopens onnxruntime_providers_cuda. So this
#     package must also ship a CUDA provider bridge library. onnxruntime_CUDA_MINIMAL=ON
#     is upstream's own option for exactly this ("Useful for a very minimal TRT build"):
#     memcpy/cast ops only, no cuDNN, no cuBLAS, ~1.6 MB, seconds to build.
#
# Both libraries go into a private directory rather than $PREFIX/lib, because
# onnxruntime-ep-cuda installs its *plugin* under the same onnxruntime_providers_cuda
# name. Patch 0011 teaches onnxruntime to search the directory an EP library was
# registered from, so the two packages coexist.

let is_win = ($env.target_platform | str starts-with "win")
let is_linux = ($env.target_platform | str starts-with "linux")

let cuda_version = ($env.cuda_compiler_version? | default "None")
if $cuda_version == "None" {
    error make {msg: "build-ep-tensorrt.nu requires a CUDA variant"}
}
let cross_compiling = ($env.CONDA_BUILD_CROSS_COMPILATION? | default "0") == "1"

# https://github.com/conda-forge/ctng-compiler-activation-feedstock/issues/143
if $is_linux {
    $env.LDFLAGS = (($env.LDFLAGS? | default "") + " -Wl,-z,noexecstack")
}

let forwarded_cmake_args = ($env.CMAKE_ARGS | split row " ")

let prefix_path = if $is_win { $env.LIBRARY_PREFIX } else { $env.PREFIX }
mut cmake_defines = ($forwarded_cmake_args | append [
    $"-DCMAKE_PREFIX_PATH=($prefix_path)"
    "-DCMAKE_CXX_STANDARD=20"
    "-DCMAKE_INSTALL_LIBDIR=lib"
    # Only the two EP shared libraries are wanted; the core shared library, Python
    # bindings and tests all come from the other outputs of this recipe.
    "-Donnxruntime_BUILD_SHARED_LIB=OFF"
    "-Donnxruntime_ENABLE_PYTHON=OFF"
    "-Donnxruntime_BUILD_UNIT_TESTS=OFF"
    "-Donnxruntime_DISABLE_RTTI=OFF"
    "-Donnxruntime_ENABLE_LTO=OFF"
    "-DEIGEN_MPL2_ONLY=ON"
    "-DFLATBUFFERS_BUILD_FLATC=OFF"
    "-DTHREADS_PREFER_PTHREAD_FLAG=ON"
    # TensorRT
    "-Donnxruntime_USE_TENSORRT=ON"
    # Link the shared libnvonnxparser from the conda-forge TensorRT packages rather than
    # fetching onnx-tensorrt and statically linking nvonnxparser_static.
    "-Donnxruntime_USE_TENSORRT_BUILTIN_PARSER=ON"
    $"-Donnxruntime_TENSORRT_HOME=($prefix_path)"
    # CUDA, in the reduced form the TensorRT EP needs. onnxruntime_USE_CUDA is what
    # enables the CUDA language and the CUDAToolkit lookup; CUDA_MINIMAL keeps
    # onnxruntime_providers_cuda down to allocators, data transfer and cast kernels
    # and drops the cuDNN/cuBLAS dependency entirely.
    "-Donnxruntime_USE_CUDA=ON"
    "-Donnxruntime_CUDA_MINIMAL=ON"
    # These default ON whenever USE_CUDA is set and are not turned off by CUDA_MINIMAL.
    # None of them is reachable from the TensorRT EP, and leaving them on would pull in
    # the cutlass kernel set that makes the CUDA EP build so expensive.
    "-Donnxruntime_USE_FLASH_ATTENTION=OFF"
    "-Donnxruntime_USE_MEMORY_EFFICIENT_ATTENTION=OFF"
    "-Donnxruntime_USE_LEAN_ATTENTION=OFF"
    "-Donnxruntime_USE_FPA_INTB_GEMM=OFF"
    # Telemetry is opt-out as of 1.29.0. cmake still defaults the option to OFF, but say
    # so explicitly: a conda-forge package must not report usage.
    "-Donnxruntime_USE_TELEMETRY=OFF"
])

if $is_win {
    # https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
    $cmake_defines = ($cmake_defines | append [
        "-DCMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON"
        "-Dprotobuf_MSVC_STATIC_RUNTIME=OFF"
        "-DONNX_USE_MSVC_STATIC_RUNTIME=OFF"
        "-DABSL_MSVC_STATIC_RUNTIME=OFF"
    ])
} else {
    $cmake_defines = ($cmake_defines | append [
        $"-DONNX_CUSTOM_PROTOC_EXECUTABLE=($env.BUILD_PREFIX)/bin/protoc"
    ])
    if $cross_compiling and $is_linux {
        # On Linux/glibc, iconv is built into libc. During cross-compilation, CMake's
        # FindIconv can't run its try_compile test to detect this and falls back to
        # finding the wrong-architecture libiconv from BUILD_PREFIX.
        $cmake_defines = ($cmake_defines | append "-DIconv_IS_BUILT_IN=TRUE")
    }
}

# The only CUDA kernels here are the cast/unary-elementwise ops of the minimal CUDA
# provider, so the architecture list costs very little to widen. Kept identical to
# build-ep-cuda.nu so both EPs cover the same hardware.
let cuda_arch_list = if $is_win {
    match $cuda_version {
        "12.9" => "70-real;75-real;80-real;86-real;89-real;90-real"
        "13.0" => "75-real;80-real;86-real;89-real;90-real;100-real;120"
        _ => { error make {msg: $"No CUDA architecture list for v($cuda_version). See build-ep-tensorrt.nu."} }
    }
} else {
    match $cuda_version {
        "12.9" => "70-real;75-real;80-real;86-real;89-real;90-real;100-real;120"
        "13.0" => "75-real;80-real;86-real;89-real;90-real;100-real;110-real;120"
        _ => { error make {msg: $"No CUDA architecture list for v($cuda_version). See build-ep-tensorrt.nu."} }
    }
}

if $is_win {
    let build_lib_prefix = $"($env.BUILD_PREFIX)/Library"
    # Add nvcc to PATH so cmake can find it (matches build.py behavior). On Windows
    # nushell exposes the path as a list named `Path`; assigning a string to `PATH`
    # shadows it with a broken value and cl.exe disappears.
    $env.Path = ($env.Path | prepend $"($build_lib_prefix)/bin")
    $cmake_defines = ($cmake_defines | append [
        $"-Donnxruntime_CUDA_HOME=($env.LIBRARY_PREFIX)"
        $"-DCMAKE_CUDA_ARCHITECTURES=($cuda_arch_list)"
    ])
} else {
    let cuda_target = match $env.target_platform {
        "linux-64" => "x86_64-linux"
        "linux-aarch64" => "sbsa-linux"
        _ => { error make {msg: $"Unknown CUDA target for ($env.target_platform)"} }
    }
    $env.CUDA_HOME = $"($env.BUILD_PREFIX)/targets/($cuda_target)"
    let cuda_toolkit_root = $"($env.PREFIX)/targets/($cuda_target)"
    $cmake_defines = ($cmake_defines | append [
        $"-Donnxruntime_CUDA_HOME=($cuda_toolkit_root)"
        $"-DCMAKE_CUDA_COMPILER=($env.BUILD_PREFIX)/bin/nvcc"
        $"-DCMAKE_CUDA_ARCHITECTURES=($cuda_arch_list)"
        # Once enable_language(CUDA) runs, FindCUDAToolkit derives the toolkit location
        # from nvcc (in BUILD_PREFIX) and ignores CUDAToolkit_ROOT. Explicitly set the
        # include dir to the host prefix where the CUDA -dev packages put their headers.
        $"-DCUDAToolkit_ROOT=($cuda_toolkit_root)"
        $"-DCMAKE_CUDA_TOOLKIT_INCLUDE_DIRECTORIES=($cuda_toolkit_root)/include"
    ])
}

# Configure
cmake -S cmake -B build-ci/Release -G Ninja --compile-no-warning-as-error ...$cmake_defines

# Build only the two EP libraries. Both are small: no cutlass, no cuDNN, no fused
# attention kernels, and the TensorRT EP links onnx/protobuf/abseil statically rather
# than the onnxruntime core.
cmake --build build-ci/Release --config Release --parallel ($env.CPU_COUNT | into int) --target onnxruntime_providers_tensorrt onnxruntime_providers_cuda

# Install into a private directory. cmake --install would require every configured
# target to be built, so copy the artifacts directly.
let ep_dir = if $is_win {
    $"($env.LIBRARY_PREFIX)/lib/onnxruntime-eps/tensorrt"
} else {
    $"($env.PREFIX)/lib/onnxruntime-eps/tensorrt"
}
mkdir $ep_dir

if $is_win {
    cp build-ci/Release/onnxruntime_providers_tensorrt.dll $"($ep_dir)/"
    cp build-ci/Release/onnxruntime_providers_cuda.dll $"($ep_dir)/"
} else {
    cp build-ci/Release/libonnxruntime_providers_tensorrt.so $"($ep_dir)/"
    cp build-ci/Release/libonnxruntime_providers_cuda.so $"($ep_dir)/"
}

# Workaround: give Windows time to release file handles before rattler-build tries to
# remove the work directory. See https://github.com/prefix-dev/rattler-build/issues/1431
if $is_win {
    sleep 30sec
}
