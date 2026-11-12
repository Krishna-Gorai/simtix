# run_xsim_cases.ps1 - the board-configuration xsim (Xilinx FP IPs) on the prepared cases,
# one after the other; done marker xsim_cases_done.txt.
$env:NoDefaultCurrentDirectoryInExePath = $null
Set-Location C:\work\SIMTiX-v2\baselines\vortex\tb
Remove-Item xsim_cases_done.txt -ErrorAction SilentlyContinue
$vivado = 'C:\Xilinx\xic\2025.1\Vivado\bin\vivado.bat'
foreach ($c in 'xcase_gemm_32x32x32', 'xcase_mandel_32x16x64') {
    & $vivado -mode batch -nojournal -log "sim_$c.log" -source sim_xsim_vortex.tcl -tclargs $c *> "sim_$c.out"
}
"done $(Get-Date)" | Out-File -Encoding utf8 xsim_cases_done.txt
