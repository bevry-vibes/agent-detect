#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
agent-detect — ship the harness configs from this host to another host over rsync.

.DESCRIPTION
Run this on any pwsh host (macOS, Linux, Windows) with ssh and rsync. It pushes each harness's config/auth/state directory (the set from CONTRIBUTING.md "per-harness config locations") to the target host over ssh, so a freshly provisioned daemon host can run the harnesses without re-configuring each one by hand.

With no arguments it prompts for the target hostname, the username there, and the target platform (linux, macos, windows); pass -Remote user@host (and -TargetOs, default linux) to skip the prompts.

Path mapping per target platform: linux and macos take the same HOME-relative paths; windows keeps the dot-dirs under the profile home and moves crush to LOCALAPPDATA and goose to APPDATA (probed over ssh). Windows targets need an ssh server and rsync on PATH (scoop install rsync).

Safety rails:

- dry-run by default; pass -Apply to transfer for real
- never deletes on the destination (no --delete, ever)
- closes nothing for you: quit the harnesses on both hosts first, so the sqlite stores (.db/-wal/-shm) are not copied mid-write
- macOS Keychain / Windows Credential Manager tokens are not files and do not transfer — expect a one-time re-login per harness that keeps its auth there

.EXAMPLE
pwsh -File ./scripts/sync-harness-configs.ps1

