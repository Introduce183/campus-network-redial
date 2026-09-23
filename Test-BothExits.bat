@echo off
setlocal
cd /d "%~dp0"

echo ==============================================
echo   Both-Exit Compare Test
echo   Tests the dial-up exit AND the Wi-Fi exit
echo ==============================================
echo.
echo Needs administrator rights (it adds and removes
echo /32 host routes to pin the probe to one exit at a
echo time), so a UAC prompt appears now.
echo.
echo After you accept it, the test runs in a NEW window:
echo press Enter there to test both exits once, as many
echo times as you like. Type q and Enter to quit.
echo.
echo Results are also appended to logs\exit-compare.log
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-BothExits.ps1"

echo.
echo If a UAC prompt was accepted, the test is now running in
echo its own window. If you declined it, nothing was changed.
echo.
pause
