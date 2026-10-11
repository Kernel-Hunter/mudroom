# Runs Mudroom on Windows against a real container runtime: build the agent
# image, check the locked network, then a short session that writes a file
# in the sandbox, and diff and apply it. Needs Docker Desktop or a Podman
# machine with Linux containers. CI runs it with a Podman machine; on a PC:
#
#   scripts/windows-sandbox-check.ps1 mudroom.exe docker
#
# Uses its own MUDROOM_HOME, so your sessions and settings aren't touched.

param(
    [Parameter(Mandatory)] [string] $Mudroom,
    [Parameter(Mandatory)] [ValidateSet('docker', 'podman')] [string] $Backend,
    [switch] $SkipImageBuild
)

$ErrorActionPreference = 'Stop'
$Mudroom = (Resolve-Path $Mudroom).Path
$root = Join-Path ([IO.Path]::GetTempPath()) "mudroom-sandbox-$PID"
$env:MUDROOM_HOME = Join-Path $root 'home'
$env:MUDROOM_TOKEN_STORE = 'file'
$project = Join-Path $root 'project'

function mr([string[]] $a) {
    Write-Host "> mudroom $a"
    $out = & $Mudroom @a 2>&1 | Out-String
    Write-Host $out
    if ($LASTEXITCODE -ne 0) { throw "mudroom $a exited with $LASTEXITCODE" }
    return $out
}

function expect($ok, $what) {
    if (-not $ok) { throw "FAILED: $what" }
    Write-Host "ok: $what"
}

try {
    New-Item -ItemType Directory -Force $project | Out-Null
    [IO.File]::WriteAllText((Join-Path $project 'README.txt'), "a project`n")

    if (-not $SkipImageBuild) {
        & $Mudroom image build --backend $Backend   # streams the build log
        if ($LASTEXITCODE -ne 0) { throw "mudroom image build exited with $LASTEXITCODE" }
    }

    $check = mr @('network', 'check', '--backend', $Backend, '--project', $project)
    expect ($check -notmatch 'UNEXPECTED') 'network check: every probe as expected'

    mr @('run', $project, '--backend', $Backend, '--', 'sh', '-c', 'echo hi > hello.txt') | Out-Null
    $work = Get-ChildItem (Join-Path $env:MUDROOM_HOME 'sessions') -Directory | Select-Object -First 1
    expect ($work) 'run created a session'

    $stat = mr @('diff', 'last', '--stat')
    expect ($stat -match 'hello.txt') 'diff lists the file the sandbox wrote'
    mr @('apply', 'last', '--all') | Out-Null
    $hello = Join-Path $project 'hello.txt'
    expect ((Test-Path $hello) -and ([IO.File]::ReadAllText($hello) -eq "hi`n")) 'apply puts hello.txt in the project'
    mr @('discard', 'last') | Out-Null
    Write-Host "sandbox check passed with $Backend"
} finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