.EXAMPLE
pwsh -File ./scripts/sync-harness-configs.ps1 -Apply balupton@linux-box -TargetOs linux
#>
[CmdletBinding()]
param(
	[Parameter(Position = 0)] [string]$Remote,
	[ValidateSet('', 'linux', 'macos', 'windows')] [string]$TargetOs = '',
	[switch]$Apply,
	[string[]]$Harness,
	[switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ($Help) {
	@'
usage: pwsh -File ./scripts/sync-harness-configs.ps1 [-Remote <user@host>] [-TargetOs linux|macos|windows] [-Apply] [-Harness <id>[,<id>]]

  (no flags)      prompt for the hostname, username, and target platform; dry-run the transfer
  -Remote         user@host; skips the prompts (prompts still fill missing parts)
  -TargetOs       linux | macos | windows (linux paths when omitted with -Remote)
  -Apply          transfer for real (rsync -a; the destination keeps extra files)
  -Harness        restrict to the named harness ids (comma separated)

The source host needs ssh and rsync; a windows target also needs an ssh server and rsync on PATH.
'@ | Write-Host
	exit 0
}

# -File passes "a,b" as one argument (pwsh -Command is what splits commas), so split it here
if ($Harness) { $Harness = @($Harness | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# --- prompts (only when the console is interactive) --------------------------------

if (-not $Remote) {
	if ([Console]::IsInputRedirected) { throw 'missing <user@host> argument and stdin is not interactive (see -Help)' }
	$hostName = (Read-Host 'target hostname').Trim()
	if (-not $hostName) { throw 'no hostname given' }
	$userName = (Read-Host 'username on the target').Trim()
	if (-not $userName) { throw 'no username given' }
	$Remote = "$userName@$hostName"
}
if (-not $TargetOs) {
	if (-not [Console]::IsInputRedirected) {
		while ($true) {
			$answer = (Read-Host 'target platform (linux / macos / windows)').Trim().ToLower()
			switch ($answer) {
				'linux' { $TargetOs = 'linux' }
				'macos' { $TargetOs = 'macos' }
				'mac' { $TargetOs = 'macos' }
				'darwin' { $TargetOs = 'macos' }
				'windows' { $TargetOs = 'windows' }
				'win' { $TargetOs = 'windows' }
				default { Write-Host 'choose one of: linux, macos, windows'; continue }
			}
			break
		}
	} else {
		$TargetOs = 'linux'   # scripted use with -Remote and no -TargetOs
	}
}

if (-not (Get-Command rsync -ErrorAction Ignore)) { throw 'rsync not found on PATH (the source host needs it)' }
if (-not (Get-Command ssh -ErrorAction Ignore)) { throw 'ssh not found on PATH' }

# --- what ships: the config-location table, one directory per harness ---------------
# HOME-relative on linux and macos; the windows overrides follow the harnesses'
# own platform split (crush lives in LOCALAPPDATA, goose in APPDATA).

$HarnessPaths = @{
	cline       = @('.cline/')
	'kimi-code' = @('.kimi-code/')
	mmx         = @('.mmx/')
	pi          = @('.pi/')
	qwen        = @('.qwen/')
	kilo        = @('.local/share/kilo/')
	omp         = @('.omp/')
	reasonix    = @('.reasonix/')
	# config only; project .crush/ stores stay per-project
	crush       = @('.local/share/crush/', '$LOCALAPPDATA/Crush/')
	opencode    = @('.local/share/opencode/')
	vibe        = @('.vibe/')
	cursor      = @('.cursor/')
	copilot     = @('.copilot/')
	hermes      = @('.hermes/')
	goose       = @('.config/goose/', '$APPDATA/Block/goose/')
	zcode       = @('.zcode/')
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

# windows targets: probe the profile home and the appdata roots, and expand the
# $LOCALAPPDATA / $APPDATA overrides in the path table with them
$remoteHome = $null
$remoteLocalAppData = $null
$remoteAppData = $null
if ($TargetOs -eq 'windows') {
	$probe = @(& ssh $Remote 'powershell -NoProfile -Command "$HOME; $env:LOCALAPPDATA; $env:APPDATA"') | Where-Object { $_ }
	if (@($probe).Count -lt 3) {
		throw 'could not probe the windows target (needs powershell reachable over ssh)'
	}
	$remoteHome = ([string]$probe[0]).Replace('\', '/')
	$remoteLocalAppData = ([string]$probe[1]).Replace('\', '/')
	$remoteAppData = ([string]$probe[2]).Replace('\', '/')
	Write-Host "windows target: home=$remoteHome localappdata=$remoteLocalAppData appdata=$remoteAppData"
}

function Get-SourcePath {
	# the local directory to ship for one table entry: $LOCALAPPDATA / $APPDATA
	# entries map from this host's own appdata (a windows source), the rest sit
	# under HOME on every platform
	param([Parameter(Mandatory)] [string]$Path)
	if ($Path -like '$LOCALAPPDATA*') {
		if (-not $env:LOCALAPPDATA) { return $null }
		$rest = ($Path -replace '^\$LOCALAPPDATA/?', '').TrimEnd('/')
		return (Join-Path $env:LOCALAPPDATA ($rest -replace '/', [IO.Path]::DirectorySeparatorChar))
	}
	if ($Path -like '$APPDATA*') {
		if (-not $env:APPDATA) { return $null }
		$rest = ($Path -replace '^\$APPDATA/?', '').TrimEnd('/')
		return (Join-Path $env:APPDATA ($rest -replace '/', [IO.Path]::DirectorySeparatorChar))
	}
	return (Join-Path $HOME ($Path.TrimEnd('/')))
}

function Get-DestPath {
	# the destination path on the target: HOME-relative as-is for linux/macos
	# (rsync resolves it against the remote home), absolute with forward slashes
	# for windows (the overrides expand, the rest land under the probed home)
	param([Parameter(Mandatory)] [string]$Path)
	if ($TargetOs -ne 'windows') { return $Path }
	$expanded = $Path.Replace('$LOCALAPPDATA', $remoteLocalAppData).Replace('$APPDATA', $remoteAppData)
	if ($expanded -eq $Path) { return "$remoteHome/$($Path.TrimEnd('/'))/" }
	return "$($expanded.TrimEnd('/'))/"
}

function Invoke-RemoteMkdir {
	# ensure the destination parent exists (runs only under -Apply)
	param([Parameter(Mandatory)] [string]$Dest)
	if ($TargetOs -eq 'windows') {
		$parent = $Dest.TrimEnd('/') -replace '/[^/]+$', ''
		& ssh $Remote ('powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path ''{0}'' | Out-Null"' -f $parent)
	} else {
		$parent = $Dest.TrimEnd('/').TrimStart('/') -replace '/[^/]+$', ''
		if (-not $parent) { $parent = '.' }
		& ssh $Remote ('mkdir -p "{0}"' -f $parent)
	}
}

# --- transfer --------------------------------------------------------------------

$flags = $Apply ? @('-a') : @('-a', '-n')
$label = $Apply ? 'APPLY' : 'DRY-RUN (pass -Apply to transfer)'
$excludes = @('.DS_Store', '*.log', 'node_modules/', 'cache/', 'Cache/', 'Cache_Data/', 'logs/', 'tmp/') |
	ForEach-Object { "--exclude=$_" }

Write-Host "$label — $(hostname) -> $Remote (target $TargetOs)`n"
foreach ($id in $Selected) {
	# one table entry per platform: the plain path for linux/macos, the matching
	# override for windows
	$path = if ($TargetOs -eq 'windows' -and $HarnessPaths[$id].Count -gt 1) { $HarnessPaths[$id][1] } else { $HarnessPaths[$id][0] }
	$src = Get-SourcePath $path
	if (-not $src -or -not (Test-Path $src)) {
		Write-Host ('[skip]   {0,-10} {1} (absent on this host)' -f $id, $path)
		continue
	}
	Write-Host ('[sync]   {0,-10} {1}' -f $id, $path)
	$dest = Get-DestPath $path
	# the destination parent must exist; rsync -a with a trailing slash copies
	# contents into the destination directory, and never deletes. the mkdir is
	# a write, so it runs only under -Apply.
	if ($Apply) { Invoke-RemoteMkdir $dest }
	& rsync @flags @excludes --info=stats1 -e ssh ($src.Replace('\', '/').TrimEnd('/') + '/') ($Remote + ':' + $dest)
}

Write-Host "`ndone. re-login per harness whose auth lived in a keychain or credential manager, then run: pwsh ./scripts/install-harnesses.ps1 -Check on the target"
exit 0
