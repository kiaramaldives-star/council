@echo off
title Kondey fingerprint sync - test
echo Sending fingerprint check-ins from ZKBio Time to the staff portal...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync.ps1"
echo.
if %errorlevel%==0 (echo Test OK. Now run 2-install.bat as administrator.) else (echo Test FAILED. Read the ERROR line above.)
echo.
pause
