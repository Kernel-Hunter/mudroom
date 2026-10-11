# Packages a release build of mudroom.exe into
# dist/mudroom-<version>-windows-<arch>.zip, with every DLL it needs that
# Windows doesn't ship, and writes the zip's SHA-256 next to it.
#
#   swift build -c release --product mudroom -Xcxx -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH
#   scripts/windows-package.ps1 .build/release/mudroom.exe 0.2.0 x86_64
#
# The DLL list isn't hard-coded. Starting from mudroom.exe, it reads each
# image's imports with dumpbin and follows them:
#   - API sets (api-ms-win-*, ext-ms-win-*) are part of Windows: skipped.
#   - The Visual C++ runtime (vcruntime140*, msvcp140*, ...) is copied from
#     Visual Studio's redistributable folder, so the zip runs on a PC without
#     the VC++ redistributable installed.
#   - Anything else in System32 is part of Windows: skipped.
#   - Anything else found on PATH (the Swift runtime) is copied, and its own
#     imports are followed.
#   - Anything not found stops the script.
# Needs Visual Studio with the C++ tools (for dumpbin) and the Swift runtime
# on PATH, as after installing Swift.

param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [ValidateSet('x86_64', 'arm64')] [string] $Arch,
    [string] $OutDir = 'dist'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Exe = (Resolve-Path $Exe).Path
$repo = Split-Path $PSScriptRoot -Parent
$machine = @{ x86_64 = 'x64'; arm64 = 'ARM64' }[$Arch]
$vcArch = @{ x86_64 = 'x64'; arm64 = 'arm64' }[$Arch]

# Visual Studio: dumpbin for imports and headers, and the VC++ runtime.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -property installationPath
if (-not $vs) { throw 'Visual Studio not found' }
$hostDir = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'Hostarm64\arm64' } else { 'Hostx64\x64' }
$dumpbin = Get-ChildItem "$vs\VC\Tools\MSVC\*\bin\$hostDir\dumpbin.exe" |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $dumpbin) { throw "dumpbin.exe not found under $vs" }
$vcRedist = Get-ChildItem "$vs\VC\Redist\MSVC\*\$vcArch\Microsoft.VC*.CRT" -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'vcruntime140.dll') } |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $vcRedist) { throw "VC++ redistributable for $vcArch not found under $vs" }
Write-Host "dumpbin   $($dumpbin.FullName)"
Write-Host "VC++ CRT  $($vcRedist.FullName)"

function Get-Imports([string] $path) {
    $out = & $dumpbin.FullName /nologo /dependents $path
    if ($LASTEXITCODE -ne 0) { throw "dumpbin /dependents $path failed" }
    # Both the normal and the delay-load lists: four spaces, then a name.
    foreach ($line in $out) {
        if ($line -match '^\s{4}(\S+\.dll)\s*$') { $Matches[1] }
    }
}

function Assert-Machine([string] $path) {
    $headers = & $dumpbin.FullName /nologo /headers $path | Out-String
    if ($headers -notmatch "machine \($machine\)") {
        throw "$path is not $machine"
    }
}

$system32 = Join-Path $env:SystemRoot 'System32'
$vcPattern = '^(vcruntime|msvcp|concrt|vccorlib)\d+(_\w+)?\.dll$'
$pathDirs = $env:PATH -split ';' | Where-Object { $_ -and (Test-Path $_ -PathType Container) }

$bundle = [ordered] @{}   # DLL name (lowercase) -> source path
$queue = [Collections.Generic.Queue[string]]::new()
$queue.Enqueue($Exe)
while ($queue.Count -gt 0) {
    $image = $queue.Dequeue()
    foreach ($dll in Get-Imports $image) {
        $key = $dll.ToLowerInvariant()
        if ($bundle.Contains($key)) { continue }
        if ($key -match '^(api|ext)-ms-win-') { continue }
        if ($key -match $vcPattern) {
            $source = Join-Path $vcRedist.FullName $dll
            if (-not (Test-Path $source)) { throw "$dll (needed by $image) is not in $($vcRedist.FullName)" }
            $bundle[$key] = $source
            continue
        }
        if (Test-Path (Join-Path $system32 $dll)) { continue }
        $source = $pathDirs | ForEach-Object { Join-Path $_ $dll } | Where-Object { Test-Path $_ -PathType Leaf } |
            Select-Object -First 1
        if (-not $source) { throw "$dll (needed by $image) was not found on PATH" }
        $bundle[$key] = $source
        $queue.Enqueue($source)
    }
}

$name = "mudroom-$Version-windows-$Arch"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$stage = Join-Path $OutDir $name
$zip = Join-Path $OutDir "$name.zip"
Remove-Item -Recurse -Force $stage, $zip, "$zip.sha256" -ErrorAction SilentlyContinue
New-Item -ItemType Directory $stage | Out-Null

Copy-Item $Exe (Join-Path $stage 'mudroom.exe')
foreach ($source in $bundle.Values) { Copy-Item $source $stage }
Copy-Item (Join-Path $repo 'LICENSE') (Join-Path $stage 'LICENSE.txt')

Get-ChildItem $stage -Include *.exe, *.dll -Recurse | ForEach-Object { Assert-Machine $_.FullName }

Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zip.sha256", "$sha  $name.zip`n")

Write-Host ''
Write-Host "Bundled DLLs ($($bundle.Count)):"
foreach ($entry in $bundle.GetEnumerator()) { Write-Host "  $(Split-Path $entry.Value -Leaf)  <- $(Split-Path $entry.Value -Parent)" }
Write-Host ''
Get-ChildItem $stage | Sort-Object Name | Format-Table Name, Length -AutoSize | Out-String | Write-Host
Write-Host "zip      $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
Write-Host "sha256   $sha"
