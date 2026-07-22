@echo off
REM ============================================================================
REM run_postsynth_mnist_sim.bat  -  post-SYNTHESIS functional simulation of the
REM                                 reduced-image MNIST chip (chip_top_mnist_short)
REM                                 in Vivado xsim.
REM
REM Simulates the synthesized gate-level netlist (UNISIM primitives) that
REM synth_postsynth_mnist.tcl emits at
REM   postsynth_mnist/chip_top_mnist_short_funcsim.v
REM driven by the self-checking testbench tests/tb_chip_mnist_short.sv. A PASS
REM proves the synthesized hardware reproduces the golden digits (result = 2) with
REM the host CPU streaming weights from the BRAM store. The netlist logic is
REM identical to the PPA build (chip_top_mnist); only the driver ROM is the short
REM (-DNIMG=2) build, so the run finishes in minutes instead of hours.
REM
REM Prereq:  cd fpga && vivado -mode batch -source synth_postsynth_mnist.tcl
REM Usage:   cd fpga && run_postsynth_mnist_sim.bat   (or from PowerShell: & .\run_postsynth_mnist_sim.bat)
REM
REM Override the Vivado install dir with the VIVADO_BIN env var if needed.
REM ============================================================================
setlocal
if "%VIVADO_BIN%"=="" set VIVADO_BIN=D:\2025.1\Vivado\bin
set GLBL=%VIVADO_BIN%\..\data\verilog\src\glbl.v

cd /d "%~dp0postsynth_mnist" || exit /b 1

echo [postsynth_mnist] compiling synthesized gate-level netlist...
call "%VIVADO_BIN%\xvlog.bat" chip_top_mnist_short_funcsim.v          || exit /b 1
echo [postsynth_mnist] compiling testbench + glbl...
call "%VIVADO_BIN%\xvlog.bat" -sv ..\..\tests\tb_chip_mnist_short.sv  || exit /b 1
call "%VIVADO_BIN%\xvlog.bat" "%GLBL%"                                || exit /b 1
echo [postsynth_mnist] elaborating (unisims_ver + secureip + glbl GSR)...
call "%VIVADO_BIN%\xelab.bat" tb_chip_mnist_short glbl -L unisims_ver -L secureip -L xpm ^
     -s mnist_postsynth --timescale 1ns/1ps                          || exit /b 1
echo [postsynth_mnist] running simulation...
call "%VIVADO_BIN%\xsim.bat" mnist_postsynth -runall                 || exit /b 1
endlocal
