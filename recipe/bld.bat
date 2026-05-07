@echo on

:: Enable CUDA support and set CUDA architectures based on CUDA version
if "%cuda_compiler_version%"=="None" (
    set "BUILD_ARGS="
    set "onnxruntime_BUILD_UNIT_TESTS=ON"
    set "CUDA_ARCH_LIST="
) else (
    set "onnxruntime_BUILD_UNIT_TESTS=OFF"
    if "%cuda_compiler_version%"=="12.9" (
        :: SM 100+ (Blackwell) triggers a broken asm constraint in CUDA 12.9's clusterlaunchcontrol.h on Windows
        :: (__CUDA_ARCH__ >= 1000 guard); fixed in CUDA 13.0. Use PTX JIT for Blackwell on this toolchain.
        set "CUDA_ARCH_LIST=70-real;75-real;80-real;86-real;89-real;90-real"
        set "BUILD_ARGS=--use_cuda  --cuda_home %LIBRARY_PREFIX% --cudnn_home %LIBRARY_PREFIX% --nvcc_threads=2 --parallel=8"
    ) else if "%cuda_compiler_version%"=="13.0" (
        set "CUDA_ARCH_LIST=75-real;80-real;86-real;89-real;90-real;100-real;120"
        set "BUILD_ARGS=--use_cuda  --cuda_home %LIBRARY_PREFIX% --cudnn_home %LIBRARY_PREFIX% --nvcc_threads=4 --parallel=8"
    ) else (
        echo No CUDA architecture list exists for CUDA v%cuda_compiler_version%. See bld.bat for information on adding one.
        exit 1
    )
)

:: We set CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON as currently we do not want to use
:: protobuf from conda-forge, see https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
python tools/ci_build/build.py ^
    --skip_pip_install ^
    --compile_no_warning_as_error ^
    --build_dir build-ci ^
    --cmake_extra_defines EIGEN_MPL2_ONLY=ON "onnxruntime_USE_COREML=OFF" "onnxruntime_BUILD_SHARED_LIB=ON" "onnxruntime_BUILD_UNIT_TESTS=%onnxruntime_BUILD_UNIT_TESTS%" CMAKE_PREFIX_PATH=%LIBRARY_PREFIX% CMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON CMAKE_CUDA_ARCHITECTURES=%CUDA_ARCH_LIST% ^
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

:: Install the project into cwd.
:: This is needed only to produce the exported CMake targets.
cmake --install build-ci/Release --prefix "install-ci"

:: In theory there should be only one wheel
for %%F in (build-ci\Release\dist\onnxruntime*.whl) do (
    python -m pip install %%F
    if errorlevel 1 exit 1
)
