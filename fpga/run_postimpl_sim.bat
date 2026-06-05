@echo off
REM ============================================================================
REM run_postimpl_sim.bat  -  post-implementation FUNCTIONAL simulation of the
REM                          complete chip (chip_top) in Vivado xsim.
REM
REM Simulates the real placed-and-routed gate-level netlist (UNISIM primitives)
REM that impl_chip.tcl emits at postimpl/chip_top_funcsim.v, driven by the same
REM self-checking testbench used for RTL sim (tests/tb_chip_top.sv). A PASS proves
REM the routed hardware computes result = 964 with the host CPU loading the inputs.
REM
REM Prereq:  cd fpga && vivado -mode batch -source impl_chip.tcl   (produces the netlist)
REM Usage:   cd fpga && run_postimpl_sim.bat
REM
REM Override the Vivado install dir with the VIVADO_BIN env var if needed.
REM ============================================================================
setlocal
if "%VIVADO_BIN%"=="" set VIVADO_BIN=D:\2025.1\Vivado\bin
set GLBL=%VIVADO_BIN%\..\data\verilog\src\glbl.v

cd /d "%~dp0postimpl" || exit /b 1

echo [postimpl] compiling routed gate-level netlist...
call "%VIVADO_BIN%\xvlog.bat" chip_top_funcsim.v                 || exit /b 1
echo [postimpl] compiling testbench + glbl...
call "%VIVADO_BIN%\xvlog.bat" -sv ..\..\tests\tb_chip_top.sv     || exit /b 1
call "%VIVADO_BIN%\xvlog.bat" "%GLBL%"                           || exit /b 1
echo [postimpl] elaborating (unisims_ver + secureip + glbl GSR)...
call "%VIVADO_BIN%\xelab.bat" tb_chip_top glbl -L unisims_ver -L secureip -L xpm ^
     -s chip_postimpl --timescale 1ns/1ps                        || exit /b 1
echo [postimpl] running simulation...
call "%VIVADO_BIN%\xsim.bat" chip_postimpl -runall               || exit /b 1
endlocal
