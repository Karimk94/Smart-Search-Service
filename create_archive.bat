@echo off
setlocal enabledelayedexpansion

echo ============================================================
echo  Creating deployment archive (includes offline packages)
echo ============================================================
echo.

REM ── Generate timestamp-based zip filename ────────────────────
set "foldername=Smart_Search_Service"
for /f "tokens=1-6 delims=.:/ " %%a in ("%DATE% %TIME%") do (
    set "ts=%%c-%%a-%%b_%%d-%%e-%%f"
)
set "ts=%ts: =0%"
set "zipname=%foldername%_%ts%.zip"
set "destPath=%~dp0..\%zipname%"

REM ── Resolve the source directory ─────────────────────────────
set "SRC=%~dp0"
if "%SRC:~-1%"=="\" set "SRC=%SRC:~0,-1%"

REM ── Verify the packages folder exists ────────────────────────
if not exist "%SRC%\packages" (
    echo ERROR: The packages\ folder was not found.
    echo         Run download_packages.bat first to build the offline wheel cache.
    pause
    exit /b 1
)

REM ── Staging folder ───────────────────────────────────────────
set "STAGE=%SRC%\_archive_staging"
if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%\Smart_Search_Service"

echo Staging files (excluding venv, __pycache__, .env, logs)...

REM ── Copy top-level files ─────────────────────────────────────
copy /y "%SRC%\app.py"                   "%STAGE%\Smart_Search_Service\" >nul
copy /y "%SRC%\requirements.txt"         "%STAGE%\Smart_Search_Service\" >nul
copy /y "%SRC%\web.config"               "%STAGE%\Smart_Search_Service\" >nul
copy /y "%SRC%\.env.example"             "%STAGE%\Smart_Search_Service\" >nul
copy /y "%SRC%\readme.md"                "%STAGE%\Smart_Search_Service\" >nul
copy /y "%SRC%\.gitignore"               "%STAGE%\Smart_Search_Service\" >nul 2>nul
copy /y "%SRC%\download_packages.bat"    "%STAGE%\Smart_Search_Service\" >nul
copy /y "%SRC%\install_packages.bat"     "%STAGE%\Smart_Search_Service\" >nul
copy /y "%SRC%\run.bat"                  "%STAGE%\Smart_Search_Service\" >nul

REM ── Copy the packages folder (the offline wheel cache) ───────
echo Adding offline packages...
xcopy "%SRC%\packages\*" "%STAGE%\Smart_Search_Service\packages\" /e /i /q /y >nul

REM ── Build the zip with PowerShell Compress-Archive ───────────
echo.
echo Compressing into: %destPath%
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Compress-Archive -Path '%STAGE%\Smart_Search_Service' -DestinationPath '%destPath%' -Force"

if errorlevel 1 (
    echo.
    echo Failed to create archive.
    rmdir /s /q "%STAGE%" 2>nul
    pause
    exit /b 1
)

REM ── Clean up staging ─────────────────────────────────────────
rmdir /s /q "%STAGE%" 2>nul

echo.
echo ============================================================
echo  Archive created successfully!
echo  Location: ..\%zipname%
echo ============================================================
echo  Contents include app.py, all .bat files, web.config,
echo  requirements.txt, .env.example, readme.md, and the
echo  packages\ offline wheel cache.
echo.
echo  To deploy: copy the zip to the server, extract it,
echo  run install_packages.bat, create .env, then run run.bat.
echo ============================================================
pause
endlocal
