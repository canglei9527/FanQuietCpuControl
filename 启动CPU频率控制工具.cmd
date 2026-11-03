@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\FanQuietCpuControl.ps1"
endlocal
