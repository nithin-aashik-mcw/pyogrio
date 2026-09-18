@echo off
REM ============================================================================
REM  Build and install pyogrio (+ benchmark dependencies) in a local .venv on
REM  Windows (x64 or ARM64), using GDAL built from source via vcpkg (pinned to
REM  the same commit/manifest/triplet family pyogrio's own CI uses), then
REM  download the benchmark datasets and run the benchmark suite.
REM
REM  Run this from a normal Command Prompt with this file placed at the root
REM  of the pyogrio repo checkout (next to pyproject.toml). The target
REM  architecture (x64 or arm64) is auto-detected from the machine; pass it
REM  explicitly as the first argument to override, e.g.:
REM      build_pyogrio_windows.bat x64
REM      build_pyogrio_windows.bat arm64
REM
REM  Requirements on the machine before running:
REM    - git, cmake, python (3.10+) on PATH, matching the target architecture
REM    - Visual Studio 2022 Build Tools with the matching "MSVC v143 - VS 2022
REM      C++ x64/x86 build tools" or "...ARM64/ARM64EC build tools" component
REM      installed
REM    - Internet access (vcpkg + PyPI + Natural Earth/USGS dataset downloads)
REM  curl.exe and tar.exe are built into Windows 10/11 (both x64 and ARM64) and
REM  are used here instead of any extra tools.
REM ============================================================================

setlocal EnableExtensions EnableDelayedExpansion

set "REPO_DIR=%~dp0"
if "%REPO_DIR:~-1%"=="\" set "REPO_DIR=%REPO_DIR:~0,-1%"
cd /d "%REPO_DIR%" || (echo [ERROR] Could not cd to "%REPO_DIR%" & exit /b 1)

if not defined VCPKG_ROOT set "VCPKG_ROOT=C:\vcpkg"
if not defined VENV_DIR set "VENV_DIR=%REPO_DIR%\.venv"
set "VCPKG_COMMIT=89dac9685f8d0ebd0a07d8b93ed51215c3a2fb2c"
set "GDAL_VERSION=3.12.4"

echo.
echo === Checking prerequisites ===
where git   >nul 2>&1 || (echo [ERROR] git not found on PATH & exit /b 1)
where cmake >nul 2>&1 || (echo [ERROR] cmake not found on PATH & exit /b 1)
where python >nul 2>&1 || (echo [ERROR] python not found on PATH & exit /b 1)
where curl  >nul 2>&1 || (echo [ERROR] curl not found on PATH & exit /b 1)
where tar   >nul 2>&1 || (echo [ERROR] tar not found on PATH & exit /b 1)
if not exist "%REPO_DIR%\ci\vcpkg.json" (
    echo [ERROR] "%REPO_DIR%\ci\vcpkg.json" not found.
    echo         Place this script at the root of the pyogrio repo checkout.
    exit /b 1
)
echo OK

REM ---------------------------------------------------------------------------
REM  Some machines (e.g. with depot_tools on PATH) have a "git.bat"/"git.cmd"
REM  shim ahead of the real Git for Windows git.exe. That breaks things in two
REM  ways: (1) any bare, non-"call"ed "git ..." in this script would silently
REM  abort the rest of the script the moment it hit such a shim, since running
REM  a batch file from inside a batch file without CALL never returns control;
REM  and (2) vcpkg.exe's own internal git invocations (which we don't control)
REM  would resolve to the shim too and can fail outright. Look up the real
REM  git.exe specifically (bypassing any .bat/.cmd shim) and, if it isn't
REM  already the one PATH would resolve to, move its directory to the front of
REM  PATH for the remainder of this script and its child processes.
REM ---------------------------------------------------------------------------
for /f "delims=" %%G in ('where git.exe 2^>nul') do (
    set "REAL_GIT_EXE=%%G"
    goto :after_find_git_exe
)
:after_find_git_exe
if not defined REAL_GIT_EXE (
    echo [ERROR] Could not locate a real git.exe on PATH.
    exit /b 1
)
for %%G in ("%REAL_GIT_EXE%") do set "REAL_GIT_DIR=%%~dpG"
if /I not "!REAL_GIT_DIR:~-1!"=="\" set "REAL_GIT_DIR=!REAL_GIT_DIR!\"
where git >nul 2>&1
for /f "delims=" %%G in ('where git 2^>nul') do (
    set "RESOLVED_GIT=%%G"
    goto :after_resolve_git
)
:after_resolve_git
if /I not "!RESOLVED_GIT!"=="!REAL_GIT_EXE!" (
    echo Prioritizing real git.exe at "!REAL_GIT_DIR!" ^(found non-.exe git shim earlier on PATH: "!RESOLVED_GIT!"^)
    set "PATH=!REAL_GIT_DIR!;%PATH%"
)

