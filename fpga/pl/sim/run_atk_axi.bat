@echo off
rem run_atk_axi.bat - simulates the AXI4-Lite wrapper atk_axi (registers + table read + downlink), no project needed
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
copy /y ..\tb\wl_phase2.mem . >nul
call %V%\xvlog.bat ..\rtl\uart_rx.v ..\rtl\frame_parser.v ..\rtl\addr_filter.v ..\rtl\aes128_enc.v ..\rtl\ccm_core.v ..\rtl\replay_window.v ..\rtl\secure_rx.v ..\rtl\atk_rx_top.v ..\rtl\location_table.v ..\rtl\downlink_frame_builder.v ..\rtl\uart_tx.v ..\rtl\cmd_fifo.v ..\rtl\admin_tx.v ..\rtl\secure_tx.v ..\rtl\atk_server.v ..\rtl\atk_axi.v || exit /b 1
call %V%\xvlog.bat -sv ..\tb\tb_atk_axi.sv || exit /b 1
call %V%\xelab.bat tb_atk_axi -s tb_atk_axi_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_atk_axi_sim -runall
