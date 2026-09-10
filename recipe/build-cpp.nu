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
let dont_vectorize = if (($env.suffix? | default "") | str contains "novec") { "ON" } else { "OFF" }
let prefix_path = if $is_win { $env.LIBRARY_PREFIX } else { $env.PREFIX }

# https://github.com/conda-forge/ctng-compiler-activation-feedstock/issues/143
if $is_linux {
    $env.LDFLAGS = (($env.LDFLAGS? | default "") + " -Wl,-z,noexecstack")
}

# --cmake_extra_defines entries (build.py prepends -D). Only defines build.py does
# not derive itself; mirrors upstream recipe/build.sh.
mut cmake_defines = [
    "EIGEN_MPL2_ONLY=ON"
    "FLATBUFFERS_BUILD_FLATC=OFF"
    $"onnxruntime_DONT_VECTORIZE=($dont_vectorize)"
    $"onnxruntime_BUILD_UNIT_TESTS=($build_unit_tests)"
    $"CMAKE_PREFIX_PATH=($prefix_path)"
    "CMAKE_CXX_STANDARD=20"
    "CMAKE_INSTALL_LIBDIR=lib"
]

# Forward all of conda-forge's CMAKE_ARGS (toolchain, find-root, compiler archiver,
# CUDA enhancements). build.py ignores CMAKE_ARGS, so strip the -D and pass each
# through --cmake_extra_defines. Upstream forwards only -DCMAKE_SYSTEM_*, dropping
# CMAKE_CXX_COMPILER_AR and thus silently disabling --enable_lto.
$cmake_defines ++= ($env.CMAKE_ARGS
    | split row " "
    | where {|a| $a | str starts-with "-D"}
    | each {|a| $a | str substring 2..})

# https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
if $is_win {
    $cmake_defines ++= ["CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON"]
}

# Cross-compilation can't run the host python, so point cmake at the target's
# python/numpy. https://conda-forge.org/docs/how-to/advanced/cross-compilation/#finding-numpy-in-cross-compiled-python-packages-using-cmake
if $cross_compiling {
    let python_include_dir = (python -c "import sysconfig; print(sysconfig.get_path('include'))" | str trim)
    let numpy_include_dir = (python -c "import numpy; print(numpy.get_include())" | str trim)
    $cmake_defines ++= [
        $"Python_EXECUTABLE:PATH=($env.BUILD_PREFIX)/bin/python"
        $"Python_INCLUDE_DIR:PATH=($python_include_dir)"
        $"Python_NumPy_INCLUDE_DIR=($numpy_include_dir)"
    ]
    if $is_linux {
        # glibc has iconv built in, but FindIconv's try_compile can't run when
        # cross-compiling and picks the wrong-arch libiconv from BUILD_PREFIX.
        $cmake_defines ++= ["Iconv_IS_BUILT_IN=TRUE"]
    }
}

# build.py flags; mirrors upstream build.sh / bld.bat. --no_telemetry is required
# since 1.29.0 (telemetry defaults on for native builds). --build_wheel enables the
# pybind11 target that the Python stage later rebuilds.
mut build_py_args = [
    "--build_dir" "build-ci"
    "--config" "Release"
    "--update"  # configure only; cmake --build below does the actual build
    "--cmake_generator" "Ninja"
    "--compile_no_warning_as_error"
    "--enable_lto"
    "--skip_pip_install"
    "--skip_submodule_sync"
    "--no_telemetry"
    "--build_wheel"
]

# CoreML EP, statically linked into libonnxruntime (osx-x86_64 is skipped).
if $is_osx {
    $build_py_args ++= ["--use_coreml" "--osx_arch" "arm64"]
}

if not $is_win {
    $build_py_args ++= ["--path_to_protoc_exe" $"($env.BUILD_PREFIX)/bin/protoc"]
}

if $cuda_enabled {
    let cuda_arch_list = if $is_win {
        match $cuda_version {
            # SM 100+ (Blackwell) hits a broken CUDA 12.9 asm on Windows (32-bit
            # long under MSVC), fixed in 13.0. SM 110 (Thor) is Linux-only.
            "12.9" => "70-real;75-real;80-real;86-real;89-real;90-real"
            "13.0" => "75-real;80-real;86-real;89-real;90-real;100-real;120"
            _ => { error make {msg: $"No CUDA architecture list for v($cuda_version). See build-cpp.nu."} }
        }
    } else {
        match $cuda_version {
            "12.9" => "70-real;75-real;80-real;86-real;89-real;90-real;100-real;120"
            "13.0" => "75-real;80-real;86-real;89-real;90-real;100-real;110-real;120"
            _ => { error make {msg: $"No CUDA architecture list for v($cuda_version). See build-cpp.nu."} }
        }
    }
    $cmake_defines ++= [$"CMAKE_CUDA_ARCHITECTURES=($cuda_arch_list)"]

    if $is_win {
        # nvcc must be on PATH for the cmake --build step. Nushell exposes it as
        # the list `Path`; assigning to `PATH` shadows it and loses cl.exe.
        $env.Path = ($env.Path | prepend $"($env.BUILD_PREFIX)/Library/bin")
        $build_py_args ++= [
            "--use_cuda" "--nvcc_threads=2"
            "--cuda_home" $env.LIBRARY_PREFIX
            "--cudnn_home" $env.LIBRARY_PREFIX
        ]
    } else {
        let cuda_target = match $env.target_platform {
            "linux-64" => "x86_64-linux"
            "linux-aarch64" => "sbsa-linux"
            _ => { error make {msg: $"Unknown CUDA target for ($env.target_platform)"} }
        }
        # nvcc lives in $BUILD_PREFIX/bin, not $CUDA_HOME/bin, in conda-forge CUDA 12.
        $env.CUDA_HOME = $"($env.BUILD_PREFIX)/targets/($cuda_target)"
        # nvcc_threads=1: the 1.29.0 fpA_intB cutlass kernels need several GB per arch;
        # more threads OOM-kill the runners (exit 137).
        $build_py_args ++= [
            "--use_cuda" "--nvcc_threads=1"
            "--cuda_home" $env.CUDA_HOME
            "--cudnn_home" $env.PREFIX
        ]
        $cmake_defines ++= [$"CMAKE_CUDA_COMPILER=($env.BUILD_PREFIX)/bin/nvcc"]
    }
}

# Configure only (--update); build.py generates the cache + Ninja tree.
python tools/ci_build/build.py ...$build_py_args --cmake_extra_defines ...$cmake_defines

# Build and install the C++ library. Limit CPU count to avoid OOMs.
let build_jobs = [($env.CPU_COUNT | into int) 8] | math min
cmake --build build-ci/Release --config Release --parallel $build_jobs

if not $cross_compiling {
    ctest -V -C Release --test-dir build-ci/Release
}

cmake --install build-ci/Release --prefix $prefix_path
