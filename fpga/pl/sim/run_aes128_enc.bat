@echo off
rem run_aes128_enc.bat - simulates aes128_enc (AES-128 core) with its testbench in the Vivado simulator (no project needed)
cd /d %~dp0
if not defined XILINX_VIVADO set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set V=%XILINX_VIVADO%\bin
call %V%\xvlog.bat ..\rtl\aes128_enc.v || exit /b 1
call %V%\xvlog.bat -sv ..\tb\tb_aes128_enc.sv || exit /b 1
call %V%\xelab.bat tb_aes128_enc -s tb_aes128_enc_sim -debug typical || exit /b 1
call %V%\xsim.bat tb_aes128_enc_sim -runall
