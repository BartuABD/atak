@echo off
rem run_downlink_frame_builder.bat - simulates downlink_frame_builder (+ uart_tx looped into uart_rx), no project needed
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
call %V%\xvlog.bat ..\rtl\downlink_frame_builder.v ..\rtl\uart_tx.v ..\rtl\uart_rx.v || exit /b 1
call %V%\xvlog.bat -sv ..\tb\tb_downlink_frame_builder.sv || exit /b 1
call %V%\xelab.bat tb_downlink_frame_builder -s tb_downlink_frame_builder_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_downlink_frame_builder_sim -runall
