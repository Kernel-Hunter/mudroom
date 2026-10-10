# Runs a Mudroom session end to end on Windows without a sandbox: create it,
# edit its work/ copy the way an agent would, then diff, apply, undo and
# discard through the CLI. Used by CI; needs no Docker.
#
#   scripts/windows-smoke.ps1 .build/debug/mudroom.exe

param([Parameter(Mandatory)] [string] $Mudroom)

$ErrorActionPreference = 'Stop'
$Mudroom = (Resolve-Path $Mudroom).Path
$root = Join-Path ([IO.Path]::GetTempPath()) "mudroom-smoke-$PID"
$env:MUDROOM_HOME = Join-Path $root 'home'
$env:MUDROOM_TOKEN_STORE = 'file'
$project = Join-Path $root 'project'

# Arguments go in as one array: PowerShell would drop a bare `--` passed
# to a function, and `mudroom new` needs it.
function mr([string[]] $a) {
    $out = & $Mudroom @a 2>&1 | Out-String
    Write-Host "> mudroom $a`n$out"
    if ($LASTEXITCODE -ne 0) { throw "mudroom $a exited with $LASTEXITCODE" }
    return $out
}

function expect($ok, $what) {
    if (-not $ok) { throw "FAILED: $what" }
    Write-Host "ok: $what"
}

try {
    New-Item -ItemType Directory -Force (Join-Path $project 'src') | Out-Null
    [IO.File]::WriteAllText((Join-Path $project 'src\app.txt'), "one`r`ntwo`r`nthree`r`n")
    [IO.File]::WriteAllText((Join-Path $project 'old.txt'), "bye`n")

    mr @('--version') | Out-Null
    $id = (mr @('new', $project, '--agent', 'smoke', '--', 'cmd', '/c', 'exit')).Trim()
    expect ($id -match '^[\w-]+$') "new prints a session id ($id)"

    $work = Join-Path $env:MUDROOM_HOME "sessions\$id\work"
    expect (Test-Path (Join-Path $work 'src\app.txt')) 'the project is cloned into work/'
    [IO.File]::WriteAllText((Join-Path $work 'src\app.txt'), "one`r`n2`r`nthree`r`n")
    [IO.File]::WriteAllText((Join-Path $work 'new.txt'), "added`n")
    Remove-Item (Join-Path $work 'old.txt')

    $stat = mr @('diff', 'last', '--stat')
    expect ($stat -match 'src/app.txt' -and $stat -match 'new.txt' -and $stat -match 'old.txt') 'diff --stat lists the three changes'
    $full = mr @('diff', 'last')
    expect ($full -match '\+2' -and $full -match '-two') 'diff shows the edited line'
    $hunks = mr @('hunks', 'last', 'src/app.txt')
    expect ($hunks -match '1') 'hunks numbers the change'

    mr @('apply', 'last', '--all') | Out-Null
    expect ([IO.File]::ReadAllText((Join-Path $project 'src\app.txt')) -eq "one`r`n2`r`nthree`r`n") 'apply writes the edit, CRLF intact'
    expect (Test-Path (Join-Path $project 'new.txt')) 'apply adds the new file'
    expect (-not (Test-Path (Join-Path $project 'old.txt'))) 'apply deletes the removed file'

    mr @('undo', 'last') | Out-Null
    expect ([IO.File]::ReadAllText((Join-Path $project 'src\app.txt')) -eq "one`r`ntwo`r`nthree`r`n") 'undo restores the edit'
    expect (-not (Test-Path (Join-Path $project 'new.txt'))) 'undo removes the added file'
    expect (Test-Path (Join-Path $project 'old.txt')) 'undo brings back the deleted file'

    $list = mr @('list')
    expect ($list -match $id) 'list shows the session'
    mr @('discard', $id) | Out-Null
    expect (-not (Test-Path $work)) 'discard deletes the clones'
    expect (Test-Path (Join-Path $project 'src\app.txt')) 'discard leaves the project alone'
    Write-Host 'smoke test passed'
} finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
