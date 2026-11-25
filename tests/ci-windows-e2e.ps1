# Windows end-to-end check of the BUILT installer (dist/install.ps1), run by CI under both
# `pwsh` and Windows PowerShell 5.1:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/ci-windows-e2e.ps1 -Mode independent|shared
# Everything happens under a temp HOME/USERPROFILE; the runner's real profile is never touched.
param(
  [ValidateSet('independent', 'shared')][string]$Mode = 'independent',
  [string]$Installer = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\install.ps1')
)
$ErrorActionPreference = 'Continue'
$script:fails = 0
function Check([bool]$ok, [string]$name) {
  if ($ok) { Write-Host "PASS: $name" } else { Write-Host "FAIL: $name"; $script:fails++ }
}
function Fwd([string]$p) { return ($p -replace '\\', '/') }
function Find-GitBash {
  foreach ($c in @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe")) {
    if ($c -and (Test-Path $c)) { return $c }
  }
  throw 'Git Bash not found'
}
function Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

$psExe = (Get-Process -Id $PID).Path
$gitBash = Find-GitBash
$root = Join-Path ([IO.Path]::GetTempPath()) ('kit-ci-' + [Guid]::NewGuid().ToString('N'))
$home1 = Join-Path $root 'home'
New-Item -ItemType Directory -Path $home1 | Out-Null
$env:USERPROFILE = $home1
$env:HOME = $home1
$env:CLAUDE_KIT_STATE = Join-Path $root 'state'
Remove-Item Env:CLAUDE_KIT_HOME -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
$env:CLAUDE_KIT_ASSUME_RUNNING = '0'
if ($Mode -eq 'shared') { $env:CLAUDE_KIT_FORCE_NO_SYMLINK = '1' }   # behave as Windows without Developer Mode
Write-Host "mode=$Mode shell=$psExe ($($PSVersionTable.PSVersion)) home=$home1"

$prim = Join-Path $home1 '.claude'
$sec = Join-Path $home1 '.claude-second'
$profiles = @($prim)
if ($Mode -eq 'shared') { $profiles = @($prim, $sec) }
$userHook = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user-hook"}]}]},"theme":"dark"}'
foreach ($p in $profiles) {
  New-Item -ItemType Directory -Path $p | Out-Null
  [IO.File]::WriteAllText((Join-Path $p 'settings.json'), $userHook)
  [IO.File]::WriteAllText((Join-Path $p 'CLAUDE.md'), "# my own rules`n")
}
$before = @{}
foreach ($p in $profiles) {
  $before[$p] = @{ s = (Sha (Join-Path $p 'settings.json')); c = (Sha (Join-Path $p 'CLAUDE.md')) }
}

# ---- install through the built PowerShell installer
$args1 = @('--yes')
foreach ($p in $profiles) { $args1 += @('--profile', (Fwd $p)) }
if ($Mode -eq 'shared') { $args1 += @('--mode', 'shared', '--primary', (Fwd $prim)) }
& $psExe -NoProfile -ExecutionPolicy Bypass -File $Installer @args1 | Out-Host
Check ($LASTEXITCODE -eq 0) "install exit code 0 (got $LASTEXITCODE)"

$kit = Join-Path $home1 '.claude-kit'
Check (Test-Path (Join-Path $kit 'hooks\session-start.sh')) 'kit home exists with hooks'
Check (Test-Path (Join-Path $kit 'bin\claude-kit')) 'claude-kit CLI installed'
$settings = Get-Content -Raw -LiteralPath (Join-Path $prim 'settings.json')
Check ($settings -match '/\.claude-kit/hooks/') 'settings.json contains kit hooks'
Check ($settings -match 'user-hook') 'settings.json keeps the user hook'
$null = $settings | ConvertFrom-Json
Check $true 'settings.json is valid JSON'
$md = Get-Content -Raw -LiteralPath (Join-Path $prim 'CLAUDE.md')
Check ($md -match 'claude-kit:begin' -and $md -match 'claude-kit:end') 'CLAUDE.md has the managed block'
Check ($md -match 'my own rules') 'CLAUDE.md keeps the user text'

if ($Mode -eq 'shared') {
  $item = Get-Item -LiteralPath (Join-Path $sec 'skills') -Force -ErrorAction SilentlyContinue
  Check ($null -ne $item) 'secondary profile has a skills entry (junction or copy)'
  $sm = Get-Content -Raw -LiteralPath (Join-Path $sec 'CLAUDE.md')
  Check ($sm -match '@') 'secondary CLAUDE.md imports the primary (no symlink fallback)'
  $ss = Get-Content -Raw -LiteralPath (Join-Path $sec 'settings.json')
  Check ($ss -match '/\.claude-kit/hooks/') 'secondary settings.json has its own kit hooks merge'
}

# ---- a kit hook really runs through Git Bash with a SessionStart payload
$payload = '{"session_id":"ci-sess","source":"startup","cwd":"' + (Fwd $root) + '","hook_event_name":"SessionStart"}'
$hook = (Fwd $kit) + '/hooks/session-start.sh'
$out = $payload | & $gitBash -c "bash '$hook' discipline"
$text = ($out | Out-String).Trim()
$ok = $false
try {
  $o = $text | ConvertFrom-Json
  $ok = ($o.hookSpecificOutput.hookEventName -eq 'SessionStart') -and ($o.hookSpecificOutput.additionalContext.Length -gt 50)
} catch { Write-Host "hook output was not JSON: $text" }
Check $ok 'session-start hook emits valid additionalContext JSON via Git Bash'
$out2 = $payload | & $gitBash -c "bash '$((Fwd $kit))/hooks/session-start.sh' platform"
Check ((($out2 | Out-String) -match 'additionalContext')) 'platform rules hook emits context (windows platform file)'

# ---- doctor
$doc = & $gitBash -c "bash '$((Fwd $kit))/bin/claude-kit' doctor" 2>&1 | Out-String
Write-Host $doc
Check ($LASTEXITCODE -eq 0) 'claude-kit doctor exit 0'

# ---- uninstall restores the profiles
& $gitBash -c "bash '$((Fwd $kit))/bin/claude-kit' uninstall --yes" 2>&1 | Out-Host
Check ($LASTEXITCODE -eq 0) 'uninstall exit code 0'
Check (-not (Test-Path $kit)) 'kit home removed'
foreach ($p in $profiles) {
  Check ((Sha (Join-Path $p 'settings.json')) -eq $before[$p].s) "settings.json restored byte-identical ($p)"
  Check ((Sha (Join-Path $p 'CLAUDE.md')) -eq $before[$p].c) "CLAUDE.md restored byte-identical ($p)"
}

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fails -gt 0) { Write-Host "$script:fails check(s) failed"; exit 1 }
Write-Host 'all checks passed'
