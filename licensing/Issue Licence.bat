@echo off
rem For the supplier only: double-click to make a yearly licence.key for a customer (or a renewal).
rem The first time, it also makes your signing key.
if not exist "%USERPROFILE%\DatabaseTools-Licensing\signing-key.xml" (
    echo No signing key yet - making one now ^(one-time setup^).
    echo.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-SigningKey.ps1"
    echo.
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-Licence.ps1"
echo.
pause
