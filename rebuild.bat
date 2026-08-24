@echo off
REM Default: MSYS2 MinGW GCC (installs MSYS2 + packages if missing).
REM VS debug tree:  rebuild.bat vs
powershell -ExecutionPolicy Bypass -File "%~dp0rebuild.ps1" %*
