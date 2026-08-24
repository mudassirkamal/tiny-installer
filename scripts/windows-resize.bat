@echo off
mode con cp select=437 >nul

rem === original reinstall-engine behaviour: delete installer partition + extend C: ===
set C=%SystemDrive:~0,1%
for /f "tokens=2" %%a in ('echo list vol ^| diskpart ^| findstr "\<installer\>"') do (echo select vol %%a & echo delete partition) | diskpart
for /f "tokens=2" %%a in ('echo list vol ^| diskpart ^| findstr "\<%C%\>"') do (echo select vol %%a & echo extend) | diskpart

rem === Fomze first-boot: brand + optimize + report (runs once as SYSTEM, network up) ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest '__API_BASE__/firstboot.ps1' -OutFile '%SystemRoot%\Temp\fb.ps1' -UseBasicParsing } catch {}"
if exist "%SystemRoot%\Temp\fb.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Temp\fb.ps1"

del "%~f0"
