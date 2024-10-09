call %RECIPE_DIR%\build.bat

:: In theory there should be only one wheel
for %%F in (build-ci\Release\dist\onnxruntime*.whl) do (
    python -m pip install %%F
    if errorlevel 1 exit 1

    :: force remove certain file
    del /f %SP_DIR%\onnxruntime\capi\onnxruntime_conda.lib
    del /f %SP_DIR%\onnxruntime\capi\onnxruntime_conda.dll
    if NOT "%cuda_compiler_version%"=="None" (
        del /f %SP_DIR%\onnxruntime\capi\onnxruntime_providers_shared.lib
        del /f %SP_DIR%\onnxruntime\capi\onnxruntime_providers_shared.dll
        del /f %SP_DIR%\onnxruntime\capi\onnxruntime_providers_cuda.lib
        del /f %SP_DIR%\onnxruntime\capi\onnxruntime_providers_cuda.dll
    )
)
