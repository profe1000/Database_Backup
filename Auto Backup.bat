@echo off
rem Double-click to run or schedule the automatic backups listed under [autobackup] in conn\connections.txt.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Auto-Backup.ps1"
