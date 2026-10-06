@echo off
rem Double-click to add, change, test or remove connections, automatic backups and settings (conn\connections.txt).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Edit-Connections.ps1"
