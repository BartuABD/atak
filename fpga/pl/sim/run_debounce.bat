@echo off
rem run_debounce.bat - simulates debounce with a bouncing button, no project needed
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
call %V%\xvlog.bat ..\rtl\debounce.v || exit /b 1
call %V%\xvlog.bat -sv ..\tb\tb_debounce.sv || exit /b 1
call %V%\xelab.bat tb_debounce -s tb_debounce_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_debounce_sim -runall
