@echo off
setlocal
cd /d "%~dp0"

echo ==============================================
echo   Network Path Manager
echo   Wi-Fi fallback + PPPoE primary, auto failover
echo ==============================================
echo.
echo This manager needs administrator rights
echo (it edits the dial-up phonebook entry and
echo  adds/removes routes), so a UAC prompt appears now.
echo.
echo After you accept it, the manager keeps running in a
echo NEW window -- you can close this one.
echo.
echo Log file: logs\network-path.log
echo Press Ctrl+C in the manager window to stop it.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-NetworkPath.ps1"

echo.
echo If a UAC prompt was accepted, the manager is now running
echo in its own window. If you declined it, nothing was changed.
echo.
pause