REM ---------------------------------------------------------------------------
REM  Determine target architecture: explicit first argument wins; otherwise
REM  auto-detect the machine's *native* architecture. PROCESSOR_ARCHITECTURE
REM  reflects the current process (e.g. "AMD64" for an x64 process running
REM  under emulation on ARM64 Windows), while PROCESSOR_ARCHITEW6432 (set by
REM  WOW64) reflects the true host architecture when the two differ.
REM ---------------------------------------------------------------------------
echo.
echo === Determining target architecture ===
if not "%~1"=="" (
    set "ARCH=%~1"
) else (
    REM inside this ( ) block, variables set here must be read back with
    REM delayed expansion (!VAR!) -- %VAR% would only see the pre-block value
    set "HOST_ARCH=%PROCESSOR_ARCHITECTURE%"
    if defined PROCESSOR_ARCHITEW6432 set "HOST_ARCH=%PROCESSOR_ARCHITEW6432%"
    if /I "!HOST_ARCH!"=="AMD64" set "ARCH=x64"
    if /I "!HOST_ARCH!"=="ARM64" set "ARCH=arm64"
    if not defined ARCH (
        echo [ERROR] Could not auto-detect a supported architecture from PROCESSOR_ARCHITECTURE="!HOST_ARCH!".
        echo         Pass it explicitly: build_pyogrio_windows.bat x64  ^|  build_pyogrio_windows.bat arm64
        exit /b 1
    )
)
set "VALID_ARCH="
if /I "%ARCH%"=="x64" set "VALID_ARCH=1"
if /I "%ARCH%"=="arm64" set "VALID_ARCH=1"
if not defined VALID_ARCH (
    echo [ERROR] Unsupported architecture "%ARCH%". Expected x64 or arm64.
    exit /b 1
)
set "TRIPLET=%ARCH%-windows-dynamic-release"
echo Target architecture: %ARCH%  ^(triplet: %TRIPLET%^)

REM ---------------------------------------------------------------------------
REM  1. Fetch and bootstrap vcpkg, pinned to the commit pyogrio's CI uses
REM ---------------------------------------------------------------------------
echo.
echo === Setting up vcpkg at "%VCPKG_ROOT%" ===
if not exist "%VCPKG_ROOT%\.git" (
    call git clone https://github.com/microsoft/vcpkg.git "%VCPKG_ROOT%"
    if errorlevel 1 (echo [ERROR] git clone of vcpkg failed & exit /b 1)
)

pushd "%VCPKG_ROOT%"
call git fetch --quiet origin
if errorlevel 1 (echo [ERROR] git fetch in vcpkg failed & popd & exit /b 1)
call git checkout --quiet %VCPKG_COMMIT%
if errorlevel 1 (echo [ERROR] git checkout of vcpkg commit %VCPKG_COMMIT% failed & popd & exit /b 1)
if not exist "%VCPKG_ROOT%\vcpkg.exe" (
    call "%VCPKG_ROOT%\bootstrap-vcpkg.bat" -disableMetrics
    if errorlevel 1 (echo [ERROR] vcpkg bootstrap failed & popd & exit /b 1)
)
popd
echo OK

REM ---------------------------------------------------------------------------
REM  2. Build GDAL (+ GEOS, PROJ, sqlite3, curl, libkml, spatialite, etc.) via
REM     vcpkg, using pyogrio's own manifest and the custom triplet for the
REM     detected architecture. This is the long step: it compiles GDAL and its
REM     dependencies from source and can take 45-90+ minutes.
REM ---------------------------------------------------------------------------
echo.
echo === Building GDAL %GDAL_VERSION% for triplet %TRIPLET% via vcpkg ===
echo (this builds GDAL and its dependencies from source and can take a long time)
set "VCPKG_DEFAULT_TRIPLET=%TRIPLET%"
"%VCPKG_ROOT%\vcpkg.exe" install --overlay-triplets=.\ci\custom-triplets --feature-flags="versions,manifests" --x-manifest-root=.\ci --x-install-root="%VCPKG_ROOT%\installed"
if errorlevel 1 (echo [ERROR] vcpkg install of GDAL failed & exit /b 1)
echo OK

set "VCPKG_INSTALLED=%VCPKG_ROOT%\installed\%TRIPLET%"
if not exist "%VCPKG_INSTALLED%\include\gdal.h" (
    echo [ERROR] "%VCPKG_INSTALLED%\include\gdal.h" not found after vcpkg install.
    exit /b 1
)

