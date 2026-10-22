# Read-only SWD probe + flash dump of the motion MCU. Writes dumps/mcu_<timestamp>_*.
#   powershell -ExecutionPolicy Bypass -File tools\swd\dump_mcu.ps1                 # Raspberry Pi Debug Probe
#   powershell -ExecutionPolicy Bypass -File tools\swd\dump_mcu.ps1 -Probe stlink
param([ValidateSet('cmsis-dap', 'stlink')][string]$Probe = 'cmsis-dap')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
$oc = (Get-Command openocd -ErrorAction SilentlyContinue).Source
if (-not $oc) {
    $oc = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter openocd.exe |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $oc) { throw 'openocd not found (winget install xpack-dev-tools.openocd-xpack)' }

New-Item -ItemType Directory -Force "$root\dumps" | Out-Null
$out = "dumps/mcu_$(Get-Date -Format yyyyMMdd_HHmmss)"
Push-Location $root
# openocd logs to stderr; don't let Windows PowerShell treat that as a terminating error
$ErrorActionPreference = 'Continue'
try {
    & $oc -c "set PROBE $Probe" -f tools/swd/gd32_readonly.cfg -c "set OUT $out" -c 'probe_and_dump' 2>&1 |
        Tee-Object -FilePath "${out}_openocd.log"
} finally { Pop-Location }
Get-ChildItem "$root\$out*" | ForEach-Object {
    '{0,-40} {1,8} B  SHA256 {2}' -f $_.Name, $_.Length, (Get-FileHash $_.FullName).Hash.Substring(0, 16)
}
