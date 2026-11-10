@echo off
rem run_secure_rx.bat - simulates secure_rx (+ ccm_core, aes128_enc, replay_window) with its testbench (no project needed)
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
call %V%\xvlog.bat ..\rtl\aes128_enc.v ..\rtl\ccm_core.v ..\rtl\replay_window.v ..\rtl\secure_rx.v || exit /b 1
call %V%\xvlog.bat -sv -i ..\tb ..\tb\tb_secure_rx.sv || exit /b 1
call %V%\xelab.bat tb_secure_rx -s tb_secure_rx_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_secure_rx_sim -runall
