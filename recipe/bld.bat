@echo on

:: Enable CUDA support and set CUDA architectures based on CUDA version
if "%cuda_compiler_version%"=="None" (
    set "onnxruntime_BUILD_UNIT_TESTS=ON"
    set "CUDA_ARCH_LIST="
    set "CUDA_DEFINES="
) else (
    set "onnxruntime_BUILD_UNIT_TESTS=OFF"
    set "NINJAJOBS=1"
    if "%cuda_compiler_version%"=="12.9" (
        set "CUDA_ARCH_LIST=70-real;75-real;80-real;86-real;89-real;90-real;100-real;120"
    ) else if "%cuda_compiler_version%"=="13.0" (
        set "CUDA_ARCH_LIST=75-real;80-real;86-real;89-real;90-real;100-real;120"
    ) else (
        echo No CUDA architecture list exists for CUDA v%cuda_compiler_version%. See bld.bat for information on adding one.
        exit 1
    )
    set "CUDA_DEFINES=-Donnxruntime_USE_CUDA=ON -Donnxruntime_CUDA_HOME=%LIBRARY_PREFIX% -Donnxruntime_CUDNN_HOME=%LIBRARY_PREFIX% -DCMAKE_CUDA_ARCHITECTURES=%CUDA_ARCH_LIST%"
)

:: Check if this is the C++ build or Python rebuild
echo %PKG_NAME% | findstr /C:"-cpp" >nul
if %errorlevel%==0 (
    goto cpp_build
) else (
    goto python_build
)

:cpp_build
:: ============================================================
:: C++ build (runs once with Python 3.12)
:: ============================================================

:: We set CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON as currently we do not want to use
:: protobuf from conda-forge, see https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
cmake -S cmake -B build-ci\Release -G Ninja --compile-no-warning-as-error ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_PREFIX_PATH=%LIBRARY_PREFIX% ^
    -DCMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% ^
    -DCMAKE_CXX_STANDARD=17 ^
    -DPython_EXECUTABLE=%PREFIX%\python.exe ^
    -Donnxruntime_BUILD_SHARED_LIB=ON ^
    -Donnxruntime_DISABLE_RTTI=OFF ^
    -Donnxruntime_ENABLE_LTO=ON ^
    -Donnxruntime_ENABLE_PYTHON=ON ^
    -Donnxruntime_BUILD_UNIT_TESTS=%onnxruntime_BUILD_UNIT_TESTS% ^
    -Donnxruntime_DONT_VECTORIZE=OFF ^
    -DEIGEN_MPL2_ONLY=ON ^
    -DFLATBUFFERS_BUILD_FLATC=OFF ^
    -DCMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON ^
    -DCMAKE_CUDA_ARCHITECTURES=%CUDA_ARCH_LIST% ^
    %CUDA_DEFINES%
if errorlevel 1 exit 1

:: Build
cmake --build build-ci\Release --config Release
if errorlevel 1 exit 1

:: Run tests (only for non-CUDA builds)
if "%cuda_compiler_version%"=="None" (
    ctest -V -C Release --test-dir build-ci\Release\
    if errorlevel 1 exit 1
)

:: Export cmake targets
cmake --install build-ci\Release --prefix "install-ci"
if errorlevel 1 exit 1

:: Save CMake cache for Python rebuilds
copy build-ci\Release\CMakeCache.txt build-ci\Release\CMakeCache.txt.orig

:: Install C++ artifacts to PREFIX
mkdir "%PREFIX%\Library\include\onnxruntime"
mkdir "%PREFIX%\Library\lib\cmake"
mkdir "%PREFIX%\Library\bin"
xcopy /E /I include\onnxruntime "%PREFIX%\Library\include\onnxruntime"
xcopy /E /I install-ci\lib\cmake\onnxruntime "%PREFIX%\Library\lib\cmake\onnxruntime"
xcopy /Y build-ci\Release\onnxruntime_conda.lib "%PREFIX%\Library\lib\"
xcopy /Y build-ci\Release\onnxruntime_conda.dll "%PREFIX%\Library\bin\"

if NOT "%cuda_compiler_version%"=="None" (
    xcopy /Y build-ci\Release\onnxruntime_providers_shared.lib "%PREFIX%\Library\lib\"
    xcopy /Y build-ci\Release\onnxruntime_providers_shared.dll "%PREFIX%\Library\bin\"
    xcopy /Y build-ci\Release\onnxruntime_providers_cuda.lib "%PREFIX%\Library\lib\"
    xcopy /Y build-ci\Release\onnxruntime_providers_cuda.dll "%PREFIX%\Library\bin\"
)

goto :eof

:python_build
:: ============================================================
:: Python rebuild (runs per Python version)
:: ============================================================

:: Determine Python version
for /f "tokens=*" %%i in ('python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"') do set "PY_VER=%%i"
for /f "tokens=1 delims=." %%a in ("%PY_VER%") do set "PY_MAJOR=%%a"
for /f "tokens=2 delims=." %%a in ("%PY_VER%") do set "PY_MINOR=%%a"
set "PY_MAJMIN=%PY_MAJOR%%PY_MINOR%"

:: Patch CMake cache: replace Python 3.12 references with target version
powershell -Command "(Get-Content 'build-ci\Release\CMakeCache.txt.orig') -replace '3\.12','%PY_VER%' -replace '3;12','%PY_MAJOR%;%PY_MINOR%' -replace 'cpython-312','cpython-%PY_MAJMIN%' -replace 'Python312','Python%PY_MAJMIN%' -replace 'python312','python%PY_MAJMIN%' -replace 'python3\.12','python%PY_VER%' -replace 'cp312-win_amd64','cp%PY_MAJMIN%-win_amd64' | Set-Content 'build-ci\Release\CMakeCache.txt'"
if errorlevel 1 exit 1

:: Delete old wheel
del /Q build-ci\Release\dist\onnxruntime*.whl 2>nul

:: Reconfigure with patched cache
cmake -S cmake -B build-ci\Release -G Ninja --compile-no-warning-as-error ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_PREFIX_PATH=%LIBRARY_PREFIX% ^
    -DCMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% ^
    -DCMAKE_CXX_STANDARD=17 ^
    -DPython_EXECUTABLE=%PREFIX%\python.exe ^
    -Donnxruntime_BUILD_SHARED_LIB=ON ^
    -Donnxruntime_DISABLE_RTTI=OFF ^
    -Donnxruntime_ENABLE_LTO=ON ^
    -Donnxruntime_ENABLE_PYTHON=ON ^
    -Donnxruntime_BUILD_UNIT_TESTS=OFF ^
    -Donnxruntime_DONT_VECTORIZE=OFF ^
    -DEIGEN_MPL2_ONLY=ON ^
    -DFLATBUFFERS_BUILD_FLATC=OFF ^
    -DCMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON ^
    -DCMAKE_CUDA_ARCHITECTURES=%CUDA_ARCH_LIST% ^
    %CUDA_DEFINES%
if errorlevel 1 exit 1

:: Rebuild (only pybind11 module changes due to Python version switch)
cmake --build build-ci\Release --config Release
if errorlevel 1 exit 1

:: Build wheel
pushd build-ci\Release
python %SRC_DIR%\setup.py bdist_wheel
if errorlevel 1 exit 1
popd

:: Install the rebuilt wheel
for %%F in (build-ci\Release\dist\onnxruntime*.whl) do (
    python -m pip install %%F
    if errorlevel 1 exit 1
)
