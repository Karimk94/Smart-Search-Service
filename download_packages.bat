@echo off
REM ============================================================================
REM  download_packages.bat
REM
REM  Run this script on an INTERNET-CONNECTED machine to download all required
REM  Python wheel files into the 'packages' folder.
REM
REM  The resulting 'packages' folder is included in the deployment archive so
REM  the target server can install everything OFFLINE via install_packages.bat.
REM
REM  Requirements:
REM  - Python and pip must be installed on this machine (any 3.x version works;
REM    the version-specific wheels are fetched explicitly for the target below).
REM  - Run from the project root.
REM
REM  IMPORTANT - VERSION-SPECIFIC (COMPILED) WHEELS:
REM  Some dependencies ship compiled C-extension wheels that are tagged for a
REM  SPECIFIC CPython version + platform, e.g.:
REM      pydantic_core-2.46.4-cp312-cp312-win_amd64.whl
REM      charset_normalizer-3.5.1-cp314-cp314-win_amd64.whl   (WRONG version)
REM  pip will REFUSE to install a wheel whose tag does not match the server's
REM  interpreter, reporting "No matching distribution found" / "from versions:
REM  none". This is the classic offline-install failure.
REM
REM  To avoid it, this script:
REM    1. Downloads the version-critical wheels for the TARGET Python FIRST
REM       (so the correct ones are guaranteed present).
REM    2. Then downloads the rest (pure-Python wheels) for the local machine.
REM    3. Finally DELETES any compiled wheel whose tag does NOT match the
REM       target, so a wrong-version wheel from the local interpreter can never
REM       pollute the offline cache.
REM
REM  >>> If the target server's Python version/platform changes, update the
REM  >>> TARGET_PY_VER and TARGET_PLATFORM variables below and re-run this. <<<
REM ============================================================================

@echo off
setlocal enabledelayedexpansion

REM --- Target server interpreter (the OFFLINE server that runs install_packages.bat) ---
set "TARGET_PY_VER=312"
set "TARGET_PLATFORM=win_amd64"

echo Changing directory to the script's location...
cd /d "%~dp0"

echo.
echo Cleaning old packages...
if exist packages rmdir /s /q packages
mkdir packages

REM ---------------------------------------------------------------------------
REM  STEP 1 - Version-critical wheels for the TARGET Python (MUST succeed).
REM           Compiled C-extension wheels (pydantic_core, and charset_normalizer
REM           when only a compiled wheel exists) are CPython-version-specific,
REM           so we fetch the exact target tag. Pulling the whole tree here also
REM           guarantees every transitive dep has a target-compatible wheel.
REM ---------------------------------------------------------------------------
echo.
echo ===================================================================
echo  STEP 1: Downloading wheels for TARGET Python %TARGET_PY_VER% / %TARGET_PLATFORM%
echo  (version-specific compiled wheels - MUST succeed)
echo ===================================================================
pip download -r requirements.txt --only-binary=:all: --platform %TARGET_PLATFORM% --python-version %TARGET_PY_VER% -d packages
if !errorlevel! neq 0 (
    echo.
    echo ERROR: Failed to download target-version wheels for Python %TARGET_PY_VER% / %TARGET_PLATFORM%.
    echo        The offline server will NOT be able to install from this cache.
    echo        Check internet access and the TARGET_PY_VER / TARGET_PLATFORM settings.
    pause
    exit /b 1
)

REM ---------------------------------------------------------------------------
REM  STEP 2 - Pure-Python wheels via the local interpreter. These are tagged
REM           'py3-none-any' so they are portable across versions; 'pip wheel'
REM           also resolves any remaining transitive deps for the local host.
REM ---------------------------------------------------------------------------
echo.
echo ===================================================================
echo  STEP 2: Downloading remaining (pure-Python) wheels for current host
echo ===================================================================
pip wheel -r requirements.txt --wheel-dir=packages
if !errorlevel! neq 0 (
    echo.
    echo WARNING: 'pip wheel' reported an error. The target-version wheels
    echo          from STEP 1 are already in place, but some pure-Python
    echo          wheels may be missing. Review the output above.
)

REM ---------------------------------------------------------------------------
REM  STEP 3 - PURGE any compiled wheel that does NOT match the target tag.
REM           A compiled wheel is one whose name contains a 'cp###' tag. We
REM           keep it ONLY if it contains 'cp%TARGET_PY_VER%'. Pure-Python
REM           wheels ('py3-none-any', no 'cp') are always kept. This guarantees
REM           no wrong-version compiled wheel (e.g. one built for the local
REM           interpreter) can ever sneak into the offline cache.
REM ---------------------------------------------------------------------------
echo.
echo ===================================================================
echo  STEP 3: Purging compiled wheels not matching cp%TARGET_PY_VER%
echo ===================================================================
set "PURGED=0"
for %%F in (packages\*.whl) do (
    set "FN=%%~nxF"
    REM Only inspect compiled wheels (those containing 'cp')
    echo !FN! | findstr /i "cp" >nul && (
        echo !FN! | findstr /i "cp%TARGET_PY_VER%" >nul || (
            echo   Deleting wrong-version wheel: !FN!
            del "%%F"
            set /a PURGED+=1
        )
    )
)
echo   Purged !PURGED! non-target compiled wheel(s).

REM ---------------------------------------------------------------------------
REM  STEP 4 - Sanity check: ensure no stray 'cp' wheels that are not
REM           cp%TARGET_PY_VER% remain (catches e.g. cp314 wheels).
REM ---------------------------------------------------------------------------
set "STRAY=0"
for %%F in (packages\*.whl) do (
    set "FN=%%~nxF"
    echo !FN! | findstr /i "cp" >nul && (
        echo !FN! | findstr /i "cp%TARGET_PY_VER%" >nul || set /a STRAY+=1
    )
)
if !STRAY! gtr 0 (
    echo.
    echo ERROR: !STRAY! compiled wheel(s) not matching cp%TARGET_PY_VER% are still
    echo        present in packages\. Offline install on Python %TARGET_PY_VER% will fail.
    echo        Inspect the packages\ folder manually.
    pause
    exit /b 1
)

echo.
echo ===================================================================
echo  Download complete!
echo ===================================================================
echo  All wheels are saved in: packages\
echo  Target interpreter: CPython %TARGET_PY_VER% / %TARGET_PLATFORM%
echo  Compiled wheels are tagged cp%TARGET_PY_VER%-cp%TARGET_PY_VER%-%TARGET_PLATFORM%
echo  (plus any pure-Python 'py3-none-any' wheels).
echo.
echo  Now run 'create_archive.bat' to bundle everything for deployment.
echo ===================================================================
echo.
pause
endlocal
