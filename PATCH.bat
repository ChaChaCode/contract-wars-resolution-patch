@echo off
rem Снимаем метку "скачано из интернета" со всех файлов патчера (иначе dnlib.dll не грузится).
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -File | Unblock-File" >nul 2>&1
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Patch-CWResolution.ps1" -GUI
