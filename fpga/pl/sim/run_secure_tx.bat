@echo off
rem run_secure_tx.bat - simulates secure_tx (+ ccm_core, aes128_enc) with its testbench (no project needed)
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
call %V%\xvlog.bat ..\rtl\aes128_enc.v ..\rtl\ccm_core.v ..\rtl\secure_tx.v || exit /b 1
call %V%\xvlog.bat -sv -i ..\tb ..\tb\tb_secure_tx.sv || exit /b 1
call %V%\xelab.bat tb_secure_tx -s tb_secure_tx_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_secure_tx_sim -runall
