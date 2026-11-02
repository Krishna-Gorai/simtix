# capture_uart.ps1  -  record the A53 console of the board into a file
#
#   powershell -ExecutionPolicy Bypass -File sw\ps_host\capture_uart.ps1 [-Port COM3]
#              [-Out docs\zcu102_board_run.txt] [-Minutes 120]
#
# Opens the UART (115200 8N1) and appends every line it receives, with a time stamp,
# to the output file and the screen. Stops at the "RESULT:" line of the host
# program (sw/ps_host/main.c) or after -Minutes. Start it BEFORE run_board.tcl.
# On the ZCU102 the A53 console is the first port of the CP2108 (COM3 on this PC).
param(
    [string]$Port = 'COM3',
    [string]$Out = (Join-Path $PSScriptRoot '..\..\docs\zcu102_board_run.txt'),
    [int]$Minutes = 120
)
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
$sp.ReadTimeout = 1000
$sp.NewLine = "`n"
$sp.Open()
$out = [System.IO.Path]::GetFullPath($Out)
"# $Port capture started $(Get-Date -Format s)" | Out-File -FilePath $out -Encoding utf8
Write-Host "capturing $Port -> $out (stops at RESULT or after $Minutes min)"
$end = (Get-Date).AddMinutes($Minutes)
try {
    while ((Get-Date) -lt $end) {
        try { $line = $sp.ReadLine().TrimEnd("`r") }
        catch {
            # PowerShell 5.1 wraps .NET exceptions: a read timeout is the inner one
            $ex = $_.Exception
            if ($ex -is [System.TimeoutException] -or $ex.InnerException -is [System.TimeoutException]) { continue }
            throw
        }
        $line | Out-File -FilePath $out -Append -Encoding utf8
        Write-Host $line
        if ($line -like 'RESULT:*') { break }
    }
} finally {
    $sp.Close()
    "# capture ended $(Get-Date -Format s)" | Out-File -FilePath $out -Append -Encoding utf8
}
