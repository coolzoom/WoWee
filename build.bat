@echo off
REM Convenience wrapper - launches the PowerShell build script.
REM Desktop deps (SDL2, OpenSSL, zlib, GLM, FFmpeg, Vulkan): vcpkg first, then
REM zip/SDK fallback. MSYS2 shells skip this and use pacman packages.
powershell -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
