@echo on

:: Enable CUDA support and set CUDA architectures based on CUDA version
if "%cuda_compiler_version%"=="None" (
    set "BUILD_ARGS="
    set "onnxruntime_BUILD_UNIT_TESTS=ON"
    set "CUDA_ARCH_LIST="
) else (
    set "onnxruntime_BUILD_UNIT_TESTS=OFF"
    if "%cuda_compiler_version%"=="12.9" (
        REM SM 100+ (Blackwell) triggers a broken asm in CUDA 12.9 clusterlaunchcontrol.h on Windows, fixed in 13.0
        set "CUDA_ARCH_LIST=70-real;75-real;80-real;86-real;89-real;90-real"
        set "BUILD_ARGS=--use_cuda  --cuda_home %LIBRARY_PREFIX% --cudnn_home %LIBRARY_PREFIX% --nvcc_threads=2 --parallel=8"
    ) else if "%cuda_compiler_version%"=="13.0" (
        set "CUDA_ARCH_LIST=75-real;80-real;86-real;89-real;90-real;100-real;120"
        set "BUILD_ARGS=--use_cuda  --cuda_home %LIBRARY_PREFIX% --cudnn_home %LIBRARY_PREFIX% --nvcc_threads=2 --parallel=8"
    ) else (
        echo No CUDA architecture list exists for CUDA v%cuda_compiler_version%. See bld.bat for information on adding one.
        exit 1
    )
)

:: The C++ unit tests build an onnx_test_data_proto target that imports ONNX's
:: .proto sources. libonnx ships only the generated headers, but the python onnx
:: package ships onnx\onnx-ml.proto in site-packages, so point onnx_SOURCE_DIR there.
set "UNIT_TEST_DEFINES="
if "%onnxruntime_BUILD_UNIT_TESTS%"=="ON" (
    if not exist "%SP_DIR%\onnx\onnx-ml.proto" (
        echo onnx-ml.proto not found in %SP_DIR%\onnx
        exit 1
    )
    set "UNIT_TEST_DEFINES=onnx_SOURCE_DIR=%SP_DIR:\=/%"
)

:: regenerate with conda-forge flatc
python onnxruntime\core\flatbuffers\schema\compile_schema.py --flatc "%BUILD_PREFIX%\Library\bin\flatc.exe" --language cpp
if errorlevel 1 exit 1
python onnxruntime\lora\adapter_format\compile_schema.py --flatc "%BUILD_PREFIX%\Library\bin\flatc.exe"
if errorlevel 1 exit 1

:: libprotobuf is a DLL. Its CMake target adds PROTOBUF_USE_DLLS only to targets that
:: link it, but e.g. onnxruntime_flatbuffers includes the onnx .pb.h headers without
:: linking protobuf and then emits protobuf inline functions that clash with the DLL's
:: exports (LNK2005). Define it for every translation unit. Use cl.exe's CL variable:
:: CXXFLAGS is ignored when build.py passes -DCMAKE_CXX_FLAGS (it does for --parallel).
set "CL=/DPROTOBUF_USE_DLLS %CL%"

:: Since 1.29.0 telemetry is opt-out rather than opt-in; a conda-forge package should
:: not report usage to Microsoft, so it is disabled explicitly on every platform.
python tools/ci_build/build.py ^
    --skip_pip_install ^
    --compile_no_warning_as_error ^
    --no_telemetry ^
    --build_dir build-ci ^
    --cmake_extra_defines EIGEN_MPL2_ONLY=ON "onnxruntime_USE_COREML=OFF" "onnxruntime_BUILD_SHARED_LIB=ON" "onnxruntime_BUILD_UNIT_TESTS=%onnxruntime_BUILD_UNIT_TESTS%" CMAKE_PREFIX_PATH=%LIBRARY_PREFIX% CMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% "onnxruntime_USE_FULL_PROTOBUF=ON" CMAKE_CUDA_ARCHITECTURES=%CUDA_ARCH_LIST% %UNIT_TEST_DEFINES% ^
    --cmake_generator Ninja ^
    --build_wheel ^
    --config Release ^
    --update ^
    --build ^
    --skip_submodule_sync ^
    --path_to_protoc_exe "%BUILD_PREFIX%\Library\bin\protoc.exe" ^
    %BUILD_ARGS%
if errorlevel 1 exit 1

:: Run only the C++ unit tests, as on unix: build.py's python test phase is brittle
:: against the unvendored onnx. The host Library\bin (onnx, protobuf, abseil DLLs)
:: is already on PATH.
if "%onnxruntime_BUILD_UNIT_TESTS%"=="ON" (
    ctest --test-dir build-ci\Release --output-on-failure --parallel %CPU_COUNT% --timeout 10800
    if errorlevel 1 exit 1
)

:: Install the project into cwd.
:: This is needed only to produce the exported CMake targets.
cmake --install build-ci/Release --prefix "install-ci"

:: In theory there should be only one wheel
for %%F in (build-ci\Release\dist\onnxruntime*.whl) do (
    python -m pip install %%F
    if errorlevel 1 exit 1
)
