@echo off
REM VertexPath.cmd - launcher (v1.4)
setlocal
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%VertexPath.ps1"
set "EXTRA_ARGS="
if /I "%~1"=="-debug"  set "EXTRA_ARGS=-Debug"
if /I "%~1"=="--debug" set "EXTRA_ARGS=-Debug"
if /I "%~1"=="/debug"  set "EXTRA_ARGS=-Debug"
if not exist "%SCRIPT_PATH%" (
    echo [VertexPath] Could not find VertexPath.ps1 next to this launcher.
    pause
    exit /b 1
)
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT_PATH%" %EXTRA_ARGS%
    if %ERRORLEVEL%==0 goto :done
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %EXTRA_ARGS%
    goto :done
)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT_PATH%" %EXTRA_ARGS%
if %ERRORLEVEL%==0 goto :done
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %EXTRA_ARGS%
:done
endlocal
