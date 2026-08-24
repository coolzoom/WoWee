@echo off
REM Default: MSYS2 MinGW GCC (installs MSYS2 + packages if missing).
REM VS debug tree:  build.bat vs
REM Env override:   set WOWEE_TOOLCHAIN=vs
powershell -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
