# Checks a Windows release zip on a machine without Swift: unzip it, run
# mudroom.exe --version and --help, then the CLI smoke test against the
# unzipped exe. CI runs it on a fresh runner that never had Swift installed.
#
#   scripts/windows-zip-check.ps1 dist/mudroom-0.2.0-windows-x86_64.zip

param([Parameter(Mandatory)] [string] $Zip)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Zip = (Resolve-Path $Zip).Path
$name = [IO.Path]::GetFileNameWithoutExtension($Zip)
if ($name -notmatch '^mudroom-(.+)-windows-(x86_64|arm64)$') { throw "unexpected zip name $name" }
$version = $Matches[1]
$tmp = $env:RUNNER_TEMP ?? [IO.Path]::GetTempPath()

function expect($ok, $what) {
    if (-not $ok) { throw "FAILED: $what" }
    Write-Host "ok: $what"
}

# Runs mudroom.exe with a time limit, so a loader error can't hang the job.
function run([string] $exe, [string[]] $arguments) {
    $out = Join-Path $tmp "mudroom-out-$PID.txt"
    $err = Join-Path $tmp "mudroom-err-$PID.txt"
    $p = Start-Process $exe -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle   # without this, ExitCode can come back empty
    if (-not $p.WaitForExit(60000)) { $p.Kill(); throw "mudroom $arguments timed out" }
    $p.WaitForExit()
    [pscustomobject] @{
        Code   = $p.ExitCode
        Stdout = (Get-Content -Raw $out) ?? ''
        Stderr = (Get-Content -Raw $err) ?? ''
    }
}

$sha = (Get-FileHash $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
if (Test-Path "$Zip.sha256") {
    expect ((Get-Content -Raw "$Zip.sha256") -match "^$sha  $name\.zip") 'the .sha256 file matches the zip'
}

$dir = Join-Path $tmp "mudroom-zip-check-$PID"
Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
Expand-Archive $Zip -DestinationPath $dir
$exe = Join-Path $dir "$name\mudroom.exe"
expect (Test-Path $exe) "the zip holds $name\mudroom.exe"
$dlls = Get-ChildItem (Split-Path $exe) -Filter *.dll | ForEach-Object Name
Write-Host "DLLs in the zip: $($dlls -join ', ')"

# The point of the test: nothing from a Swift install may be on this machine.
expect (-not (Get-Command swift -ErrorAction SilentlyContinue)) 'no swift on PATH'
expect (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\Swift'))) 'no Swift install in %LOCALAPPDATA%\Programs\Swift'
$elsewhere = foreach ($d in $env:PATH -split ';' | Where-Object { $_ }) {
    foreach ($dll in $dlls) {
        if ($dll -match '^(vcruntime|msvcp|concrt)') { continue }   # the runner has the VC++ redistributable
        if (Test-Path (Join-Path $d $dll)) { Join-Path $d $dll }
    }
}
expect (-not $elsewhere) "no bundled Swift DLL exists elsewhere on PATH $elsewhere"

$r = run $exe @('--version')
expect ($r.Code -eq 0 -and $r.Stdout.Trim() -eq $version) "mudroom --version prints $version (got '$($r.Stdout.Trim())', exit $($r.Code))"
$r = run $exe @('--help')
Write-Host $r.Stdout
expect ($r.Code -eq 0 -and $r.Stdout -match 'USAGE: mudroom') 'mudroom --help prints the usage'

# Take swiftCore.dll away and the exe must stop loading: the copy in the zip
# is the one in use, not one found somewhere else.
$core = Join-Path (Split-Path $exe) 'swiftCore.dll'
if (Test-Path $core) {
    Rename-Item $core 'swiftCore.dll.off'
    try {
        $r = run $exe @('--version')
        expect ($r.Code -ne 0) "without its swiftCore.dll the exe doesn't start (exit $($r.Code))"
    } finally {
        Rename-Item "$core.off" 'swiftCore.dll'
    }
}

& (Join-Path $PSScriptRoot 'windows-smoke.ps1') $exe
if (-not $?) { throw 'smoke test failed' }
Write-Host "zip check passed: $name"
