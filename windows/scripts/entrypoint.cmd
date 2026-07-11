@echo off
rem Container entrypoint: load the VS developer environment, then run the given
rem command (or an interactive PowerShell when none is given). A launcher script
rem avoids the exec-form quoting hell around the spaces in the VS install path.
call "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=amd64 >nul
rem Fail loudly if the VS env did not load -- otherwise every downstream build fails
rem confusingly with missing cl/link/msbuild instead of one clear message.
if errorlevel 1 (echo [entrypoint] ERROR: VsDevCmd.bat failed with errorlevel %errorlevel% & exit /b 1)
if "%~1"=="" (
  powershell.exe -NoLogo -ExecutionPolicy Bypass
) else (
  %*
)
