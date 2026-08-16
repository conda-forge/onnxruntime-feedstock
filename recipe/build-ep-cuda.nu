# Build the CUDA execution provider as a standalone plugin library
# (onnxruntime_BUILD_CUDA_EP_AS_PLUGIN=ON). The plugin is Python-independent
# and loads into any onnxruntime core >= the version recorded in upstream's
# plugin-ep-cuda/MIN_ONNXRUNTIME_VERSION via the EP plugin API
# (register_execution_provider_library / RegisterExecutionProviderLibrary).
# See docs/cuda_plugin_ep/ in the onnxruntime sources.

let is_win = ($env.target_platform | str starts-with "win")
let is_linux = ($env.target_platform | str starts-with "linux")

let cuda_version = ($env.cuda_compiler_version? | default "None")
if $cuda_version == "None" {
    error make {msg: "build-ep-cuda.nu requires a CUDA variant"}
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
    # The plugin links the internal static libs (framework/graph/mlas/...);
    # the core shared library, Python bindings, and tests are not needed.
    "-Donnxruntime_BUILD_SHARED_LIB=OFF"
    "-Donnxruntime_ENABLE_PYTHON=OFF"
    "-Donnxruntime_BUILD_UNIT_TESTS=OFF"
    "-Donnxruntime_DISABLE_RTTI=OFF"
    "-Donnxruntime_ENABLE_LTO=OFF"
    "-Donnxruntime_USE_KLEIDIAI=ON"
    "-Donnxruntime_USE_SVE=ON"
    "-DEIGEN_MPL2_ONLY=ON"
    "-DFLATBUFFERS_BUILD_FLATC=OFF"
    "-DTHREADS_PREFER_PTHREAD_FLAG=ON"
    # Plugin selection
    "-Donnxruntime_USE_CUDA=ON"
    "-Donnxruntime_BUILD_CUDA_EP_AS_PLUGIN=ON"
    # Without this the plugin reports "<version>-dev"
    $"-Donnxruntime_PLUGIN_EP_VERSION=($env.PKG_VERSION)"
    # One architecture at a time per translation unit. The fpA_intB_gemm/gemv
    # cutlass kernels added in 1.29.0 need several GB each in nvcc, and the arch
    # list below asks for up to eight; anything above ~8 concurrent cicc processes
    # OOM-kills the 16-core/63 GB runners (exit 137).
    "-Donnxruntime_NVCC_THREADS=1"
    # Telemetry is opt-out as of 1.29.0. cmake still defaults the option to OFF,
    # but say so explicitly: a conda-forge package must not report usage.
    "-Donnxruntime_USE_TELEMETRY=OFF"
])

if $is_win {
    # https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
    $cmake_defines = ($cmake_defines | append [
        "-DCMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON"
        # Matches what upstream build.py does when enable_msvc_static_runtime is off.
        "-Dprotobuf_MSVC_STATIC_RUNTIME=OFF"
        "-DONNX_USE_MSVC_STATIC_RUNTIME=OFF"
        "-DABSL_MSVC_STATIC_RUNTIME=OFF"
    ])
} else {
    $cmake_defines = ($cmake_defines | append [
        $"-DONNX_CUSTOM_PROTOC_EXECUTABLE=($env.BUILD_PREFIX)/bin/protoc"
    ])
    if $cross_compiling and $is_linux {
        # On Linux/glibc, iconv is built into libc. During cross-compilation,
        # CMake's FindIconv can't run its try_compile test to detect this and
        # falls back to finding the wrong-architecture libiconv from BUILD_PREFIX.
        $cmake_defines = ($cmake_defines | append "-DIconv_IS_BUILT_IN=TRUE")
    }
}

let cuda_arch_list = if $is_win {
    match $cuda_version {
        # SM 100+ (Blackwell) triggers a broken asm in CUDA 12.9
        # clusterlaunchcontrol.h on Windows (long is 32-bit under MSVC),
        # fixed in 13.0. SM 110 (Thor) is Linux-only.
        "12.9" => "70-real;75-real;80-real;86-real;89-real;90-real"
        "13.0" => "75-real;80-real;86-real;89-real;90-real;100-real;120"
        _ => { error make {msg: $"No CUDA architecture list for v($cuda_version). See build-ep-cuda.nu."} }
    }
} else {
    match $cuda_version {
        "12.9" => "70-real;75-real;80-real;86-real;89-real;90-real;100-real;120"
        "13.0" => "75-real;80-real;86-real;89-real;90-real;100-real;110-real;120"
        _ => { error make {msg: $"No CUDA architecture list for v($cuda_version). See build-ep-cuda.nu."} }
    }
}

