param([string]$Label = "UNLABELED")

# RX25 receive-path probe: capture the same register set at a known phase and
# attempt one 16-byte read so the "before" and "after" of a single attempt are
# both recorded.  Appends to a single log so the four phases line up in order.

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tool = Join-Path $root "tools\bin\rx25_pa_tool.exe"
$outDir = Join-Path $root "outputs\rx_probe"
$log = Join-Path $outDir "rx_probe.txt"
# The device interface path is derived at runtime because the
# instance id embeds this specific card's serial number.
$inst = (Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "*VEN_1234&DEV_C070*" } | Select-Object -First 1).InstanceId
if (-not $inst) { Write-Host "no RX25 device found"; exit 1 }
$dev = "\\.\" + ($inst -replace "\\", "#") + "#{70cf91ae-6425-4ebd-a161-be86a29d1153}"

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function Log([string]$s) {
    Write-Host $s
    Add-Content -Path $log -Value $s -Encoding UTF8
}

function Dump([string]$tag) {
    Log "  -- $tag --"
    $o = & $tool --device $dev --regs 0x000:21 2>&1 | Out-String
    $kept = 0
    foreach ($line in ($o -split "`r?`n")) {
        if ($line -match '^\s*0x[0-9a-fA-F]{3}\s') { Log ("    " + $line.Trim()); $kept++ }
    }
    # If the output format ever differs, keep the raw text rather than logging
    # an empty section and losing the measurement.
    if ($kept -eq 0) {
        foreach ($line in ($o -split "`r?`n")) {
            if ($line.Trim()) { Log ("    RAW: " + $line.Trim()) }
        }
    }
    if ($o -match 'open failed:\s*(\d+)') { Log ("    OPEN_FAILED " + $Matches[1]) }
}

Log ""
Log "================================================================"
Log ("PHASE {0}   {1}" -f $Label, (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Log "================================================================"

Dump "before read attempt"

$rf = Join-Path $outDir ("read_" + $Label + ".txt")
$r = & $tool --device $dev --read-pa 0x10000000 --length 16 --skip-arm --output $rf 2>&1 | Out-String
foreach ($line in ($r -split "`r?`n")) {
    if ($line -match 'cq status|cq bytes|never matched|stage=|FAIL|OK|open failed') {
        Log ("    " + $line.Trim())
    }
}

Dump "after read attempt"

Log ""
