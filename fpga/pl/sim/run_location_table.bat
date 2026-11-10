@echo off
rem run_location_table.bat - simulates location_table with its testbench in the Vivado simulator (no project needed)
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
call %V%\xvlog.bat ..\rtl\location_table.v || exit /b 1
call %V%\xvlog.bat -sv ..\tb\tb_location_table.sv || exit /b 1
call %V%\xelab.bat tb_location_table -s tb_location_table_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_location_table_sim -runall
