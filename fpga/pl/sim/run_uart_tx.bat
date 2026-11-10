@echo off
rem run_uart_tx.bat - simulates uart_tx (looped into uart_rx) in the Vivado simulator (no project needed)
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
call %V%\xvlog.bat ..\rtl\uart_tx.v ..\rtl\uart_rx.v || exit /b 1
call %V%\xvlog.bat -sv ..\tb\tb_uart_tx.sv || exit /b 1
call %V%\xelab.bat tb_uart_tx -s tb_uart_tx_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_uart_tx_sim -runall
