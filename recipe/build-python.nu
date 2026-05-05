let is_win = ($env.target_platform | str starts-with "win")
let is_linux = ($env.target_platform | str starts-with "linux")
let cross_compiling = ($env.CONDA_BUILD_CROSS_COMPILATION? | default "0") == "1"
let cuda_enabled = (($env.cuda_compiler_version? | default "None") != "None")

# https://github.com/conda-forge/ctng-compiler-activation-feedstock/issues/143
if $is_linux {
    $env.LDFLAGS = (($env.LDFLAGS? | default "") + " -Wl,-z,noexecstack")
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

# Build only the pybind11 module (links against already-installed libonnxruntime)
# Add `-- -d explain` to get ninja debug info about invalidated caches
cmake --build build-ci/Release --target onnxruntime_pybind11_state --config Release --parallel $env.CPU_COUNT

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
    mut deselect = [
        --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_register_custom_ops_library
        --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_run_with_adapter
        --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_model_serialization_with_external_initializers_to_directory
        --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_model_serialization_with_original_external_initializers_to_directory
	--deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_register_custom_e_ps_library
    ]

    # Deselect tests that require a CUDA device (CI runners have no GPU)
    if $cuda_enabled {
        $deselect = ($deselect | append [
            --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_get_and_set_tuning_results
            --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_ort_value
            --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_ort_value_gh_issue9799
            --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_set_providers
            --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_set_providers_with_options
            --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_sparse_tensor_coo_format
            --deselect onnxruntime/test/python/onnxruntime_test_python.py::TestInferenceSession::test_sparse_tensor_csr_format
            --deselect onnxruntime/test/python/onnxruntime_test_python_autoep.py::TestAutoEP::test_cuda_ep_register_and_inference
            --deselect onnxruntime/test/python/onnxruntime_test_python_autoep.py::TestAutoEP::test_cuda_ep_selection_delegate_and_inference
        ])
    }

    pytest -v ...$deselect ...[
        onnxruntime/test/python/onnxruntime_test_python.py
        onnxruntime/test/python/onnxruntime_test_python_autoep.py
        onnxruntime/test/python/onnxruntime_test_python_sparse_matmul.py
        onnxruntime/test/python/onnxruntime_test_python_mlops.py
    ]

    # Run separately: global_threadpool sets process-wide state that breaks later tests.
    pytest -v onnxruntime/test/python/onnxruntime_test_python_global_threadpool.py
}
