@echo off
REM Convenience wrapper - launches the PowerShell build script.
REM Desktop deps (SDL2, OpenSSL, zlib, GLM, FFmpeg, Vulkan): reuse anything already
REM installed; otherwise build.ps1 downloads/builds them under extern\ and passes
REM the paths to CMake. MSYS2 shells skip this and use pacman packages.
powershell -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