set "GDAL_INCLUDE_PATH=%VCPKG_INSTALLED%\include"
set "GDAL_LIBRARY_PATH=%VCPKG_INSTALLED%\lib"
set "GDAL_DATA=%VCPKG_INSTALLED%\share\gdal"
set "PROJ_LIB=%VCPKG_INSTALLED%\share\proj"
set "GEOS_INCLUDE_PATH=%VCPKG_INSTALLED%\include"
set "GEOS_LIBRARY_PATH=%VCPKG_INSTALLED%\lib"
set "PATH=%VCPKG_INSTALLED%\bin;%PATH%"

REM ---------------------------------------------------------------------------
REM  3. Create/populate the .venv
REM ---------------------------------------------------------------------------
echo.
echo === Setting up .venv at "%VENV_DIR%" ===
if not exist "%VENV_DIR%\Scripts\python.exe" (
    python -m venv "%VENV_DIR%"
    if errorlevel 1 (echo [ERROR] python -m venv failed & exit /b 1)
)
set "PY=%VENV_DIR%\Scripts\python.exe"

"%PY%" -m pip install --upgrade pip -q
if errorlevel 1 (echo [ERROR] pip self-upgrade failed & exit /b 1)

echo Installing build tooling and core runtime deps...
"%PY%" -m pip install -q "setuptools>=77" "Cython>=3.1" "versioneer[toml]==0.28" numpy pandas packaging certifi
if errorlevel 1 (echo [ERROR] installing build tooling failed & exit /b 1)
echo OK

REM ---------------------------------------------------------------------------
REM  4. Build and install pyogrio against the vcpkg GDAL
REM ---------------------------------------------------------------------------
echo.
echo === Building and installing pyogrio ===
"%PY%" -m pip install --no-build-isolation --no-deps -e . -v
if errorlevel 1 (echo [ERROR] pyogrio build/install failed & exit /b 1)
echo OK

REM ---------------------------------------------------------------------------
REM  5. Make the venv auto-load the vcpkg GDAL/GEOS DLLs and data dirs.
REM     Since Python 3.8, extension-module DLL dependencies are no longer
REM     resolved via PATH, only via os.add_dll_directory(). A .pth file's
REM     "import ..." line runs automatically at interpreter startup, so this
REM     makes every use of this venv (pytest, scripts, etc.) work with no
REM     manual environment setup.
REM ---------------------------------------------------------------------------
echo.
echo === Wiring up automatic GDAL/GEOS DLL loading for this venv ===
> "%VENV_DIR%\Lib\site-packages\_pyogrio_gdal_dll.pth" echo import os; d=r"%VCPKG_INSTALLED%\bin"; os.path.isdir(d) and os.add_dll_directory(d); os.environ.setdefault("GDAL_DATA", r"%GDAL_DATA%"); os.environ.setdefault("PROJ_LIB", r"%PROJ_LIB%")
if errorlevel 1 (echo [ERROR] writing _pyogrio_gdal_dll.pth failed & exit /b 1)
echo OK

REM ---------------------------------------------------------------------------
REM  6. Verify pyogrio imports cleanly before going further
REM ---------------------------------------------------------------------------
echo.
echo === Verifying pyogrio import ===
"%PY%" -c "import pyogrio; print('pyogrio', pyogrio.__version__); print('GDAL', pyogrio.__gdal_version_string__)"
if errorlevel 1 (echo [ERROR] pyogrio failed to import after install & exit /b 1)
echo OK

REM ---------------------------------------------------------------------------
REM  7. Install benchmark/test dependencies.
REM
REM     shapely and fiona both publish win_amd64 (x64) wheels on PyPI, so on
REM     an x64 machine pip just uses those directly. Neither currently
REM     publishes a win_arm64 wheel though, so on ARM64 pip falls back to
REM     building them from source here; both are wired up against the same
REM     vcpkg-built GEOS/GDAL to make that fallback work either way:
REM       - shapely's setup.py reads GEOS_INCLUDE_PATH/GEOS_LIBRARY_PATH
REM         directly (set above).
REM       - fiona's setup.py has no such env-var hook on Windows, so its
REM         include/library/link flags are passed via legacy
REM         "--global-option" build_ext arguments instead.
REM     pyarrow also has no win_arm64 wheel and would require building the
REM     full Arrow C++ project from source, which is out of scope here; it is
REM     not required by any file in benchmarks/, so it is skipped.
REM ---------------------------------------------------------------------------
echo.
echo === Installing pytest / geopandas / pyproj ===
"%PY%" -m pip install -q pytest pytest-benchmark pytest-cov geopandas pyproj
if errorlevel 1 (echo [ERROR] installing pytest/geopandas/pyproj failed & exit /b 1)
echo OK

