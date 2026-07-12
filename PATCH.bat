@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Patch-CWResolution.ps1" %*
pause
