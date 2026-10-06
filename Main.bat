@echo off
rem Double-click to pick and run any of the other .bat tools in this folder.
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title Database Tools
rem First run (e.g. fresh from git): make conn\connections.txt from the sample.
if not exist "conn\connections.txt" if exist "conn\connections.sample.txt" (
    copy /y "conn\connections.sample.txt" "conn\connections.txt" >nul
    echo conn\connections.txt was missing - a new one was made from connections.sample.txt.
    echo Pick "Edit Connections" and press A to add your databases.
    echo.
    pause
)
:menu
cls
echo ==================================================
echo   DATABASE TOOLS
echo ==================================================
echo.
set n=0
for %%F in (*.bat) do (
    if /i not "%%~nxF"=="%~nx0" (
        set /a n+=1
        set "tool!n!=%%~nxF"
        echo   !n!. %%~nF
    )
)
echo   H. Help (index.html)
echo   Q. Quit
echo.
set "choice="
set /p "choice=> "
if not defined choice goto menu
if /i "!choice!"=="Q" exit /b
if /i "!choice!"=="H" ( start "" "%~dp0index.html" & goto menu )
if not defined tool!choice! ( echo Type a number from the list. & pause & goto menu )
set "pick=!tool%choice%!"
echo.
call "%~dp0!pick!"
echo.
pause
goto menu