echo.
echo === Building shapely from source against vcpkg GEOS ===
"%PY%" -m pip install --no-build-isolation shapely
if errorlevel 1 (echo [ERROR] shapely build/install failed & exit /b 1)
echo OK

echo.
echo === Building fiona from source against vcpkg GDAL ===
"%PY%" -m pip install --no-build-isolation ^
  --config-settings="--global-option=build_ext" ^
  --config-settings="--global-option=-I%GDAL_INCLUDE_PATH%" ^
  --config-settings="--global-option=-L%GDAL_LIBRARY_PATH%" ^
  --config-settings="--global-option=-lgdal" ^
  fiona
if errorlevel 1 (echo [ERROR] fiona build/install failed & exit /b 1)
echo OK

echo.
echo === Verifying fiona/shapely/geopandas import ===
"%PY%" -c "import fiona, shapely, geopandas; print('fiona', fiona.__version__); print('shapely', shapely.__version__); print('geopandas', geopandas.__version__)"
if errorlevel 1 (echo [ERROR] fiona/shapely/geopandas failed to import after install & exit /b 1)
echo OK

REM ---------------------------------------------------------------------------
REM  8. Download benchmark datasets into benchmarks\fixtures.
REM     The URLs in benchmarks\README.md for Natural Earth are stale (return
REM     HTTP 500); naciscdn.org is the current working mirror. The two USGS
REM     hydrography GDBs from prd-tnm.s3.amazonaws.com still work as documented.
REM ---------------------------------------------------------------------------
echo.
echo === Downloading benchmark datasets into benchmarks\fixtures ===
set "FIX=%REPO_DIR%\benchmarks\fixtures"
if not exist "%FIX%" mkdir "%FIX%"

call :fetch_and_extract "ne_110m_admin_0_countries" "https://naciscdn.org/naturalearth/110m/cultural/ne_110m_admin_0_countries.zip"
call :fetch_and_extract "ne_10m_admin_0_countries" "https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_0_countries.zip"
call :fetch_and_extract "ne_110m_admin_1_states_provinces" "https://naciscdn.org/naturalearth/110m/cultural/ne_110m_admin_1_states_provinces.zip"
call :fetch_and_extract "ne_10m_admin_1_states_provinces" "https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_1_states_provinces.zip"
call :fetch_and_extract "WBD_17_HU2_GDB" "https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/WBD/HU2/GDB/WBD_17_HU2_GDB.zip"
call :fetch_and_extract "NHDPLUS_H_1704_HU4_GDB" "https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/NHDPlusHR/Beta/GDB/NHDPLUS_H_1704_HU4_GDB.zip"
echo OK

REM ---------------------------------------------------------------------------
REM  9. Run the benchmark suite
REM ---------------------------------------------------------------------------
echo.
echo === Running pyogrio benchmark suite ===
"%PY%" -m pytest "%REPO_DIR%\benchmarks" --benchmark-only -v
set "BENCH_RESULT=%errorlevel%"

echo.
if "%BENCH_RESULT%"=="0" (
    echo === All done: pyogrio is built, installed, and the benchmark suite passed. ===
) else (
    echo [WARNING] Benchmark run exited with code %BENCH_RESULT%. Scroll up for details.
)
exit /b %BENCH_RESULT%

REM ============================================================================
REM  :fetch_and_extract <name> <url>
REM  Downloads <url> to benchmarks\fixtures\<name>.zip (skipped if already
REM  present) and extracts it into benchmarks\fixtures\<name>\ (skipped if
REM  that folder already has content), unless already done.
REM ============================================================================
:fetch_and_extract
set "NAME=%~1"
set "URL=%~2"
if not exist "%FIX%\%NAME%.zip" (
    echo Downloading %NAME%...
    curl -sSL --fail -o "%FIX%\%NAME%.zip" "%URL%"
    if errorlevel 1 (
        echo [ERROR] download of %NAME% failed
        exit /b 1
    )
) else (
    echo %NAME%.zip already present, skipping download.
)
if not exist "%FIX%\%NAME%" mkdir "%FIX%\%NAME%"
dir /a /b "%FIX%\%NAME%" 2>nul | findstr "." >nul
if errorlevel 1 (
    echo Extracting %NAME%...
    tar -xf "%FIX%\%NAME%.zip" -C "%FIX%\%NAME%"
    if errorlevel 1 (
        echo [ERROR] extraction of %NAME% failed
        exit /b 1
    )
) else (
    echo %NAME% already extracted, skipping.
)
exit /b 0
