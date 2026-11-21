#!/usr/bin/env pwsh
# scripts/zig.ps1 — run the repo's pinned Zig toolchain.
#
# The version comes from `minimum_zig_version` in build.zig.zon (the same field
# CI's setup-zig reads). On first use the matching compiler is downloaded into
# the gitignored vendor/zig/<version>/<platform>/ directory and every later run
# reuses it, so local builds and CI always run the same Zig.
#
# Usage:
#   ./scripts/zig build
#   ./scripts/zig build test
#   ./scripts/zig --check            # print the resolved version and path
#   ./scripts/zig --toolchain-path   # print only the vendored binary path
#   ./scripts/zig --refresh build    # reinstall before running
#
# Unix runs scripts/zig; Windows runs `pwsh scripts/zig.ps1` or scripts\zig.cmd.

param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = Split-Path -Parent $PSScriptRoot
$zon = Get-Content -LiteralPath (Join-Path $repo 'build.zig.zon') -Raw
if ($zon -notmatch 'minimum_zig_version\s*=\s*"([^"]+)"') {
	throw 'build.zig.zon does not declare minimum_zig_version'
}
$version = $Matches[1]

function Get-ZigArch {
	if ($IsWindows) {
		# PROCESSOR_ARCHITEW6432 is set when an x64 process runs on an ARM64 host.
		$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
		switch ($arch.ToUpperInvariant()) {
			'AMD64' { return 'x86_64' }
			'ARM64' { return 'aarch64' }
			'X86' { return 'x86' }
			'ARM' { return 'arm' }
			default { throw "unsupported Windows architecture: $arch" }
		}
	}
	if ($IsMacOS) {
		# `uname -m` reports x86_64 under Rosetta; the sysctl reports the real CPU.
		$arm = & sysctl -n hw.optional.arm64 2>$null
		if ($LASTEXITCODE -eq 0 -and "$arm".Trim() -eq '1') { return 'aarch64' }
	}
	$machine = (& uname -m).Trim()
	switch -Regex ($machine) {
		'^(x86_64|amd64)$' { return 'x86_64' }
		'^(aarch64|arm64)$' { return 'aarch64' }
		'^(arm|armv[0-9]+l?)$' { return 'arm' }
		'^(i[3-6]86|x86)$' { return 'x86' }
		'^riscv64$' { return 'riscv64' }
		'^(ppc64le|powerpc64le)$' { return 'powerpc64le' }
		'^loongarch64$' { return 'loongarch64' }
		'^s390x$' { return 's390x' }
		default { throw "unsupported architecture: $machine" }
	}
}

$os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } elseif ($IsLinux) { 'linux' } else { throw "unsupported operating system: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)" }
$platformKey = "$(Get-ZigArch)-$os"

$vendorRoot = Join-Path $repo 'vendor/zig'
$installDir = Join-Path $vendorRoot (Join-Path $version $platformKey)
$zigName = if ($IsWindows) { 'zig.exe' } else { 'zig' }
$zigBin = Join-Path $installDir $zigName

function Test-ZigInstall {
	if (-not (Test-Path -LiteralPath $zigBin)) { return $false }
	try {
		$installed = (& $zigBin version 2>$null | Select-Object -First 1)
	} catch {
		return $false
	}
	return ($LASTEXITCODE -eq 0 -and "$installed".Trim() -eq $version)
}

function Install-Zig {
	[Console]::Error.WriteLine("zig $version is not installed; fetching the $platformKey build into vendor/zig/...")
	try {
		$index = Invoke-RestMethod -Uri 'https://ziglang.org/download/index.json'
	} catch {
		throw "could not fetch https://ziglang.org/download/index.json: $($_.Exception.Message)"
	}
	$versionEntry = $index.PSObject.Properties[$version]
	if (-not $versionEntry) { throw "zig $version is not listed at https://ziglang.org/download/index.json" }
	$platformEntry = $versionEntry.Value.PSObject.Properties[$platformKey]
	if (-not $platformEntry) {
		$available = ($versionEntry.Value.PSObject.Properties.Name | Sort-Object) -join ', '
		throw "zig $version has no build for $platformKey (available: $available)"
	}
	$meta = $platformEntry.Value
	$url = $meta.tarball
	$expected = "$($meta.shasum)".ToLowerInvariant()
	if (-not $url -or -not $expected) { throw "zig $version's $platformKey entry is missing a tarball or shasum" }

	$stage = Join-Path $vendorRoot ('.stage-' + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Force -Path $stage | Out-Null
	try {
		$archive = Join-Path $stage (Split-Path $url -Leaf)
		Invoke-WebRequest -Uri $url -OutFile $archive
		$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
		if ($actual -ne $expected) {
			throw "checksum mismatch for $(Split-Path $url -Leaf): expected $expected, got $actual"
		}
		$extract = Join-Path $stage 'extract'
		New-Item -ItemType Directory -Force -Path $extract | Out-Null
		if ($archive.EndsWith('.zip')) {
			Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
		} else {
			& tar -xf $archive -C $extract
			if ($LASTEXITCODE -ne 0) { throw "tar could not extract $(Split-Path $url -Leaf)" }
		}
		$found = Get-ChildItem -LiteralPath $extract -Recurse -File -Filter $zigName | Select-Object -First 1
		if (-not $found) { throw "the $platformKey archive did not contain $zigName" }
		New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installDir) | Out-Null
		if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
		Move-Item -LiteralPath $found.Directory.FullName -Destination $installDir
	} finally {
		Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
	}
	if (-not (Test-ZigInstall)) { throw "zig $version failed to install at $installDir" }
}

$zigArgs = @($args)
$refresh = $false
$printPath = $false
$check = $false
while ($zigArgs.Count -gt 0 -and $zigArgs[0] -in @('--refresh', '--toolchain-path', '--check')) {
	switch ($zigArgs[0]) {
		'--refresh' { $refresh = $true }
		'--toolchain-path' { $printPath = $true }
		'--check' { $check = $true }
	}
	$zigArgs = @($zigArgs | Select-Object -Skip 1)
}

if ($refresh -or -not (Test-ZigInstall)) { Install-Zig }

if ($printPath) { Write-Output $zigBin; exit 0 }
if ($check) { Write-Output "zig $version ($zigBin)"; exit 0 }

& $zigBin @zigArgs
if ($null -eq $LASTEXITCODE) { exit 1 }
exit $LASTEXITCODE
