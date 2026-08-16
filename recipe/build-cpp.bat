@echo on

:: Build the CPU-only libonnxruntime C++ package with upstream's build.py
:: driver. Standalone build: no Python bindings, no unit tests. CUDA support
:: is provided by the separate onnxruntime-ep-cuda plugin package.

:: Since 1.29.0 telemetry is opt-out rather than opt-in; a conda-forge package should
:: not report usage to Microsoft, so it is disabled explicitly on every platform.
:: --parallel is easy to miss: build.py defaults it to 1, so leaving it off built
:: Windows serially (`cmake --build ... -- -j1`) on a 16-core runner.
:: We set CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON as currently we do not want to use
:: protobuf from conda-forge, see https://github.com/conda-forge/onnxruntime-feedstock/issues/57#issuecomment-1518033552
python tools/ci_build/build.py ^
    --skip_pip_install ^
    --parallel=%CPU_COUNT% ^
    --no_telemetry ^
    --compile_no_warning_as_error ^
    --build_dir build-ci ^
    --cmake_extra_defines EIGEN_MPL2_ONLY=ON "onnxruntime_USE_COREML=OFF" "onnxruntime_BUILD_SHARED_LIB=ON" "onnxruntime_BUILD_UNIT_TESTS=OFF" CMAKE_PREFIX_PATH=%LIBRARY_PREFIX% CMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON ^
    --cmake_generator Ninja ^
    --config Release ^
    --update ^
    --build ^
    --skip_submodule_sync
if errorlevel 1 exit 1

:: Install the project into cwd.
:: This is needed only to produce the exported CMake targets.
cmake --install build-ci/Release --prefix "install-ci"
if errorlevel 1 exit 1

mkdir "%PREFIX%\Library\include\onnxruntime"
mkdir "%PREFIX%\Library\lib\cmake"
mkdir "%PREFIX%\Library\bin"
xcopy /E /I include\onnxruntime "%PREFIX%\Library\include\onnxruntime"
xcopy /E /I install-ci\lib\cmake\onnxruntime "%PREFIX%\Library\lib\cmake\onnxruntime"
xcopy /Y build-ci\Release\onnxruntime_conda.lib "%PREFIX%\Library\lib\"
xcopy /Y build-ci\Release\onnxruntime_conda.dll "%PREFIX%\Library\bin\"
