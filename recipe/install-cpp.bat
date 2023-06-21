@echo off
setlocal enabledelayedexpansion

mkdir "%PREFIX%\Library\include\onnxruntime"
mkdir "%PREFIX%\Library\lib"
mkdir "%PREFIX%\Library\bin"
xcopy /E /I include\onnxruntime "%PREFIX%\Library\include\onnxruntime"
xcopy /Y build-ci\Release\onnxruntime_conda.lib "%PREFIX%\Library\lib\"
xcopy /Y build-ci\Release\onnxruntime_conda.dll "%PREFIX%\Library\bin\"
