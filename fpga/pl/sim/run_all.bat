@echo off
rem run_all.bat - runs every testbench (run_*.bat), keeps each log in logs\, prints PASS / FAIL per testbench.
rem PASS = the log has "PASSED", no "FAILED" and no line starting with "ERROR". Exit code = number of failed testbenches.
rem Vivado: set XILINX_VIVADO, default C:\AMDDesignTools\2025.2\Vivado.
setlocal enabledelayedexpansion
cd /d %~dp0
if not exist logs mkdir logs
set FAILED=0
for %%f in (run_*.bat) do if /i not "%%f"=="run_all.bat" (
    call "%~dp0%%f" > logs\%%~nf.log 2>&1
    set R=PASS
    findstr /c:"PASSED" logs\%%~nf.log >nul || set R=FAIL
    findstr /r /c:"^ERROR" /c:"FAILED" logs\%%~nf.log >nul && set R=FAIL
    if "!R!"=="FAIL" set /a FAILED+=1
    echo !R!  %%~nf
)
echo %FAILED% failed
exit /b %FAILED%
