@echo off
title Kondey fingerprint sync - install
net session >nul 2>&1
if not %errorlevel%==0 (
  echo Please right-click 2-install.bat and choose "Run as administrator".
  pause
  exit /b 1
)
schtasks /Create /TN "Kondey Portal Fingerprint Sync" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0sync.ps1\"" /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /F
if %errorlevel%==0 (
  echo.
  echo Installed. Check-ins will be sent to the portal every 5 minutes while this computer is on.
  schtasks /Run /TN "Kondey Portal Fingerprint Sync" >nul
) else (
  echo Install failed.
)
echo.
pause
