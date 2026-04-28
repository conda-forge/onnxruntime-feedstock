let is_win = ($env.target_platform | str starts-with "win")
let is_linux = ($env.target_platform | str starts-with "linux")
let cross_compiling = ($env.CONDA_BUILD_CROSS_COMPILATION? | default "0") == "1"

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

# Only forward cross-compilation and platform flags from CMAKE_ARGS.
# See build-cpp.nu for rationale.
let forwarded_cmake_args = ($env.CMAKE_ARGS  | split row " " )
mut cmake_defines = ($forwarded_cmake_args | append [
    "-DCMAKE_BUILD_TYPE=Release"
    $"-DCMAKE_PREFIX_PATH=($env.PREFIX)"
    "-DCMAKE_CXX_STANDARD=20"
    "-DCMAKE_INSTALL_LIBDIR=lib"
    $"-DPython_EXECUTABLE:PATH=($python_executable)"
    $"-DPython_INCLUDE_DIR:PATH=($python_include_dir)"
    $"-DPython_NumPy_INCLUDE_DIR=($numpy_include_dir)"
])

if $is_win {
    # https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
    $cmake_defines = ($cmake_defines | append "-DCMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON")
}

# Patch CMakeCache.txt: replace the staging Python version (3.13) with the current
# variant's version so FindPython doesn't re-search and trigger unnecessary rebuilds.
# Approach borrowed from pytorch-feedstock.
let py_ver = (python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" | str trim)
let py_major = ($py_ver | split row "." | get 0)
let py_minor = ($py_ver | split row "." | get 1)

let cache_path = "build-ci/Release/CMakeCache.txt"
(open $cache_path
    | str replace --all "3.13" $py_ver
    | str replace --all "3;13" $"($py_major);($py_minor)"
    | str replace --all "cpython-313" $"cpython-($py_major)($py_minor)"
    | save -f $cache_path)

# Force rebuild of the pybind11 module for the current Python version.
for f in (glob "build-ci/Release/onnxruntime_pybind11_state.*") { rm $f }

# Debug: print an absl compile rule BEFORE re-configure
print "=== BEFORE RE-CONFIGURE ==="
^grep -A2 "strings_internal.dir/internal/utf8" build-ci/Release/build.ninja

# Configure
# cmake -S cmake -B build-ci/Release -G Ninja --compile-no-warning-as-error ...$cmake_defines

# Build only the pybind11 module (links against already-installed libonnxruntime)
cmake --build build-ci/Release --target onnxruntime_pybind11_state --config Release --parallel $env.CPU_COUNT -- -d explain

# Debug: print same rule AFTER re-configure
print "=== AFTER RE-CONFIGURE ==="
^grep -A2 "strings_internal.dir/internal/utf8" build-ci/Release/build.ninja

# Remove shared library from Python tree (belongs to onnxruntime-cpp)
if $is_win {
    for f in (glob "build-ci/Release/onnxruntime/capi/onnxruntime_conda*") { rm $f }
} else {
    for f in (glob "build-ci/Release/onnxruntime/capi/libonnxruntime*") { rm $f }
}

# Build the wheel
cd build-ci/Release
let plat_args = if $cross_compiling {
    let plat_name = match $env.target_platform {
        "linux-64" => "linux_x86_64"
        "linux-aarch64" => "linux_aarch64"
        _ => { error make {msg: $"Unknown target platform for wheel: ($env.target_platform)"} }
    }
    [--plat-name $plat_name]
} else {
    []
}

python $"($env.SRC_DIR)/setup.py" bdist_wheel ...$plat_args ...$plat_args

# Install the wheel
pip install ...(glob dist/*.whl) --no-deps --no-build-isolation $"--prefix=($env.PREFIX)"

# Run CPU-relevant Python tests from upstream build.py:
# https://github.com/microsoft/onnxruntime/blob/v1.24.3/tools/ci_build/build.py#L1770-L1904
if not $cross_compiling {
    cd $env.SRC_DIR

    # Deselect tests that need build artifacts we didn't produce or
    # that write to the read-only testdata directory.
    let deselect = [
        --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_register_custom_ops_library
        --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_run_with_adapter
        --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_model_serialization_with_external_initializers_to_directory
        --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_model_serialization_with_original_external_initializers_to_directory
	--deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_register_custom_e_ps_library
    ]

    pytest -v ...$deselect ...[
        onnxruntime/test/python/onnxruntime_test_python.py
        onnxruntime/test/python/onnxruntime_test_python_autoep.py
        onnxruntime/test/python/onnxruntime_test_python_sparse_matmul.py
        onnxruntime/test/python/onnxruntime_test_python_mlops.py
    ]

    # Run separately: global_threadpool sets process-wide state that breaks later tests.
    pytest -v onnxruntime/test/python/onnxruntime_test_python_global_threadpool.py
}
