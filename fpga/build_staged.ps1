# build_staged.ps1 - the ZCU102 board build in stages, with no Vivado holding the project
# while synthesis or implementation runs (create_bd_ps.tcl prep / implprep / finish; the runs
# execute alone from their runme.bat). For hosts with too little RAM for the one-process
# build (16 lanes on the 7.8 GB laptop). Run from PowerShell:
#
#   powershell -ExecutionPolicy Bypass -File fpga\build_staged.ps1 tagl16 lanes16 warps8 l1kb128 mshr16 mtags16 mhz100 lowmem
#
# The arguments go to create_bd_ps.tcl unchanged (zcu102 is the default board). Progress
# lines go to fpga\build_staged_<tag>.log; the last line is BUILD OK or BUILD FAILED.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$BdArgs)
$ErrorActionPreference = 'Continue'   # each step's result is checked explicitly (5.1 would turn native stderr into errors)
$env:NoDefaultCurrentDirectoryInExePath = $null
$fpga = $PSScriptRoot
Set-Location $fpga
$viv = 'C:\Xilinx\xic\2025.1\Vivado\bin\vivado.bat'
$tag = ($BdArgs | Where-Object { $_ -match '^tag(\w+)$' } | Select-Object -First 1) -replace '^tag', ''
$sfx = '_zcu102' + $(if ($tag) { "_$tag" } else { '' })
if ($BdArgs -contains 'zcu104') { $sfx = $(if ($tag) { "_$tag" } else { '' }) }
$log = Join-Path $fpga "build_staged$sfx.log"
$runs = Join-Path $fpga "simtix_ps$sfx\simtix_ps.runs"

function Note($m) {
    $free = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
    "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') [free $free MB] $m" | Tee-Object -FilePath $log -Append
}
function Fail($m) { Note "BUILD FAILED: $m"; exit 1 }
function Vivado($stage) {
    & $viv -mode batch -nojournal -log (Join-Path $fpga "build_staged$sfx`_$stage.log") `
        -source create_bd_ps.tcl -tclargs (@($stage) + $BdArgs) *> $null
    if ($LASTEXITCODE -ne 0) { Fail "vivado $stage exit $LASTEXITCODE (see build_staged$sfx`_$stage.log)" }
}
function RunMe($run, $okPattern) {
    $dir = Join-Path $runs $run
    if (-not (Test-Path "$dir\runme.bat")) { Fail "no $dir\runme.bat" }
    Push-Location $dir
    & cmd.exe /c runme.bat *> $null
    Pop-Location
    if (-not (Select-String -Path "$dir\runme.log" -Pattern $okPattern -Quiet)) { Fail "$run did not finish (see $dir\runme.log)" }
}

Note "start: $($BdArgs -join ' ')"
Note "stage prep (project, block design, synth_1 scripts)"
Vivado 'prep'
Note "synth_1 running alone"
RunMe 'synth_1' 'synth_design completed successfully'
$peak = (Select-String -Path "$runs\synth_1\runme.log" -Pattern 'synth_design: Time.*peak = ([0-9.]+)' | Select-Object -Last 1).Matches.Groups[1].Value
Note "synth_1 done, peak $peak MB"
Note "stage implprep (impl_1 scripts)"
Vivado 'implprep'
Note "impl_1 running alone (opt, place, phys_opt, route, post-route phys_opt, bitstream)"
RunMe 'impl_1' 'write_bitstream completed successfully'
Note "impl_1 done"
Note "stage finish (reports, routed netlist, XSA)"
Vivado 'finish'
$sum = Select-String -Path (Join-Path $fpga "build_staged$sfx`_finish.log") -Pattern '========== BOARD BUILD' | Select-Object -Last 1
Note "$($sum.Line)"
Note "BUILD OK: simtix_ps$sfx.xsa"
