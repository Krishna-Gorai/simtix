@echo off
REM ============================================================================
REM run_postimpl_fp_sim.bat  -  post-implementation FUNCTIONAL simulation of the
REM                             DEPLOYABLE FP chip (chip_top) in Vivado xsim.
REM
REM Simulates the real placed-and-routed gate-level netlist (UNISIM primitives)
REM that impl_chip_fp.tcl emits at postimpl_fp/chip_top_fp_funcsim.v - the same
REM netlist the 103.7 MHz clean-DRC bitstream was written from - driven by the
REM self-checking testbench used for RTL sim (tests/tb_chip_top.sv). A PASS
REM proves the routed FP-enabled hardware computes result = 964 with the host
REM CPU loading the inputs.
REM
REM Prereq:  cd fpga && vivado -mode batch -source impl_chip_fp.tcl
REM Usage:   cd fpga && run_postimpl_fp_sim.bat
REM
REM Override the Vivado install dir with the VIVADO_BIN env var if needed.
REM ============================================================================
setlocal
if "%VIVADO_BIN%"=="" set VIVADO_BIN=D:\2025.1\Vivado\bin
set GLBL=%VIVADO_BIN%\..\data\verilog\src\glbl.v

cd /d "%~dp0postimpl_fp" || exit /b 1

echo [postimpl_fp] compiling routed gate-level netlist...
call "%VIVADO_BIN%\xvlog.bat" chip_top_fp_funcsim.v              || exit /b 1
echo [postimpl_fp] compiling testbench + glbl...
call "%VIVADO_BIN%\xvlog.bat" -sv ..\..\tests\tb_chip_top.sv     || exit /b 1
call "%VIVADO_BIN%\xvlog.bat" "%GLBL%"                           || exit /b 1
echo [postimpl_fp] elaborating (unisims_ver + secureip + glbl GSR)...
call "%VIVADO_BIN%\xelab.bat" tb_chip_top glbl -L unisims_ver -L secureip -L xpm ^
     -s chip_fp_postimpl --timescale 1ns/1ps                     || exit /b 1
echo [postimpl_fp] running simulation...
call "%VIVADO_BIN%\xsim.bat" chip_fp_postimpl -runall            || exit /b 1
endlocal
