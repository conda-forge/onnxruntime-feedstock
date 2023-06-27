@echo on

:: Enable CUDA support
if "%cuda_compiler_version%"=="None" (
    set "BUILD_ARGS="
) else (
    set "BUILD_ARGS=--use_cuda --cudnn_home %PREFIX%\Library"
)

:: We set CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON as currently we do not want to use
:: protobuf from conda-forge, see https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
python tools/ci_build/build.py ^
    --compile_no_warning_as_error ^
    --build_dir build-ci ^
    --cmake_extra_defines EIGEN_MPL2_ONLY=ON "onnxruntime_USE_COREML=OFF" "onnxruntime_BUILD_SHARED_LIB=ON" "onnxruntime_BUILD_UNIT_TESTS=ON" CMAKE_PREFIX_PATH=%LIBRARY_PREFIX% CMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON ^
    --cmake_generator Ninja ^
    --build_wheel ^
    --config Release ^
    --update ^
    --build ^
    --skip_submodule_sync ^
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
