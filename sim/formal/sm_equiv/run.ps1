# run.ps1 - prove the two store-merge forms of mem_engine.sv (me_store_merge OLD = 1, the
# original, and OLD = 0, the replicate + one-hot form) equal for every input, at 4, 8 and 16
# lanes. sm_equiv.sv is the miter: both forms on the same free inputs, output `bad` = they
# differ. yosys maps it to an and-inverter graph with `bad` as its only output and ABC's
# combinational prover (iprove: simulation, fraiging, SAT) proves `bad` constant 0.
#   powershell -ExecutionPolicy Bypass -File sim/formal/sm_equiv/run.ps1 [-Lanes 4,8,16]
# The original form's variable-position writes leave undefined padding for positions past
# the line, which no index reaches (word offset < LW, byte < 4); setundef -zero ties it off.
param([int[]]$Lanes = @(4, 8, 16))
$env:PATH = "C:\tools\oss-cad-suite\bin;C:\tools\oss-cad-suite\lib;" + $env:PATH
$here = $PSScriptRoot
$rtl  = (Resolve-Path (Join-Path $here '..\..\..\rtl\accel')).Path
$fail = 0
foreach ($nl in $Lanes) {
    $ys = @"
plugin -i slang
read_slang --top sm_equiv -G NL=$nl $rtl\simtix_pkg.sv $rtl\mem_engine.sv $here\sm_equiv.sv
prep -top sm_equiv
flatten
setundef -zero
techmap
opt -fast
aigmap
setundef -zero
opt_clean
select -module sm_equiv w:ok
delete -output
select -clear
write_aiger -zinit $here\sm_l$nl.aig
"@
    $f = Join-Path $here "sm_l$nl.ys"
    $ys | Out-File -Encoding ascii $f
    & yosys -q -l (Join-Path $here "sm_l$nl.log") -s $f *> $null
    if ($LASTEXITCODE -ne 0) { "lanes $nl : yosys failed, see sm_l$nl.log"; $fail++; continue }
    $out = & yosys-abc -c "read $here\sm_l$nl.aig; print_stats; iprove" 2>&1 | Out-String
    $out | Out-File -Encoding ascii (Join-Path $here "sm_l${nl}_abc.log")
    if ($out -match 'UNSATISFIABLE|Networks are equivalent') { "lanes $nl : PROVED equivalent (ABC iprove)" }
    else { "lanes $nl : NOT PROVED`n$out"; $fail++ }
}
exit $fail
