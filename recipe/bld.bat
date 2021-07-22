@echo on

pushd wil\include
move wil %LIBRARY_PREFIX%\include\wil
popd

rd /s /q cmake\external\onnx
if errorlevel 1 exit 1

dir

move onnx cmake\external\onnx
if errorlevel 1 exit 1
rd /s /q cmake\external\eigen
if errorlevel 1 exit 1
move eigen cmake\external\eigen
if errorlevel 1 exit 1
rd /s /q cmake\external\googletest
if errorlevel 1 exit 1
move googletest cmake\external\googletest
if errorlevel 1 exit 1

pushd cmake\external\SafeInt\safeint
if errorlevel 1 exit 1
copy %LIBRARY_PREFIX%\include\SafeInt.hpp .
if errorlevel 1 exit 1
popd

pushd cmake\external\json
if errorlevel 1 exit 1
md single_include
if errorlevel 1 exit 1
md single_include\nlohmann
if errorlevel 1 exit 1
copy %LIBRARY_PREFIX%\include\nlohmann\json.hpp single_include\nlohmann\json.hpp
if errorlevel 1 exit 1
popd

rem Needs eigen 3.4
rem rm -rf cmake/external/eigen
rem pushd cmake/external
rem ln -s $PREFIX/include/eigen3 eigen
rem popd

python tools/ci_build/build.py ^
    --enable_lto ^
    --build_dir build-ci ^
    --use_full_protobuf ^
    --cmake_extra_defines Protobuf_PROTOC_EXECUTABLE=%LIBRARY_PREFIX%/bin/protoc.exe Protobuf_INCLUDE_DIR=%LIBRARY_PREFIX%/include "onnxruntime_PREFER_SYSTEM_LIB=ON" onnxruntime_USE_COREML=OFF CMAKE_PREFIX_PATH=%LIBRARY_PREFIX% CMAKE_INSTALL_PREFIX=%LIBRARY_PREFIX% ^
    --cmake_generator Ninja ^
    --build_wheel ^
    --config Release ^
    --update ^
    --build ^
    --skip_submodule_sync
if errorlevel 1 exit 1

xcopy build-ci\Release\dist\onnxruntime-*.whl onnxruntime-%PKG_VERSION%-py3-none-any.whl
if errorlevel 1 exit 1
python -m pip install onnxruntime-%PKG_VERSION%-py3-none-any.whl
if errorlevel 1 exit 1
