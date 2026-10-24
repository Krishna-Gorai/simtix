# Launch Vortex's out-of-context synthesis + implementation (hw/syn/xilinx/dut/project.tcl)
# detached, with Vivado 2025.1 on Windows.
#   Vortex, staged by gen_sources.sh:
#     powershell -ExecutionPolicy Bypass -File run_syn.ps1 [-Name zcu104_1c4w8t] [-Mhz 100]
#   SIMTiX's board top through the same flow:
#     powershell -ExecutionPolicy Bypass -File run_syn.ps1 -Name simtix_ps_top -Top simt_ps_top
# Writes <Root>\<Name>\build.log, and the reports (timing.rpt, post_impl_util.rpt,
# power_vectorless.rpt, synth_summary.csv) next to it.
param([string]$Name = 'zcu104_1c4w8t', [int]$Mhz = 100, [string]$Root = 'C:\work\vortex_syn',
      [string]$Top = 'Vortex')
$dir = Join-Path $Root $Name
New-Item -ItemType Directory -Force $dir | Out-Null
$env:NoDefaultCurrentDirectoryInExePath = $null
$fwd = $Root -replace '\\', '/'
$env:TOOL_DIR     = "$fwd/scripts"
$env:MAX_JOBS     = '2'
$env:OPT_LEVEL    = '3'
$env:CLK_FREQ_MHZ = "$Mhz"
# The SLR interface gate needs the XRT flow's IP stubs; a single-die Zynq has no SLRs.
$env:MODULE_INTERFACE_CHECK = 'off'
if ($Top -eq 'Vortex') {
    $env:FPU_IP = 'project_1/ip'               # Xilinx floating-point IPs (FPU_TYPE=DSP)
    $sources = 'project_1/sources.txt'
} else {
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $env:SIMTIX_ROOT = $repo -replace '\\', '/'
    $sources = (Join-Path $PSScriptRoot 'simtix_sources.txt') -replace '\\', '/'
}
$vargs = @('-mode', 'batch', '-log', 'build.log', '-nojournal',
           '-source', "$fwd/dut/project.tcl",
           '-tclargs', $Top, 'xczu7ev-ffvc1156-2-e', $sources, "$fwd/dut/project.xdc")
$p = Start-Process -FilePath 'C:\Xilinx\xic\2025.1\Vivado\bin\vivado.bat' -ArgumentList $vargs `
        -WorkingDirectory $dir -WindowStyle Hidden -PassThru
"started PID $($p.Id) in $dir at $(Get-Date -Format 'HH:mm') ($Top, $Mhz MHz)"
