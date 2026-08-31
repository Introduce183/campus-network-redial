@echo off
setlocal
cd /d "%~dp0"

echo ==============================================
echo   Campus Network Auto-Redial Launcher
echo ==============================================
echo.

echo [1/2] Detecting dial-up connection name from the phone book...
set "DIALNAME="
for /f "usebackq delims=" %%N in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$names=@(); $p=[Environment]::GetFolderPath('CommonApplicationData')+'\Microsoft\Network\Connections\Pbk\rasphone.pbk'; if(Test-Path -LiteralPath $p){ $names += (Select-String -LiteralPath $p -Pattern '^\s*\[(.+?)\]\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value }) }; $p=[Environment]::GetFolderPath('ApplicationData')+'\Microsoft\Network\Connections\Pbk\rasphone.pbk'; if(Test-Path -LiteralPath $p){ $names += (Select-String -LiteralPath $p -Pattern '^\s*\[(.+?)\]\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value }) }; $names=@($names | Select-Object -Unique); if($names.Count -eq 1){ $names[0] }"`) do set "DIALNAME=%%N"

echo [2/2] Starting auto-redial...
echo.

if defined DIALNAME (
    echo Detected dial-up name: %DIALNAME%
    echo.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Redial-UntilCampusReady.ps1" -DialName "%DIALNAME%"
) else (
    echo No single dial-up entry detected; the script will auto-detect the name.
    echo.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Redial-UntilCampusReady.ps1"
)

set "CODE=%ERRORLEVEL%"
echo.
if "%CODE%"=="0" (
    echo Launcher finished successfully.
) else (
    echo Launcher finished with exit code %CODE%.
)
echo.
pause
