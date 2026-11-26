# run_power_all.ps1 - board power of every machine on every suite (docs/power_plan.md)
#
#   powershell -ExecutionPolicy Bypass -File sw\ps_host\run_power_all.ps1 [-Only name,name] [-BuildOnly]
#
# For each run: a Vitis build of the host with the power pass alone (build option power),
# the Vitis servers the build leaves behind stopped (they lock the next workspace), then the
# board run over JTAG (xsdb), its console written to docs\power_runs\zcu102_power_<name>.txt.
# The ZCU102 must be powered with the JTAG cable connected. A run whose log already ends with
# the host's RESULT line is skipped, so the script can be started again after a stop.
param([string[]]$Only, [switch]$BuildOnly)
if ($Only) { $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }   # -File passes one string

$R     = 'C:\work\SIMTiX-v2'
$VITIS = 'C:\Xilinx\xic\2025.1\Vitis\bin\vitis.bat'
$XSDB  = 'C:\Xilinx\xic\2025.1\Vivado\bin\xsdb.bat'
$OUT   = Join-Path $R 'docs\power_runs'
New-Item -ItemType Directory -Force $OUT | Out-Null
Remove-Item Env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue
Set-Location $R

$X8   = 'fpga\simtix_ps_zcu102_v3b34.xsa'            # the paper's 8-lane design, 115.37 MHz
$XFG  = 'baselines\fgpu\fgpu_ps_zcu102_f188.xsa'      # FGPU at 187.48 MHz
$runs = @()
foreach ($s in @('apps', 'rodinia', 'rivec')) {
    $sa = @(); if ($s -ne 'apps') { $sa = @($s) }
    $runs += @{ name = "simtix8_$s";  build = @('sw\ps_host\build_vitis.py') + $sa + @('power', $X8)
                elf = 'sw\ps_host\ws_zcu102\ps_host\build\ps_host.elf'
                run = @('sw\ps_host\run_board.tcl') + $sa }
    $runs += @{ name = "simtix16_$s"; build = @('sw\ps_host\build_vitis.py', 'lanes16') + $sa + @('power')
                elf = 'sw\ps_host\ws_zcu102_l16\ps_host\build\ps_host.elf'
                run = @('sw\ps_host\run_board.tcl', 'lanes16') + $sa }
    $runs += @{ name = "vortex_$s";   build = @('baselines\vortex\host\build_vitis_vortex.py') + $sa + @('power')
                elf = 'baselines\vortex\host\ws_zcu102\vx_host\build\vx_host.elf'
                run = @('baselines\vortex\host\run_board_vortex.tcl') + $sa }
    $runs += @{ name = "fgpu_$s";     build = @('baselines\fgpu\host\build_vitis_fgpu.py', $s, 'power', $XFG)
                elf = "baselines\fgpu\host\ws_zcu102_$s\fg_host\build\fg_host.elf"
                run = @('baselines\fgpu\host\run_board_fgpu.tcl', $s) }
    $runs += @{ name = "ara_$s";      build = @('baselines\ara\host\build_vitis_ara.py') + $sa + @('power')
                elf = 'baselines\ara\host\ws_zcu102\ara_host\build\ara_host.elf'
                run = @('baselines\ara\host\run_board_ara.tcl') + $sa }
}

function Stop-VitisServers {
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'RigelApp|slxcmd\.py' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
}

foreach ($run in $runs) {                # ($r would be $R: PowerShell names ignore case)
    if ($Only -and ($Only -notcontains $run.name)) { continue }
    $log = Join-Path $OUT "zcu102_power_$($run.name).txt"
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'RESULT' -Quiet)) {
        Write-Host "== $($run.name): done before, skipped"; continue
    }
    Write-Host "== $($run.name): build  ($(Get-Date -Format HH:mm))"
    Stop-VitisServers
    Remove-Item (Join-Path $R $run.elf) -ErrorAction SilentlyContinue
    $blog = Join-Path $OUT "build_$($run.name).log"
    # vitis.bat returns only when the Vitis server the build leaves behind exits, about 10 min
    # after the build: start it without waiting, watch its log for the build script's last
    # line ("ELF: ..."), then stop the server and the batch (20 min at most)
    $cl = '"' + $VITIS + '" -s ' + ($run.build -join ' ') + ' > "' + $blog + '" 2>&1'
    # cmd /c drops the first and last quote of the line: one more pair keeps the paths quoted
    $p = Start-Process -FilePath cmd.exe -ArgumentList '/c', ('"' + $cl + '"') -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 240; $i++) {         # (vitis.bat can exit while the build goes on)
        Start-Sleep -Seconds 5
        if ((Test-Path $blog) -and (Select-String -Path $blog -Pattern '^ELF:' -Quiet)) { break }
    }
    # the ELF can appear only after that line: wait until it exists with a settled size (2 min)
    $elf = Join-Path $R $run.elf; $last = -1
    for ($i = 0; $i -lt 24; $i++) {
        if (Test-Path $elf) { $sz = (Get-Item $elf).Length; if ($sz -gt 0 -and $sz -eq $last) { break }; $last = $sz }
        Start-Sleep -Seconds 5
    }
    Stop-VitisServers
    if (-not $p.HasExited) { & taskkill /T /F /PID $p.Id 2>&1 | Out-Null }
    Stop-VitisServers
    if (-not (Test-Path (Join-Path $R $run.elf))) {
        Write-Host "   build FAILED: see $OUT\build_$($run.name).log"; continue
    }
    if ($BuildOnly) { Write-Host '   built'; continue }
    Write-Host "== $($run.name): board  ($(Get-Date -Format HH:mm))"
    $xl = '"' + $XSDB + '" ' + (($run.run + @($log)) -join ' ') + ' > "' + (Join-Path $OUT "xsdb_$($run.name).log") + '" 2>&1'
    # as the build: cmd keeps the quoting; wait for the batch itself (hw_server, which xsdb
    # starts, keeps running and is no reason to wait)
    $px = Start-Process -FilePath cmd.exe -ArgumentList '/c', ('"' + $xl + '"') -WindowStyle Hidden -PassThru
    $px.WaitForExit()
    $n = 0; if (Test-Path $log) { $n = @(Select-String -Path $log -Pattern '^POWER,(?!app,)').Count }
    $res = 'no RESULT line'
    if (Test-Path $log) { $m = Select-String -Path $log -Pattern 'RESULT.*' | Select-Object -Last 1; if ($m) { $res = $m.Line } }
    Write-Host "   $n POWER rows; $res"
}
Write-Host "== all done ($(Get-Date -Format HH:mm))"
