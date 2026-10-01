@echo off
REM ============================================================
REM  run.bat
REM  Starts the Smart Search Service (FastAPI / uvicorn)
REM  on port 5006. Uses the local venv if present.
REM ============================================================
echo =========================================================
echo  Starting Smart Search Service (FastAPI)
echo =========================================================
echo.

REM --- Activate the virtual environment if it exists ---
if exist venv\Scripts\activate.bat (
    call venv\Scripts\activate.bat
) else (
    echo WARNING: venv not found. Using system Python.
    echo         Run install_packages.bat first for a clean environment.
    echo.
)

REM --- Start the server ---
echo Starting server on http://0.0.0.0:5006 ...
echo Press Ctrl+C to stop.
echo.

REM Prefer the uvicorn CLI; fall back to python app.py if not on PATH
where uvicorn >nul 2>nul
if %errorlevel%==0 (
    uvicorn app:app --host 0.0.0.0 --port 5006 --workers 4
) else (
    python app.py
)

pause
