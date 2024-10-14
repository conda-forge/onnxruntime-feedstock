@echo on

:: Enable CUDA support
if "%cuda_compiler_version%"=="None" (
    set "BUILD_ARGS="
    set "onnxruntime_BUILD_UNIT_TESTS=ON"
    set "CMAKE_CUDA_ARCHITECTURES=all-major"
) else (
    if "%cuda_compiler_version%"=="12.0" (
        set "CMAKE_CUDA_ARCHITECTURES=80;86;90"
    ) else (
        set "CMAKE_CUDA_ARCHITECTURES=all-major"
    )
    set CPU_COUNT=1
    set "BUILD_ARGS=--use_cuda  --cuda_home %LIBRARY_PREFIX% --cudnn_home %LIBRARY_PREFIX% --nvcc_threads=1"
    set onnxruntime_BUILD_UNIT_TESTS=OFF
)

:: We set CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON as currently we do not want to use
:: protobuf from conda-forge, see https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
set "BUILD_ARGS=--compile_no_warning_as_error %BUILD_ARGS%"
set "BUILD_ARGS=--build_dir build-ci %BUILD_ARGS%"
set "BUILD_ARGS=--cmake_generator Ninja %BUILD_ARGS%"
set "BUILD_ARGS=--build_wheel %BUILD_ARGS%"
set "BUILD_ARGS=--config Release %BUILD_ARGS%"
set "BUILD_ARGS=--update %BUILD_ARGS%"
set "BUILD_ARGS=--build %BUILD_ARGS%"
set "BUILD_ARGS=--skip_submodule_sync %BUILD_ARGS%"

:: It seems that the first command is may fail when doing megabuilds, so it fails
:: Run it a second time to get it build
python tools/ci_build/build.py ^
    --cmake_extra_defines EIGEN_MPL2_ONLY=ON "onnxruntime_USE_COREML=OFF" "onnxruntime_BUILD_SHARED_LIB=ON" "onnxruntime_BUILD_UNIT_TESTS=%onnxruntime_BUILD_UNIT_TESTS%" CMAKE_PREFIX_PATH=%LIBRARY_PREFIX% CMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON CMAKE_CUDA_ARCHITECTURES=%CMAKE_CUDA_ARCHITECTURES% ^
    %BUILD_ARGS%
if errorlevel 1 python tools/ci_build/build.py ^
    --cmake_extra_defines EIGEN_MPL2_ONLY=ON "onnxruntime_USE_COREML=OFF" "onnxruntime_BUILD_SHARED_LIB=ON" "onnxruntime_BUILD_UNIT_TESTS=%onnxruntime_BUILD_UNIT_TESTS%" CMAKE_PREFIX_PATH=%LIBRARY_PREFIX% CMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON CMAKE_CUDA_ARCHITECTURES=%CMAKE_CUDA_ARCHITECTURES% ^
    %BUILD_ARGS%
if errorlevel 1 exit 1

if "%cuda_compiler_version%"=="None" (
    python tools/ci_build/build.py --test  --config Release --cmake_generator Ninja --build_dir build-ci
    if errorlevel 1 exit 1
)

:: In theory there should be only one wheel
for %%F in (build-ci\Release\dist\onnxruntime*.whl) do (
    python -m pip install %%F
    if errorlevel 1 exit 1
)
