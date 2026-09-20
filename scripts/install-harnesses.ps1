#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
agent-detect — install the test-matrix harnesses (macOS, Linux, Windows).

.DESCRIPTION
Interactive on a user machine: pick the harnesses from a multiselect, then pick an install method for each (the methods show in preference order, and nothing runs before you confirm).
Non-interactive on CI: pass -Yes (or run under CI=true) and every harness installs through its first available method — the flow the daemon runner uses.

Method preference (policy — see CONTRIBUTING.md "per-harness install"):

- Windows: scoop before winget before the app store; npm before custom installers
- macOS: homebrew before npm for the harnesses with a native tap; custom installers last
- Linux: npm before anything; soar appimages before flatpak (both wait for verified package ids); custom installers last

The per-harness registry (probe binary, per-OS methods, package names, custom installers) lives in this one script — add a harness here when its rule lands.

.EXAMPLE
pwsh -File ./scripts/install-harnesses.ps1

.EXAMPLE
pwsh -File ./scripts/install-harnesses.ps1 -Yes

.EXAMPLE
pwsh -File ./scripts/install-harnesses.ps1 -Check
#>
[CmdletBinding()]
param(
	[switch]$Yes,
	[switch]$Check,
	[switch]$List,
	[string[]]$Harness,
	[switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ($Help) {
	@'
usage: pwsh -File ./scripts/install-harnesses.ps1 [-Yes] [-Check] [-List] [-Harness <id>[,<id>]]

  (no flags)  interactive: pick harnesses and install methods from the menus
  -Yes        non-interactive: install every harness through its first available method
  -Check      probe every harness binary and print the state; install nothing
  -List       print the registry (id, probe, methods for this platform) and exit
  -Harness    restrict to the named harness ids (comma separated)

CI=true or GITHUB_ACTIONS=true in the environment implies -Yes.
'@ | Write-Host
	exit 0
}
if ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true') { $Yes = $true }

# --- platform ----------------------------------------------------------------

$Platform = if ($IsMacOS) { 'Darwin' } elseif ($IsLinux) { 'Linux' } elseif ($IsWindows) { 'Windows' } else { $null }
if (-not $Platform) { throw 'unsupported platform: install-harnesses.ps1 runs on macOS, Linux, and Windows' }

# --- registry ----------------------------------------------------------------
# Probe: the binary agent-detect's invocations table probes with --version.
# Methods: the ordered install methods per platform (the policy above sets the order).

$Registry = @(
	[pscustomobject]@{ Id = 'cline'; Label = 'Cline CLI'; Probe = 'cline'; Methods = @{ Darwin = @('npm'); Linux = @('npm'); Windows = @('npm') } }
	[pscustomobject]@{ Id = 'kimi-code'; Label = 'Kimi Code'; Probe = 'kimi'; Methods = @{ Darwin = @('npm'); Linux = @('npm'); Windows = @('npm') } }
	[pscustomobject]@{ Id = 'mmx'; Label = 'MMX (MiniMax M3 CLI)'; Probe = 'mmx'; Methods = @{ Darwin = @('npm'); Linux = @('npm'); Windows = @('npm') } }
	[pscustomobject]@{ Id = 'pi'; Label = 'pi (π coding agent)'; Probe = 'pi'; Methods = @{ Darwin = @('npm'); Linux = @('npm'); Windows = @('scoop', 'npm') } }
	[pscustomobject]@{ Id = 'qwen'; Label = 'Qwen Code'; Probe = 'qwen'; Methods = @{ Darwin = @('brew', 'npm'); Linux = @('npm', 'brew'); Windows = @('npm') } }
	[pscustomobject]@{ Id = 'kilo'; Label = 'Kilo Code'; Probe = 'kilo'; Methods = @{ Darwin = @('brew', 'npm'); Linux = @('npm', 'brew'); Windows = @('npm') } }
	[pscustomobject]@{ Id = 'omp'; Label = 'oh-my-pi (omp)'; Probe = 'omp'; Methods = @{ Darwin = @('brew', 'npm'); Linux = @('npm', 'brew'); Windows = @('scoop', 'npm') } }
	[pscustomobject]@{ Id = 'reasonix'; Label = 'Reasonix'; Probe = 'reasonix'; Methods = @{ Darwin = @('brew', 'npm'); Linux = @('npm', 'brew'); Windows = @('scoop', 'npm') } }
	[pscustomobject]@{ Id = 'crush'; Label = 'Crush'; Probe = 'crush'; Methods = @{ Darwin = @('brew', 'npm'); Linux = @('npm', 'brew'); Windows = @('winget', 'npm') } }
	[pscustomobject]@{ Id = 'opencode'; Label = 'OpenCode'; Probe = 'opencode'; Methods = @{ Darwin = @('brew', 'npm'); Linux = @('npm', 'brew'); Windows = @('scoop', 'npm') } }
	[pscustomobject]@{ Id = 'vibe'; Label = 'Mistral Vibe'; Probe = 'vibe'; Methods = @{ Darwin = @('uv'); Linux = @('uv'); Windows = @('uv') } }
	[pscustomobject]@{ Id = 'cursor'; Label = 'Cursor CLI (cursor-agent)'; Probe = 'cursor-agent'; Methods = @{ Darwin = @('brew', 'custom'); Linux = @('custom'); Windows = @('custom') } }
	[pscustomobject]@{ Id = 'copilot'; Label = 'GitHub Copilot CLI'; Probe = 'copilot'; Methods = @{ Darwin = @('brew'); Linux = @(); Windows = @('scoop') } }
	[pscustomobject]@{ Id = 'hermes'; Label = 'Hermes (contributor scope)'; Probe = 'hermes'; Methods = @{ Darwin = @('custom'); Linux = @('custom'); Windows = @('custom') } }
	[pscustomobject]@{ Id = 'goose'; Label = 'Goose (contributor scope)'; Probe = 'goose'; Methods = @{ Darwin = @(); Linux = @(); Windows = @('scoop') } }
	[pscustomobject]@{ Id = 'autoclaw'; Label = 'AutoClaw (desktop app)'; Probe = 'autoclaw'; Methods = @{ Darwin = @('manual'); Linux = @('manual'); Windows = @('manual') } }
)

$NpmPackage = @{
	cline = 'cline'
	'kimi-code' = '@moonshot-ai/kimi-code'
	mmx = 'mmx-cli'
	pi = '@earendil-works/pi-coding-agent'
	qwen = '@qwen-code/qwen-code'
	kilo = '@kilocode/cli'
	omp = '@oh-my-pi/pi-coding-agent'
	reasonix = 'reasonix'
	crush = '@charmland/crush'
	opencode = 'opencode-ai'
}
$BrewPackage = @{
	qwen = 'qwen-code'
	kilo = 'Kilo-Org/tap/kilo'
	omp = 'can1357/tap/omp'
	reasonix = 'esengine/reasonix/reasonix'
	crush = 'charmbracelet/tap/crush'
	opencode = 'anomalyco/tap/opencode'
	cursor = 'cursor-cli'
	copilot = 'copilot-cli'
}
$ScoopPackage = @{
	pi = 'pi-coding-agent'
	omp = 'oh-my-pi'
	reasonix = 'reasonix'
	opencode = 'opencode'
	copilot = 'copilot-cli'
	goose = 'goose-cli'
}
$WingetPackage = @{ crush = 'charmbracelet.crush' }
$UvPackage = @{ vibe = 'mistral-vibe' }
# soar and flatpak ids stay empty until verified against the package indexes;
# the methods are wired so a verified id only needs one entry here.
$SoarPackage = @{}
$FlatpakPackage = @{}

# --- helpers ------------------------------------------------------------------

function Write-Info { param([string]$Message) Write-Host "$($PSStyle.Foreground.BrightBlue)info $Message$($PSStyle.Reset)" }
function Write-Fail { param([string]$Message) Write-Host "$($PSStyle.Foreground.Red)fail $Message$($PSStyle.Reset)" }

function Test-HarnessInstalled {
	param([Parameter(Mandatory)] [pscustomobject]$Entry)
	return [bool](Get-Command $Entry.Probe -ErrorAction Ignore)
}

function Get-HarnessVersion {
	param([Parameter(Mandatory)] [string]$Probe)
	try { return (@(& $Probe --version 2>&1) | Select-Object -First 1) } catch { return 'unknown' }
}

function Test-MethodAvailable {
	param([Parameter(Mandatory)] [string]$Id, [Parameter(Mandatory)] [string]$Method)
	switch ($Method) {
		npm { return [bool](Get-Command npm -ErrorAction Ignore) }
		brew { return [bool](Get-Command brew -ErrorAction Ignore) }
		scoop { return [bool](Get-Command scoop -ErrorAction Ignore) }
		winget { return [bool](Get-Command winget -ErrorAction Ignore) }
		uv { return [bool](Get-Command uv -ErrorAction Ignore) }
		soar { return ([bool](Get-Command soar -ErrorAction Ignore)) -and $SoarPackage.ContainsKey($Id) }
		flatpak { return ([bool](Get-Command flatpak -ErrorAction Ignore)) -and $FlatpakPackage.ContainsKey($Id) }
		default { return $true }   # custom, manual
	}
}

function Get-MethodCommand {
	param([Parameter(Mandatory)] [string]$Id, [Parameter(Mandatory)] [string]$Method)
	switch ($Method) {
		npm { return "npm i -g $($NpmPackage[$Id])" }
		brew { return "brew install $($BrewPackage[$Id])" }
		scoop { return "scoop install $($ScoopPackage[$Id])" }
		winget { return "winget install $($WingetPackage[$Id])" }
		uv { return "uv tool install $($UvPackage[$Id])" }
		soar { return "soar install $($SoarPackage[$Id])" }
		flatpak { return "flatpak install -y $($FlatpakPackage[$Id])" }
		custom {
			switch ("$Platform/$Id") {
				'Darwin/cursor' { return 'brew install cursor-cli  (fallback: curl -fsSL https://cursor.com/install | bash)' }
				'Linux/cursor' { return 'curl -fsSL https://cursor.com/install | bash' }
				'Windows/cursor' { return "Invoke-RestMethod 'https://cursor.com/install?win32=true' | Invoke-Expression" }
				'Darwin/hermes' { return 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash' }
				'Linux/hermes' { return 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash' }
				'Windows/hermes' { return 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash  (needs a POSIX shell: Git Bash or WSL)' }
			}
		}
		manual {
			switch ($Id) {
				autoclaw { return 'download the desktop installer from https://autoclaw.z.ai' }
			}
		}
	}
}

function Invoke-Method {
	# Returns $true (installed), 'manual' (needs a human step — printed), or $false (failed).
	param(
		[Parameter(Mandatory)] [string]$Id,
		[Parameter(Mandatory)] [string]$Method
	)
	switch ($Method) {
		npm { npm i -g $NpmPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		brew { brew install $BrewPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		scoop { scoop install $ScoopPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		winget { winget install $WingetPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		uv { uv tool install $UvPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		soar { soar install $SoarPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		flatpak { flatpak install -y $FlatpakPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		custom {
			switch ("$Platform/$Id") {
				'Darwin/cursor' { & bash -c 'curl -fsSL https://cursor.com/install | bash'; return ($LASTEXITCODE -eq 0) }
				'Linux/cursor' { & bash -c 'curl -fsSL https://cursor.com/install | bash'; return ($LASTEXITCODE -eq 0) }
				'Windows/cursor' {
					# The scriptblock form runs the harness's documented "irm | iex"
					# installer (shown to the user by Get-MethodCommand) without the
					# Invoke-Expression linter finding.
					& ([scriptblock]::Create([string](Invoke-RestMethod 'https://cursor.com/install?win32=true')))
					return ($LASTEXITCODE -eq 0)
				}
				'Darwin/hermes' { & bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'; return ($LASTEXITCODE -eq 0) }
				'Linux/hermes' { & bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'; return ($LASTEXITCODE -eq 0) }
				'Windows/hermes' { Write-Info "manual step: $(Get-MethodCommand $Id $Method)"; return 'manual' }
			}
		}
		manual { Write-Info "manual step: $(Get-MethodCommand $Id $Method)"; return 'manual' }
	}
	return $false
}

function Install-Entry {
	param([Parameter(Mandatory)] [pscustomobject]$Entry, [Parameter(Mandatory)] [string]$Method)
	Write-Host ('[install]   {0} via {1}: {2}' -f $Entry.Id, $Method, (Get-MethodCommand $Entry.Id $Method))
	$result = Invoke-Method $Entry.Id $Method
	if ($result -eq 'manual') {
		Write-Info "[manual]    $($Entry.Id) — needs a manual step (printed above); not counted as a failure"
	} elseif (-not $result) {
		Write-Fail "[fail]      $($Entry.Id) — the install command exited nonzero"
		$script:failures++
	}
}

function Get-AvailableMethod {
	param([Parameter(Mandatory)] [pscustomobject]$Entry)
	# the comma stops PowerShell unrolling a single-element array into a scalar -
	# every caller reads .Count under StrictMode, where a scalar has no Count
	return , @($Entry.Methods[$Platform] | Where-Object { Test-MethodAvailable $Entry.Id $_ })
}

# --- selection ------------------------------------------------------------------

$Selected = if ($Harness) {
	$unknown = @($Harness | Where-Object { -not ($Registry.Id -contains $_) })
	if ($unknown.Count -gt 0) { throw "unknown harness id(s): $($unknown -join ', ') (see -List)" }
	@($Registry | Where-Object { $Harness -contains $_.Id })
} else {
	$Registry
}

# --- -List -----------------------------------------------------------------------

if ($List) {
	foreach ($entry in $Registry) {
		'{0,-12} {1,-14} {2}' -f $entry.Id, $entry.Probe, ($entry.Methods[$Platform] -join ',')
	}
	exit 0
}

# --- -Check ----------------------------------------------------------------------

if ($Check) {
	$installed = 0
	$missing = 0
	foreach ($entry in $Selected) {
		if (Test-HarnessInstalled $entry) {
			$installed++
			Write-Host ('[ok]       {0,-10} {1} ({2})' -f $entry.Id, $entry.Label, (Get-HarnessVersion $entry.Probe))
		} else {
			$missing++
			Write-Host ('[missing]  {0,-10} {1}' -f $entry.Id, $entry.Label)
		}
	}
	Write-Host "$installed installed, $missing missing"
	exit 0
}

# --- the shared menu, with a plain-prompt fallback --------------------------------
# The installer must also run where the shared menu cannot be resolved, so the
# fallback keeps a numbered Read-Host flow alive.

$menuLoaded = $false
if (-not $Yes) {
	$menuPath = $null
	foreach ($candidate in @(
		$env:BEVRY_SKILLS_MENU,
		(Join-Path $PSScriptRoot '../../skills/scripts/menu.ps1'),
		(Join-Path $PSScriptRoot '../skills/scripts/menu.ps1')
	)) {
		if ($candidate -and (Test-Path $candidate)) { $menuPath = $candidate; break }
	}
	if (-not $menuPath) {
		$menuCacheDir = if ($IsWindows) { Join-Path $env:LOCALAPPDATA 'bevry-vibes/skills/scripts' } else { Join-Path $HOME '.cache/bevry-vibes/skills/scripts' }
		$menuCache = Join-Path $menuCacheDir 'menu.ps1'
		if (-not (Test-Path $menuCache)) {
			try {
				New-Item -ItemType Directory -Force -Path $menuCacheDir | Out-Null
				Invoke-WebRequest 'https://raw.githubusercontent.com/bevry-vibes/skills/main/scripts/menu.ps1' -OutFile $menuCache
			} catch {
				Write-Info "the shared menu is unavailable ($($_.Exception.Message)); the numbered-prompt fallback is used instead."
			}
		}
		if (Test-Path $menuCache) { $menuPath = $menuCache }
	}
	if ($menuPath) {
		. $menuPath
		if (Get-Command Read-MultiChoice -ErrorAction Ignore) { $menuLoaded = $true }
	}
	if (-not $menuLoaded -and [Console]::IsInputRedirected) { throw 'stdin is not interactive — pass -Yes for the non-interactive flow.' }
}

# --- install ------------------------------------------------------------------------

$failures = 0

if ($Yes) {
	foreach ($entry in $Selected) {
		if (Test-HarnessInstalled $entry) {
			Write-Host ('[installed] {0} — {1}' -f $entry.Id, (Get-HarnessVersion $entry.Probe))
			continue
		}
		$methods = Get-AvailableMethod $entry
		if ($methods.Count -eq 0) {
			$planned = @($entry.Methods[$Platform])
			if ($planned.Count -eq 0) {
				Write-Info ("[skip]      {0} — no install method on {1}" -f $entry.Id, $Platform)
			} else {
				Write-Info ("[skip]      {0} — method tools missing on this host: {1}" -f $entry.Id, ($planned -join ' '))
			}
			continue
		}
		Install-Entry $entry $methods[0]
	}
} elseif ($menuLoaded) {
	$menuOptions = for ($i = 0; $i -lt $Selected.Count; $i++) {
		$entry = $Selected[$i]
		$installed = Test-HarnessInstalled $entry
		$methods = Get-AvailableMethod $entry
		$label = if ($installed) {
			"$($PSStyle.Dim)$($entry.Label) — installed$($PSStyle.Reset)"
		} elseif ($methods.Count -eq 0) {
			"$($PSStyle.Dim)$($entry.Label) — no available method$($PSStyle.Reset)"
		} else {
			"$($PSStyle.Foreground.Green)$($entry.Label)$($PSStyle.Reset)"
		}
		[pscustomobject]@{
			Index  = $i
			Label  = $label
			Detail = @($methods | ForEach-Object { Get-MethodCommand $entry.Id $_ })
			Locked = ($installed -or $methods.Count -eq 0)
		}
	}
	$chosen = Read-MultiChoice -Options $menuOptions -Title 'Select harnesses to install'
	if ($null -eq $chosen) {
		Write-Info 'cancelled.'
	} else {
		foreach ($picked in $chosen) {
			$entry = $Selected[$picked.Index]
			$methods = Get-AvailableMethod $entry
			$rows = @($methods | ForEach-Object { "$_ — $(Get-MethodCommand $entry.Id $_)" }) + @('skip this harness')
			$index = Read-MenuChoice -Rows $rows -Initial 0
			if ($index -lt 0 -or $index -ge $methods.Count) { continue }
			Install-Entry $entry $methods[$index]
		}
	}
} else {
	# numbered-prompt fallback (the shared menu did not resolve)
	foreach ($entry in $Selected) {
		if (Test-HarnessInstalled $entry) {
			Write-Host ('[installed] {0} — {1}' -f $entry.Id, (Get-HarnessVersion $entry.Probe))
			continue
		}
		$methods = Get-AvailableMethod $entry
		if ($methods.Count -eq 0) {
			$planned = @($entry.Methods[$Platform])
			if ($planned.Count -eq 0) {
				Write-Info ("[skip]      {0} — no install method on {1}" -f $entry.Id, $Platform)
			} else {
				Write-Info ("[skip]      {0} — method tools missing on this host: {1}" -f $entry.Id, ($planned -join ' '))
			}
			continue
		}
		Write-Host ''
		Write-Host "$($entry.Id) — $($entry.Label)"
		for ($m = 0; $m -lt $methods.Count; $m++) {
			Write-Host ('  {0}) {1}' -f ($m + 1), (Get-MethodCommand $entry.Id $methods[$m]))
		}
		Write-Host '  s) skip this harness'
		$answer = (Read-Host '?').Trim()
		if ($answer -eq 's' -or $answer -eq 'S' -or $answer -eq '') { continue }
		$pick = 0
		if (-not [int]::TryParse($answer, [ref]$pick) -or $pick -lt 1 -or $pick -gt $methods.Count) {
			Write-Info 'not a choice — skipped'
			continue
		}
		Install-Entry $entry $methods[$pick - 1]
	}
}

if ($failures -gt 0) {
	Write-Fail "$failures install command(s) failed"
	exit 1
}
exit 0
