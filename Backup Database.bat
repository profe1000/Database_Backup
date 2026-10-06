@echo off
rem Double-click to back up a database to a .bak file.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Backup-Launcher.ps1"
