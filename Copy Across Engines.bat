@echo off
rem Double-click to copy a database between SQL Server and PostgreSQL.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Copy-AcrossEngines.ps1"
