@echo off
rem Double-click to install what the database tools need (SQL Server Express, SqlPackage, PostgreSQL tools).
rem Anything already installed is skipped.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Install-Dependencies.ps1"
echo.
pause
