@echo off
rem run_addr_filter.bat - simulates addr_filter with its testbench in the Vivado simulator (no project needed)
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
copy /y ..\rtl\whitelist.mem . >nul
copy /y ..\tb\tb_whitelist.mem . >nul
call %V%\xvlog.bat ..\rtl\addr_filter.v || exit /b 1
call %V%\xvlog.bat -sv ..\tb\tb_addr_filter.sv || exit /b 1
call %V%\xelab.bat tb_addr_filter -s tb_addr_filter_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_addr_filter_sim -runall
