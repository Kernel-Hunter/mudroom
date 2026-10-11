# Runs Mudroom on Windows against a real container runtime: build the agent
# image, check the network, then a short session that writes a file in the
# sandbox, and diff and apply it. Needs Docker Desktop or a Podman machine
# with Linux containers. On a PC:
#
#   scripts/windows-sandbox-check.ps1 mudroom.exe docker
#   scripts/windows-sandbox-check.ps1 mudroom.exe podman -Network open
#
# -Network picks the mode for both the check and the session (default:
# locked, the allowlist proxy). Uses its own MUDROOM_HOME, so your sessions
# and settings aren't touched.

param(
    [Parameter(Mandatory)] [string] $Mudroom,
    [Parameter(Mandatory)] [ValidateSet('docker', 'podman')] [string] $Backend,
    [ValidateSet('locked', 'open', 'offline')] [string] $Network = 'locked',
    [switch] $SkipImageBuild
)

$ErrorActionPreference = 'Stop'
$Mudroom = (Resolve-Path $Mudroom).Path
$root = Join-Path ([IO.Path]::GetTempPath()) "mudroom-sandbox-$PID"
$env:MUDROOM_HOME = Join-Path $root 'home'
$env:MUDROOM_TOKEN_STORE = 'file'
$project = Join-Path $root 'project'

# Prints the output as it comes and returns it as one string.
function mr([string[]] $a) {
    Write-Host "> mudroom $a"
    & $Mudroom @a 2>&1 | Tee-Object -Variable lines | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "mudroom $a exited with $LASTEXITCODE" }
    return ($lines | Out-String)
}

function expect($ok, $what) {
    if (-not $ok) { throw "FAILED: $what" }
    Write-Host "ok: $what"
}

try {
    New-Item -ItemType Directory -Force $project | Out-Null
    [IO.File]::WriteAllText((Join-Path $project 'README.txt'), "a project`n")

    if (-not $SkipImageBuild) { mr @('image', 'build', '--backend', $Backend) | Out-Null }

    $check = mr @('network', 'check', '--backend', $Backend, '--project', $project, '--mode', $Network)
    expect ($check -notmatch 'UNEXPECTED') "network check ($Network): every probe as expected"

    mr @('run', $project, '--backend', $Backend, '--network', $Network, '--', 'sh', '-c', 'echo hi > hello.txt') | Out-Null
    $stat = mr @('diff', 'last', '--stat')
    expect ($stat -match 'hello.txt') 'diff lists the file the sandbox wrote'
    mr @('apply', 'last', '--all') | Out-Null
    $hello = Join-Path $project 'hello.txt'
    expect ((Test-Path $hello) -and ([IO.File]::ReadAllText($hello) -eq "hi`n")) 'apply puts hello.txt in the project'
    mr @('discard', 'last') | Out-Null
    Write-Host "sandbox check passed: $Backend, $Network network"
} finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
