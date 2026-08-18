@echo off
setlocal EnableExtensions EnableDelayedExpansion
title PCHM30 DTBO Flasher
cd /d "%~dp0"

echo ==========================================
echo  PCHM30 DTBO Flasher - Windows ADB
echo ==========================================
echo.

where adb >nul 2>&1
if errorlevel 1 (
    echo [ERROR] adb.exe was not found in PATH.
    echo Install Android platform-tools or place this script in a folder where adb is available.
    pause
    exit /b 1
)

adb get-state >nul 2>&1
if errorlevel 1 (
    echo [ERROR] No ADB device detected.
    adb devices
    pause
    exit /b 1
)

set /a COUNT=0
for /f "delims=" %%F in ('dir /b /a-d "*dtbo*.img" 2^>nul') do (
    set /a COUNT+=1
    set "IMG!COUNT!=%%F"
)

if !COUNT! EQU 0 (
    echo [ERROR] No DTBO .img file was found beside this script.
    echo Put this .cmd and the DTBO .img file in the same folder.
    pause
    exit /b 1
)

echo DTBO images found in:
echo %CD%
echo.
for /L %%N in (1,1,!COUNT!) do echo [%%N] !IMG%%N!
echo.
set /p PICK=Select the image number to flash: 

set "SELECTED="
for /L %%N in (1,1,!COUNT!) do (
    if "!PICK!"=="%%N" set "SELECTED=!IMG%%N!"
)

if not defined SELECTED (
    echo [ERROR] Invalid selection.
    pause
    exit /b 1
)

echo.
echo Selected: !SELECTED!
echo Target  : /dev/block/by-name/dtbo
echo.

echo [1/3] Backing up the current DTBO...
adb shell su -c "dd if=/dev/block/by-name/dtbo of=/sdcard/PCHM30-dtbo-backup-before-flash.img bs=4M" || goto :fail
adb pull /sdcard/PCHM30-dtbo-backup-before-flash.img "%~dp0PCHM30-dtbo-backup-before-flash.img" || goto :fail

echo.
echo Backup saved as:
echo %~dp0PCHM30-dtbo-backup-before-flash.img
echo.
set /p CONFIRM=Type yes to flash !SELECTED! : 
if /I not "!CONFIRM!"=="yes" (
    echo Cancelled. Nothing was flashed.
    pause
    exit /b 0
)

echo.
echo [2/3] Pushing and flashing DTBO...
adb push "!SELECTED!" /sdcard/PCHM30-dtbo-to-flash.img || goto :fail
adb shell su -c "dd if=/sdcard/PCHM30-dtbo-to-flash.img of=/dev/block/by-name/dtbo bs=4M" || goto :fail
adb shell su -c "sync" || goto :fail

echo.
echo [3/3] Flash completed successfully.
echo Rebooting device...
adb reboot
exit /b 0

:fail
echo.
echo [ERROR] Flash process failed.
echo The backup file may already exist beside this script.
echo Do NOT reboot if the write operation failed halfway.
pause
exit /b 1
