#Requires -Version 7.6

<#
.SYNOPSIS
agent-detect — ship the harness configs from macOS to Linux over rsync.

.DESCRIPTION
Run this ON the macOS host (pwsh). It pushes each harness's config/auth/state directory (the set from CONTRIBUTING.md "per-harness config locations") to the Linux host over ssh, so a freshly provisioned daemon host can run the harnesses without re-configuring each one by hand.

Safety rails:

- dry-run by default; pass -Apply to transfer for real
- never deletes on the destination (no --delete, ever)
- closes nothing for you: quit the harnesses on both hosts first, so the sqlite stores (.db/-wal/-shm) are not copied mid-write
- macOS Keychain tokens are not files and do not transfer — expect a one-time re-login per harness that keeps its auth in the keychain

.EXAMPLE
pwsh -File ./scripts/sync-harness-configs.ps1 user@linux-host

.EXAMPLE
pwsh -File ./scripts/sync-harness-configs.ps1 -Apply user@linux-host
#>
[CmdletBinding()]
param(
	[Parameter(Position = 0)] [string]$Remote,
	[switch]$Apply,
	[string[]]$Harness,
	[switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ($Help) {
	@'
usage: pwsh -File ./scripts/sync-harness-configs.ps1 [-Apply] [-Harness <id>[,<id>]] <user@linux-host>

  (no flags)      dry-run: print what rsync would transfer, transfer nothing
  -Apply          transfer for real (rsync -a; the destination keeps extra files)
  -Harness        restrict to the named harness ids (comma separated)
'@ | Write-Host
	exit 0
}

if (-not $Remote) { throw 'missing <user@linux-host> argument (see -Help)' }
if (-not $IsMacOS) { throw "run this on the macOS host (detected platform is not macOS)" }
if (-not (Get-Command rsync -ErrorAction Ignore)) { throw 'rsync not found on PATH' }
if (-not (Get-Command ssh -ErrorAction Ignore)) { throw 'ssh not found on PATH' }

# --- what ships: the config-location table, one directory per harness ----------

$HarnessPaths = @{
	cline     = @('.cline/')
	'kimi-code' = @('.kimi-code/')
	mmx       = @('.mmx/')
	pi        = @('.pi/')
	qwen      = @('.qwen/')
	kilo      = @('.local/share/kilo/')
	omp       = @('.omp/')
	reasonix  = @('.reasonix/')
	# config only; project .crush/ stores stay per-project
	crush     = @('.local/share/crush/')
	opencode  = @('.local/share/opencode/')
	vibe      = @('.vibe/')
	cursor    = @('.cursor/')
	copilot   = @('.copilot/')
	hermes    = @('.hermes/')
	goose     = @('.config/goose/')
	zcode     = @('.zcode/')
}

$Selected = if ($Harness) {
	$unknown = @($Harness | Where-Object { -not $HarnessPaths.ContainsKey($_) })
	if ($unknown.Count -gt 0) { throw "unknown harness id(s): $($unknown -join ', ')" }
	$Harness
} else {
	@($HarnessPaths.Keys)
}

# --- preflight -------------------------------------------------------------------

Write-Host "checking ssh: $Remote"
& ssh -o BatchMode=yes $Remote 'true' *> $null
if ($LASTEXITCODE -ne 0) {
	throw "ssh to $Remote needs a login (BatchMode failed) — authenticate, then re-run"
}

# --- transfer --------------------------------------------------------------------

$flags = $Apply ? @('-a') : @('-a', '-n')
$label = $Apply ? 'APPLY' : 'DRY-RUN (pass -Apply to transfer)'
$excludes = @('.DS_Store', '*.log', 'node_modules/', 'cache/', 'Cache/', 'Cache_Data/', 'logs/', 'tmp/') |
	ForEach-Object { "--exclude=$_" }

Write-Host "$label — $(hostname) -> $Remote`n"
foreach ($id in $Selected) {
	foreach ($path in $HarnessPaths[$id]) {
		$src = Join-Path $HOME ($path.TrimEnd('/'))
		if (-not (Test-Path $src)) {
			Write-Host ('[skip]   {0,-10} {1} (absent on this host)' -f $id, $path)
			continue
		}
		Write-Host ('[sync]   {0,-10} {1}' -f $id, $path)
		$destDir = Split-Path $path -Parent
		# the destination parent must exist; rsync -a with a trailing slash copies
		# contents into the destination directory, and never deletes. the mkdir is
		# a write, so it runs only under -Apply.
		if ($Apply -and $destDir) {
			& ssh $Remote ('mkdir -p "$HOME/{0}"' -f $destDir)
		}
		# $HOME stays literal (single-quoted format) so the remote shell expands it
		& rsync @flags @excludes --info=stats1 -e ssh ($HOME + '/' + $path) ('{0}:$HOME/{1}' -f $Remote, $path)
	}
}

Write-Host "`ndone. re-login per harness whose auth lived in the macOS keychain, then run: pwsh ./scripts/install-harnesses.ps1 -Check on the linux host"
exit 0
