# Debug: print all environment variables
print "=== ENVIRONMENT VARIABLES ==="
$env | transpose key value | each {|row| print $"($row.key)=($row.value)"} | ignore
print "=== END ENVIRONMENT VARIABLES ==="

let is_win = ($env.target_platform | str starts-with "win")
let is_linux = ($env.target_platform | str starts-with "linux")
let is_osx = ($env.target_platform | str starts-with "osx")

let cuda_version = ($env.cuda_compiler_version? | default "None")
let cuda_enabled = ($cuda_version != "None")
let cross_compiling = ($env.CONDA_BUILD_CROSS_COMPILATION? | default "0") == "1"

let build_unit_tests = if $cross_compiling or $cuda_enabled { "OFF" } else { "ON" }
let dont_vectorize = if ($env.suffix | str contains "novec") { "ON" } else { "OFF" }

# https://github.com/conda-forge/ctng-compiler-activation-feedstock/issues/143
if $is_linux {
    $env.LDFLAGS = (($env.LDFLAGS? | default "") + " -Wl,-z,noexecstack")
}

# Explicitly provide Python and NumPy paths to cmake. See:
# https://conda-forge.org/docs/how-to/advanced/cross-compilation/#finding-numpy-in-cross-compiled-python-packages-using-cmake
let python_include_dir = (python -c "import sysconfig; print(sysconfig.get_path('include'))" | str trim)
let numpy_include_dir = (python -c "import numpy; print(numpy.get_include())" | str trim)
# $PYTHON points to the host env python which can't run during cross-compilation.
let python_executable = if $cross_compiling { $"($env.BUILD_PREFIX)/bin/python" } else { $env.PYTHON }

let forwarded_cmake_args = ($env.CMAKE_ARGS | split row " ")

mut cmake_defines = ($forwarded_cmake_args | append [
    $"-DCMAKE_PREFIX_PATH=($env.PREFIX)"
    "-DCMAKE_CXX_STANDARD=20"
    "-DCMAKE_INSTALL_LIBDIR=lib"
    "-Donnxruntime_BUILD_SHARED_LIB=ON"
    "-Donnxruntime_DISABLE_RTTI=OFF"
    "-Donnxruntime_ENABLE_LTO=OFF"  # TODO
    "-Donnxruntime_ENABLE_PYTHON=ON"  # Must be enabled to get the dlpack exports
    "-Donnxruntime_USE_KLEIDIAI=ON"
    "-Donnxruntime_USE_SVE=ON"
    $"-Donnxruntime_BUILD_UNIT_TESTS=($build_unit_tests)"
    $"-Donnxruntime_DONT_VECTORIZE=($dont_vectorize)"
    "-DEIGEN_MPL2_ONLY=ON"
    "-DFLATBUFFERS_BUILD_FLATC=OFF"
    $"-DPython_EXECUTABLE:PATH=($python_executable)"
    $"-DPython_INCLUDE_DIR:PATH=($python_include_dir)"
    $"-DPython_NumPy_INCLUDE_DIR=($numpy_include_dir)"
    "-DCMAKE_OSX_ARCHITECTURES=arm64"  # Ignored on non-apple platforms
    "-DTHREADS_PREFER_PTHREAD_FLAG=ON"  # Ensure -pthread is used from the start, avoiding cache invalidation in Python stage
])

if $is_win {
    # https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
    $cmake_defines = ($cmake_defines | append [
        "-DCMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON"
        # Matches what upstream build.py does when enable_msvc_static_runtime is off.
        "-Dprotobuf_MSVC_STATIC_RUNTIME=OFF"
        "-DONNX_USE_MSVC_STATIC_RUNTIME=OFF"
        "-DABSL_MSVC_STATIC_RUNTIME=OFF"
        "-Dgtest_force_shared_crt=ON"
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

# CUDA configuration
if $cuda_enabled {
    let cuda_arch_list = match $cuda_version {
        "12.9" => "70-real;75-real;80-real;86-real;89-real;90-real;100-real;120"
        "13.0" => "75-real;80-real;86-real;89-real;90-real;100-real;120"
        _ => { error make {msg: $"No CUDA architecture list for v($cuda_version). See build-cpp.nu."} }
    }
    $env.NINJAJOBS = "1"

    if $is_win {
        $cmake_defines = ($cmake_defines | append [
            "-Donnxruntime_USE_CUDA=ON"
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
            "-Donnxruntime_USE_CUDA=ON"
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
}

# Configure
cmake -S cmake -B build-ci/Release -G Ninja --compile-no-warning-as-error ...$cmake_defines

# Build
cmake --build build-ci/Release --config Release --parallel $env.CPU_COUNT

# # Run tests
if not $cross_compiling {
   ctest -V -C Release --test-dir build-ci/Release
}

# Install
let lib_prefix = if $is_win { $env.LIBRARY_PREFIX } else { $env.PREFIX }
cmake --install build-ci/Release --prefix $lib_prefix

# Workaround: give Windows time to release file handles before rattler-build
# tries to remove the work directory. See https://github.com/prefix-dev/rattler-build/issues/1431
if $is_win {
    sleep 30sec
}
