let is_win = ($env.target_platform | str starts-with "win")
let is_linux = ($env.target_platform | str starts-with "linux")
let cross_compiling = ($env.CONDA_BUILD_CROSS_COMPILATION? | default "0") == "1"

# https://github.com/conda-forge/ctng-compiler-activation-feedstock/issues/143
if $is_linux {
    $env.LDFLAGS = (($env.LDFLAGS? | default "") + " -Wl,-z,noexecstack")
}

# Workaround: rattler-build sets CFLAGS/CXXFLAGS/LDFLAGS with $BUILD_PREFIX paths
# instead of $PREFIX paths during cross-compilation. See build-cpp.nu for details.
for flag_name in [CFLAGS CXXFLAGS LDFLAGS DEBUG_CFLAGS DEBUG_CXXFLAGS] {
    let val = ($env | get --optional $flag_name | default "")
    if ($val | str contains $env.BUILD_PREFIX) {
       load-env {($flag_name): ($val | str replace --all $env.BUILD_PREFIX $env.PREFIX)}
    }
}

# Explicitly provide Python and NumPy paths to cmake. See:
# https://conda-forge.org/docs/how-to/advanced/cross-compilation/#finding-numpy-in-cross-compiled-python-packages-using-cmake
let python_include_dir = (python -c "import sysconfig; print(sysconfig.get_path('include'))" | str trim)
let numpy_include_dir = (python -c "import numpy; print(numpy.get_include())" | str trim)
# $PYTHON points to the host env python which can't run during cross-compilation.
let python_executable = if $cross_compiling { $"($env.BUILD_PREFIX)/bin/python" } else { $env.PYTHON }

# Only forward cross-compilation and platform flags from CMAKE_ARGS.
# See build-cpp.nu for rationale.
let forwarded_cmake_args = ($env.CMAKE_ARGS | split row " " | where {|it|
    ($it | str starts-with "-DCMAKE_SYSTEM_") or ($it | str starts-with "-DCMAKE_OSX_")
})

mut cmake_defines = ($forwarded_cmake_args | append [
    "-DCMAKE_BUILD_TYPE=Release"
    $"-DCMAKE_PREFIX_PATH=($env.PREFIX)"
    "-DCMAKE_CXX_STANDARD=17"
    "-DCMAKE_INSTALL_LIBDIR=lib"
    $"-DPython_EXECUTABLE:PATH=($python_executable)"
    $"-DPython_INCLUDE_DIR:PATH=($python_include_dir)"
    $"-DPython_NumPy_INCLUDE_DIR=($numpy_include_dir)"
])

if $is_win {
    # https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
    $cmake_defines = ($cmake_defines | append "-DCMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON")
}

# Configure
cmake -S cmake -B build-ci/Release -G Ninja --compile-no-warning-as-error ...$cmake_defines

# Build only the pybind11 module (links against already-installed libonnxruntime)
cmake --build build-ci/Release --target onnxruntime_pybind11_state --config Release --parallel $env.CPU_COUNT

# Remove shared library from Python tree (belongs to onnxruntime-cpp)
if $is_win {
    for f in (glob "build-ci/Release/onnxruntime/capi/onnxruntime_conda*") { rm $f }
} else {
    for f in (glob "build-ci/Release/onnxruntime/capi/libonnxruntime*") { rm $f }
}

# Build the wheel
cd build-ci/Release
python $"($env.SRC_DIR)/setup.py" bdist_wheel

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
