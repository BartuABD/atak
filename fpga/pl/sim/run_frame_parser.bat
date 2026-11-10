@echo off
rem run_frame_parser.bat - simulates frame_parser with its testbench in the Vivado simulator (no project needed)
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
call %V%\xvlog.bat ..\rtl\frame_parser.v || exit /b 1
call %V%\xvlog.bat -sv ..\tb\tb_frame_parser.sv || exit /b 1
call %V%\xelab.bat tb_frame_parser -s tb_frame_parser_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_frame_parser_sim -runall
