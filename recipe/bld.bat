@echo on

:: Enable CUDA support
if "%cuda_compiler_version%"=="None" (
    set "BUILD_ARGS="
    set "onnxruntime_BUILD_UNIT_TESTS=ON"
) else (
    set "BUILD_ARGS=--use_cuda  --cuda_home %LIBRARY_PREFIX% --cudnn_home %LIBRARY_PREFIX% --nvcc_threads=1 --parallel=0"
    set onnxruntime_BUILD_UNIT_TESTS=OFF
)

python ^
    onnxruntime\lora\adapter_format\compile_schema.py ^
    --flatc %LIBRARY_BIN%\flatc.exe --language cpp

python ^
    onnxruntime\core\flatbuffers\schema\compile_schema.py ^
    --flatc %LIBRARY_BIN%\flatc.exe --language cpp

set CMAKE_EXTRA_DEFINES="onnxruntime_USE_VCPKG=ON"
set CMAKE_EXTRA_DEFINES="%CMAKE_EXTRA_DEFINES% EIGEN_MPL2_ONLY=ON"
set CMAKE_EXTRA_DEFINES="%CMAKE_EXTRA_DEFINES% onnxruntime_USE_COREML=OFF"
set CMAKE_EXTRA_DEFINES="%CMAKE_EXTRA_DEFINES% onnxruntime_BUILD_SHARED_LIB=ON"
set CMAKE_EXTRA_DEFINES="%CMAKE_EXTRA_DEFINES% onnxruntime_BUILD_UNIT_TESTS=%onnxruntime_BUILD_UNIT_TESTS%"
set CMAKE_EXTRA_DEFINES="%CMAKE_EXTRA_DEFINES% CMAKE_PREFIX_PATH=%LIBRARY_PREFIX%"
set CMAKE_EXTRA_DEFINES="%CMAKE_EXTRA_DEFINES% CMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX%"
set CMAKE_EXTRA_DEFINES="%CMAKE_EXTRA_DEFINES% CMAKE_CUDA_ARCHITECTURES=50-real;60-real;70-real;75-real;80-real;86-real;89-real;90-real;100-real;120"
:: We set CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON as currently we do not want to use
:: protobuf from conda-forge, see https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
python tools/ci_build/build.py ^
    --compile_no_warning_as_error ^
    --build_dir build-ci ^
    --cmake_extra_defines %CMAKE_EXTRA_DEFINES% ^
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
