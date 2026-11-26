@echo off
title Kondey fingerprint sync - uninstall
schtasks /Delete /TN "Kondey Portal Fingerprint Sync" /F
echo.
echo The fingerprint sync has been stopped and removed from Task Scheduler.
pause
