@echo off
rem run_ccm_core.bat - simulates ccm_core (AES-128-CCM) with its testbench in the Vivado simulator (no project needed)
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
call %V%\xvlog.bat ..\rtl\aes128_enc.v ..\rtl\ccm_core.v || exit /b 1
call %V%\xvlog.bat -sv -i ..\tb ..\tb\tb_ccm_core.sv || exit /b 1
call %V%\xelab.bat tb_ccm_core -s tb_ccm_core_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_ccm_core_sim -runall
