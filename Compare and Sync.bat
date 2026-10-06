@echo off
rem Double-click to compare two databases from conn\connections.txt and sync them.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Compare-Sync.ps1"
