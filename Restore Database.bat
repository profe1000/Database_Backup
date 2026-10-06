@echo off
rem Double-click to restore a backup (.bak / .sql / .bacpac) or convert a .sql dump to .bak.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Restore-Launcher.ps1"
