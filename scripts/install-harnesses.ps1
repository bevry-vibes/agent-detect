#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
agent-detect — install the test-matrix harnesses (macOS, Linux, Windows).

.DESCRIPTION
Interactive on a user machine: pick harnesses and actions from the multiselect. Each row's radios sit beneath its title and description — a missing harness offers `○ install`; an installed harness offers `○ upgrade    ○ uninstall`. The radios are a hybrid: at most one set per row, none required — space sets the focused action (clearing its sibling), space again unsets, left/right or h/l move between a row's actions. After Enter, each chosen action walks a method menu before anything runs.
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

  (no flags)  interactive: pick harnesses and actions from the radios, then a method per action
  -Yes        non-interactive: install every harness through its first available method
  -Check      probe every harness binary and print the state; install nothing
  -List       print the registry (id, probe, methods for this platform) and exit
  -Harness    restrict to the named harness ids (comma separated)

CI=true or GITHUB_ACTIONS=true in the environment implies -Yes.
'@ | Write-Host
	exit 0
}
if ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true') { $Yes = $true }
# -File passes "a,b" as one argument (pwsh -Command is what splits commas), so split it here
if ($Harness) { $Harness = @($Harness | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# --- platform ----------------------------------------------------------------

$Platform = if ($IsMacOS) { 'Darwin' } elseif ($IsLinux) { 'Linux' } elseif ($IsWindows) { 'Windows' } else { $null }
if (-not $Platform) { throw 'unsupported platform: install-harnesses.ps1 runs on macOS, Linux, and Windows' }

# npm may sit behind the user's node-env wrapper (a dorothy command that exposes
# a node.js environment): when plain npm is not on PATH, every npm invocation
# runs as "node-env -- npm ...". The array form splats into the & call operator.
$NpmCommand = if (Get-Command npm -ErrorAction Ignore) {
	@('npm')
} elseif (Get-Command node-env -ErrorAction Ignore) {
	@('node-env', '--', 'npm')
} else {
	$null
}

# Installers may place binaries in XDG_BIN_HOME (default ~/.local/bin) or the
# npm global prefix bin (behind node-env when plain npm is off PATH), which is
# fine — but those directories are not always on PATH in the current session, so
# the probe resolves all three and reports where the binary is.
$XdgBinHome = if ($env:XDG_BIN_HOME) { $env:XDG_BIN_HOME } else { Join-Path $HOME '.local/bin' }
$NpmGlobalBin = $null
if ($NpmCommand) {
	try {
		# the prefix query runs through the same routing as installs (node-env -- npm ...)
		$npmPrefix = [string](& $NpmCommand prefix -g | Select-Object -First 1)
		if ($npmPrefix) {
			$npmPrefix = $npmPrefix.Trim()
			$NpmGlobalBin = $IsWindows ? $npmPrefix : (Join-Path $npmPrefix 'bin')
		}
	} catch { $NpmGlobalBin = $null }
}

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
	[pscustomobject]@{ Id = 'opencode2'; Label = 'OpenCode v2 (opencode2)'; Probe = 'opencode2'; Methods = @{ Darwin = @('npm', 'custom'); Linux = @('npm', 'custom'); Windows = @('npm', 'custom') } }
	[pscustomobject]@{ Id = 'dsh'; Label = 'DeepSeek Harness — dsh (developer preview)'; Probe = 'dsh'; Methods = @{ Darwin = @('npm'); Linux = @('npm'); Windows = @('npm') } }
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
	opencode2 = '@opencode-ai/cli'
	dsh = '@deepseek-ai/dsh'
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

function Resolve-HarnessBinary {
	# PATH first, then XDG_BIN_HOME, then the npm global prefix bin.
	# Returns the binary's path (the command name when on PATH), or $null.
	param([Parameter(Mandatory)] [string]$Probe)
	$onPath = Get-Command $Probe -ErrorAction Ignore
	if ($onPath) { return $onPath.Source }
	$names = if ($IsWindows) { @($Probe, "$Probe.exe", "$Probe.cmd") } else { @($Probe) }
	foreach ($dir in @($XdgBinHome, $NpmGlobalBin)) {
		if (-not $dir) { continue }
		foreach ($name in $names) {
			$candidate = Join-Path $dir $name
			if (Test-Path $candidate) { return $candidate }
		}
	}
	return $null
}

function Test-HarnessInstalled {
	param([Parameter(Mandatory)] [pscustomobject]$Entry)
	return ($null -ne (Resolve-HarnessBinary $Entry.Probe))
}

function Get-HarnessVersion {
	param([Parameter(Mandatory)] [string]$Probe)
	$bin = Resolve-HarnessBinary $Probe
	if (-not $bin) { return 'unknown' }
	try { return (@(& $bin --version 2>&1) | Select-Object -First 1) } catch { return 'unknown' }
}

function Test-MethodAvailable {
	param([Parameter(Mandatory)] [string]$Id, [Parameter(Mandatory)] [string]$Method)
	switch ($Method) {
		npm { return ($null -ne $NpmCommand) }
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
	param(
		[Parameter(Mandatory)] [string]$Id,
		[Parameter(Mandatory)] [string]$Method,
		[ValidateSet('install', 'upgrade', 'uninstall')] [string]$Action = 'install'
	)
	switch ("$Method/$Action") {
		'npm/install' { return "$($NpmCommand -join ' ') i -g $($NpmPackage[$Id])" }
		'npm/upgrade' { return "$($NpmCommand -join ' ') i -g $($NpmPackage[$Id])@latest" }
		'npm/uninstall' { return "$($NpmCommand -join ' ') rm -g $($NpmPackage[$Id])" }
		'brew/install' { return "brew install $($BrewPackage[$Id])" }
		'brew/upgrade' { return "brew upgrade $($BrewPackage[$Id])" }
		'brew/uninstall' { return "brew uninstall $($BrewPackage[$Id])" }
		'scoop/install' { return "scoop install $($ScoopPackage[$Id])" }
		'scoop/upgrade' { return "scoop update $($ScoopPackage[$Id])" }
		'scoop/uninstall' { return "scoop uninstall $($ScoopPackage[$Id])" }
		'winget/install' { return "winget install $($WingetPackage[$Id])" }
		'winget/upgrade' { return "winget upgrade --id $($WingetPackage[$Id])" }
		'winget/uninstall' { return "winget uninstall --id $($WingetPackage[$Id])" }
		'uv/install' { return "uv tool install $($UvPackage[$Id])" }
		'uv/upgrade' { return "uv tool upgrade $($UvPackage[$Id])" }
		'uv/uninstall' { return "uv tool uninstall $($UvPackage[$Id])" }
		'soar/install' { return "soar install $($SoarPackage[$Id])" }
		'soar/upgrade' { return 'soar update' }
		'soar/uninstall' { return "soar remove $($SoarPackage[$Id])" }
		'flatpak/install' { return "flatpak install -y $($FlatpakPackage[$Id])" }
		'flatpak/upgrade' { return "flatpak update -y $($FlatpakPackage[$Id])" }
		'flatpak/uninstall' { return "flatpak uninstall -y $($FlatpakPackage[$Id])" }
		default {
			# custom and manual: rerunning the installer is the upgrade; uninstall is manual
			if ($Method -eq 'custom' -and $Action -eq 'uninstall') {
				return 'manual — remove the harness with its own uninstaller'
			}
			switch ("$Platform/$Id") {
				'Darwin/cursor' { return 'brew install cursor-cli  (fallback: curl -fsSL https://cursor.com/install | bash)' }
				'Linux/cursor' { return 'curl -fsSL https://cursor.com/install | bash' }
				'Windows/cursor' { return "Invoke-RestMethod 'https://cursor.com/install?win32=true' | Invoke-Expression" }
				'Darwin/hermes' { return 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash' }
				'Linux/hermes' { return 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash' }
				'Windows/hermes' { return 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash  (needs a POSIX shell: Git Bash or WSL)' }
				'Darwin/opencode2' { return 'curl -fsSL https://opencode.ai/v2/install | bash' }
				'Linux/opencode2' { return 'curl -fsSL https://opencode.ai/v2/install | bash' }
				'Windows/opencode2' { return 'curl -fsSL https://opencode.ai/v2/install | bash  (needs a POSIX shell: Git Bash or WSL)' }
				default {
					switch ($Id) {
						autoclaw { return 'download the desktop installer from https://autoclaw.z.ai' }
					}
				}
			}
		}
	}
}

function Invoke-Method {
	# Returns $true (done), 'manual' (needs a human step — printed), or $false (failed).
	param(
		[Parameter(Mandatory)] [string]$Id,
		[Parameter(Mandatory)] [string]$Method,
		[ValidateSet('install', 'upgrade', 'uninstall')] [string]$Action = 'install'
	)
	switch ("$Method/$Action") {
		'npm/install' { & $NpmCommand i -g $NpmPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'npm/upgrade' { & $NpmCommand i -g "$($NpmPackage[$Id])@latest"; return ($LASTEXITCODE -eq 0) }
		'npm/uninstall' { & $NpmCommand rm -g $NpmPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'brew/install' { brew install $BrewPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'brew/upgrade' { brew upgrade $BrewPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'brew/uninstall' { brew uninstall $BrewPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'scoop/install' { scoop install $ScoopPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'scoop/upgrade' { scoop update $ScoopPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'scoop/uninstall' { scoop uninstall $ScoopPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'winget/install' { winget install $WingetPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'winget/upgrade' { winget upgrade --id $WingetPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'winget/uninstall' { winget uninstall --id $WingetPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'uv/install' { uv tool install $UvPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'uv/upgrade' { uv tool upgrade $UvPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'uv/uninstall' { uv tool uninstall $UvPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'soar/install' { soar install $SoarPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'soar/upgrade' { soar update; return ($LASTEXITCODE -eq 0) }
		'soar/uninstall' { soar remove $SoarPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'flatpak/install' { flatpak install -y $FlatpakPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'flatpak/upgrade' { flatpak update -y $FlatpakPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		'flatpak/uninstall' { flatpak uninstall -y $FlatpakPackage[$Id]; return ($LASTEXITCODE -eq 0) }
		default {
			if ($Action -eq 'uninstall') {
				# custom/manual harnesses have no scriptable uninstall
				Write-Info "manual step: $(Get-MethodCommand -Id $Id -Method $Method -Action $Action)"
				return 'manual'
			}
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
				'Windows/hermes' { Write-Info "manual step: $(Get-MethodCommand -Id $Id -Method $Method -Action $Action)"; return 'manual' }
				'Darwin/opencode2' { & bash -c 'curl -fsSL https://opencode.ai/v2/install | bash'; return ($LASTEXITCODE -eq 0) }
				'Linux/opencode2' { & bash -c 'curl -fsSL https://opencode.ai/v2/install | bash'; return ($LASTEXITCODE -eq 0) }
				'Windows/opencode2' { Write-Info "manual step: $(Get-MethodCommand -Id $Id -Method $Method -Action $Action)"; return 'manual' }
				default {
					switch ($Id) {
						autoclaw { Write-Info "manual step: $(Get-MethodCommand -Id $Id -Method $Method -Action $Action)"; return 'manual' }
					}
				}
			}
		}
	}
	return $false
}

function Invoke-Entry {
	param(
		[Parameter(Mandatory)] [pscustomobject]$Entry,
		[Parameter(Mandatory)] [string]$Method,
		[ValidateSet('install', 'upgrade', 'uninstall')] [string]$Action = 'install'
	)
	Write-Host ('[{0}]   {1} via {2}: {3}' -f $Action, $Entry.Id, $Method, (Get-MethodCommand -Id $Entry.Id -Method $Method -Action $Action))
	$result = Invoke-Method -Id $Entry.Id -Method $Method -Action $Action
	# "$result" forces string comparison: a $true result -eq 'manual' would coerce
	# the string to bool and mislabel every successful run as a manual step
	if ("$result" -eq 'manual') {
		Write-Info "[manual]    $($Entry.Id) — needs a manual step (printed above); not counted as a failure"
	} elseif (-not $result) {
		Write-Fail "[fail]      $($Entry.Id) — the ${Action} command exited nonzero"
		$script:failures++
	} elseif ($Action -eq 'uninstall') {
		Write-Info "[ok]        $($Entry.Id) — uninstalled"
	} elseif (Get-Command $Entry.Probe -ErrorAction Ignore) {
		Write-Info "[ok]        $($Entry.Id) — $(Get-HarnessVersion $Entry.Probe)"
	} else {
		$resolved = Resolve-HarnessBinary $Entry.Probe
		Write-Info "[ok]        $($Entry.Id) — installed at $resolved, which is not on PATH yet (add it to PATH, or run it through node-env)"
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
			if (Get-Command $entry.Probe -ErrorAction Ignore) {
				Write-Host ('[ok]       {0,-10} {1} ({2})' -f $entry.Id, $entry.Label, (Get-HarnessVersion $entry.Probe))
			} else {
				$resolved = Resolve-HarnessBinary $entry.Probe
				Write-Host ('[ok]       {0,-10} {1} (at {2} — add it to PATH, or run it through node-env)' -f $entry.Id, $entry.Label, $resolved)
			}
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
		Invoke-Entry -Entry $entry -Method $methods[0] -Action install
	}
} elseif ($menuLoaded) {
	$menuOptions = for ($i = 0; $i -lt $Selected.Count; $i++) {
		$entry = $Selected[$i]
		$installed = Test-HarnessInstalled $entry
		$methods = Get-AvailableMethod $entry
		if ($installed -and $methods.Count -gt 0) {
			# installed rows stay active: the radios select upgrade or uninstall
			$label = "$($PSStyle.Foreground.Cyan)$($entry.Label)$($PSStyle.Reset)$($PSStyle.Dim) — installed$($PSStyle.Reset)"
			$actions = @('upgrade', 'uninstall')
			$detail = @("upgrade via $($methods[0]): $(Get-MethodCommand -Id $entry.Id -Method $methods[0] -Action upgrade)")
			$locked = $false
		} elseif ($installed) {
			$label = "$($PSStyle.Dim)$($entry.Label) — installed (no available method)$($PSStyle.Reset)"
			$actions = @()
			$detail = @()
			$locked = $true
		} elseif ($methods.Count -gt 0) {
			$label = "$($PSStyle.Foreground.Green)$($entry.Label)$($PSStyle.Reset)"
			$actions = @('install')
			$detail = @($methods | ForEach-Object { Get-MethodCommand -Id $entry.Id -Method $_ -Action install })
			$locked = $false
		} else {
			$label = "$($PSStyle.Dim)$($entry.Label) — no available method$($PSStyle.Reset)"
			$actions = @()
			$detail = @()
			$locked = $true
		}
		[pscustomobject]@{
			Index   = $i
			Label   = $label
			Detail  = $detail
			Locked  = $locked
			Actions = $actions
		}
	}
	$installSummary = {
		# Runs inside the shared menu (dynamic scoping): read only fields the
		# selection items carry.
		param($Chosen)
		$parts = @($Chosen | Where-Object { $_.PSObject.Properties['Action'] } | ForEach-Object { $_.Action })
		"$($Chosen.Count) selected$(if ($parts.Count -gt 0) { ': ' + ($parts -join ', ') } else { '' })"
	}
	$chosen = Read-MultiChoice -Options $menuOptions -Title 'Select harnesses and actions' -FooterSummary $installSummary
	if ($null -eq $chosen) {
		Write-Info 'cancelled.'
	} else {
		foreach ($picked in $chosen) {
			# every installer row carries Actions, so every pick is a wrapper
			if (-not ($picked.PSObject.Properties['Action'])) { continue }
			$entry = $Selected[$picked.Index]
			$action = $picked.Action
			$methods = Get-AvailableMethod $entry
			$rows = @($methods | ForEach-Object { "$_ — $(Get-MethodCommand -Id $entry.Id -Method $_ -Action $action)" }) + @("skip this $action")
			$index = Read-MenuChoice -Rows $rows -Initial 0
			if ($index -lt 0 -or $index -ge $methods.Count) { continue }
			Invoke-Entry -Entry $entry -Method $methods[$index] -Action $action
		}
	}
} else {
	# numbered-prompt fallback (the shared menu did not resolve; install only —
	# the menu flow adds upgrade and uninstall)
	foreach ($entry in $Selected) {
		if (Test-HarnessInstalled $entry) {
			Write-Host ('[installed] {0} — {1} (the menu flow offers upgrade and uninstall)' -f $entry.Id, (Get-HarnessVersion $entry.Probe))
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
		Invoke-Entry -Entry $entry -Method $methods[$pick - 1] -Action install
	}
}

if ($failures -gt 0) {
	Write-Fail "$failures install command(s) failed"
	exit 1
}
exit 0
