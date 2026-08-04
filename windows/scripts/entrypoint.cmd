@echo off
rem Container entrypoint: load the VS developer environment, then run the given
rem command (or an interactive pwsh (PowerShell 7) when none is given). A launcher script
rem avoids the exec-form quoting hell around the spaces in the VS install path.
rem VS major from the baked VISUAL_STUDIO_VERSION Machine env (load-versions.ps1 /
rem versions.env); fall back to 18 for images from older bases without the key.
if not defined VISUAL_STUDIO_VERSION set VISUAL_STUDIO_VERSION=18
rem Two-root probe, mirroring Resolve-VsBuildToolsRoot (WindowsContainerImage.Common.psm1):
rem VS Build Tools can land under either Program Files root -- prefer the 64-bit
rem root, fall back to (x86). Hardcoding only (x86) broke 64-bit-rooted installs.
set "VSDEVCMD=C:\Program Files (x86)\Microsoft Visual Studio\%VISUAL_STUDIO_VERSION%\BuildTools\Common7\Tools\VsDevCmd.bat"
if exist "%ProgramFiles%\Microsoft Visual Studio\%VISUAL_STUDIO_VERSION%\BuildTools\Common7\Tools\VsDevCmd.bat" set "VSDEVCMD=%ProgramFiles%\Microsoft Visual Studio\%VISUAL_STUDIO_VERSION%\BuildTools\Common7\Tools\VsDevCmd.bat"
call "%VSDEVCMD%" -arch=amd64 >nul
rem Fail loudly if the VS env did not load -- otherwise every downstream build fails
rem confusingly with missing cl/link/msbuild instead of one clear message.
if errorlevel 1 (echo [entrypoint] ERROR: VsDevCmd.bat failed with errorlevel %errorlevel% & exit /b 1)
rem clang-cl /fsanitize=address runtime: clang_rt.asan_dynamic-x86_64.dll lives in
rem LLVM's VERSIONED lib\clang\<N>\lib\windows dir, which the baked PATH cannot
rem carry (the version floats with scoop's llvm). Resolve it dynamically so
rem ASAN-instrumented exes run instead of dying STATUS_ENTRYPOINT_NOT_FOUND.
for /d %%v in ("C:\Users\ContainerAdministrator\scoop\apps\llvm\current\lib\clang\*") do if exist "%%v\lib\windows" set "PATH=%%v\lib\windows;%PATH%"
if "%~1"=="" (
  pwsh.exe -NoLogo -ExecutionPolicy Bypass
) else (
  %*
)
