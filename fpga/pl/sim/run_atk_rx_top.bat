@echo off
rem run_atk_rx_top.bat - end-to-end simulation of atk_rx_top in the Vivado simulator (no project needed)
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
copy /y ..\rtl\whitelist.mem . >nul
copy /y ..\tb\wl_server.mem . >nul
call %V%\xvlog.bat ..\rtl\uart_rx.v ..\rtl\frame_parser.v ..\rtl\addr_filter.v ..\rtl\aes128_enc.v ..\rtl\ccm_core.v ..\rtl\replay_window.v ..\rtl\secure_rx.v ..\rtl\atk_rx_top.v || exit /b 1
call %V%\xvlog.bat -sv ..\tb\tb_atk_rx_top.sv || exit /b 1
call %V%\xelab.bat tb_atk_rx_top -s tb_atk_rx_top_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_atk_rx_top_sim -runall