if $is_win {
    let build_lib_prefix = $"($env.BUILD_PREFIX)/Library"
    # Add nvcc to PATH so cmake can find it (matches build.py behavior).
    # On Windows nushell exposes the path as a list named `Path`; assigning a
    # string to `PATH` shadows it with a broken value and cl.exe disappears.
    $env.Path = ($env.Path | prepend $"($build_lib_prefix)/bin")
    $cmake_defines = ($cmake_defines | append [
        $"-Donnxruntime_CUDA_HOME=($env.LIBRARY_PREFIX)"
        $"-Donnxruntime_CUDNN_HOME=($env.LIBRARY_PREFIX)"
        $"-DCMAKE_CUDA_ARCHITECTURES=($cuda_arch_list)"
    ])
} else {
    let cuda_target = match $env.target_platform {
        "linux-64" => "x86_64-linux"
        "linux-aarch64" => "sbsa-linux"
        _ => { error make {msg: $"Unknown CUDA target for ($env.target_platform)"} }
    }
    $env.CUDA_HOME = $"($env.BUILD_PREFIX)/targets/($cuda_target)"
    # onnxruntime_CUDA_HOME sets CUDAToolkit_ROOT for find_package(CUDAToolkit).
    # Point it to the host prefix where libcublas-dev etc. install their headers.
    let cuda_toolkit_root = $"($env.PREFIX)/targets/($cuda_target)"
    $cmake_defines = ($cmake_defines | append [
        $"-Donnxruntime_CUDA_HOME=($cuda_toolkit_root)"
        $"-Donnxruntime_CUDNN_HOME=($env.PREFIX)"
        $"-DCMAKE_CUDA_COMPILER=($env.BUILD_PREFIX)/bin/nvcc"
        $"-DCMAKE_CUDA_ARCHITECTURES=($cuda_arch_list)"
        # Once enable_language(CUDA) runs, FindCUDAToolkit derives the toolkit
        # location from nvcc (in BUILD_PREFIX) and ignores CUDAToolkit_ROOT.
        # Explicitly set the include dir to the host prefix where libcublas-dev
        # etc. install their headers.
        $"-DCUDAToolkit_ROOT=($cuda_toolkit_root)"
        $"-DCMAKE_CUDA_TOOLKIT_INCLUDE_DIRECTORIES=($cuda_toolkit_root)/include"
    ])
}

# Configure
cmake -S cmake -B build-ci/Release -G Ninja --compile-no-warning-as-error ...$cmake_defines

# Build only the plugin library; the full install tree is not wanted here.
# Cap concurrency rather than using every core: with one nvcc thread per TU this
# is the number of simultaneous cicc processes, and 16 of them exhausts the
# runner's memory partway through llm/fpA_intB_gemv/dispatcher_*_int4*.cu.
let build_jobs = ([8, ($env.CPU_COUNT | into int)] | math min)
cmake --build build-ci/Release --config Release --parallel $build_jobs --target onnxruntime_providers_cuda_plugin

# Install: only the plugin library ships in this package. cmake --install would
# require every configured target to be built, so copy the artifact directly,
# matching the destinations of upstream's install rule (LIBRARY->lib, RUNTIME->bin).
if $is_win {
    mkdir $"($env.LIBRARY_PREFIX)/bin"
    cp build-ci/Release/onnxruntime_providers_cuda.dll $"($env.LIBRARY_PREFIX)/bin/"
} else {
    mkdir $"($env.PREFIX)/lib"
    cp build-ci/Release/libonnxruntime_providers_cuda.so $"($env.PREFIX)/lib/"
}

# Workaround: give Windows time to release file handles before rattler-build
# tries to remove the work directory. See https://github.com/prefix-dev/rattler-build/issues/1431
if $is_win {
    sleep 30sec
}
