#!/bin/sh
# agent-detect — install the test-matrix harnesses (macOS + Linux).
#
# Interactive on a user machine: each harness that is not installed yet shows
# its install methods in preference order, and asks before anything runs.
# Non-interactive on CI: pass --yes (or run under CI=true) and every harness
# installs through its first available method — the flow the daemon runner uses.
#
# Method preference (policy — see CONTRIBUTING.md "per-harness install"):
#   - npm before custom installers (web scripts run last, after a printed notice)
#   - Linux: soar appimages before flatpak (both wait for verified package ids)
#   - macOS: homebrew before npm for the harnesses with a native tap
#
# The per-harness registry (probe binary, package names, custom installers)
# lives here and in scripts/install-harnesses.ps1 — add a harness to both when
# its rule lands. Windows uses the .ps1 (scoop before winget before the app
# store; npm before custom installers).

set -eu

# --- arguments -------------------------------------------------------------

yes=0
check=0
list=0
only=
while [ $# -gt 0 ]; do
	case "$1" in
		--yes|-y) yes=1 ;;
		--check) check=1 ;;
		--list) list=1 ;;
		--harness=*) only=${1#--harness=} ;;
		--help|-h) usage=1 ;;
		*) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
	shift
done

if [ "${usage:-0}" = 1 ]; then
	cat <<'EOF'
usage: scripts/install-harnesses.sh [--yes] [--check] [--list] [--harness=<id>[,<id>]]

  (no flags)  interactive: per harness, pick an install method or skip
  --yes       non-interactive: install every harness through its first available method
  --check     probe every harness binary and print the state; install nothing
  --list      print the registry (id, probe, methods) and exit
  --harness   restrict to the named harness ids (comma separated)

CI=true or GITHUB_ACTIONS=true in the environment implies --yes.
EOF
	exit 0
fi

if [ "${CI:-}" = true ] || [ "${GITHUB_ACTIONS:-}" = true ]; then
	yes=1
fi

# --- platform --------------------------------------------------------------

os=$(uname -s)
case "$os" in
	Darwin|Linux) ;;
	*) printf 'unsupported platform: %s (use scripts/install-harnesses.ps1 on Windows)\n' "$os" >&2; exit 2 ;;
esac

# --- harness registry ------------------------------------------------------
# probe: the binary agent-detect's invocations table probes with --version.
# methods: the ordered install methods for this platform.

harness_ids='cline kimi-code mmx pi qwen kilo omp reasonix crush opencode vibe cursor copilot hermes goose autoclaw'

harness_label() {
	case "$1" in
		cline) printf 'Cline CLI' ;;
		kimi-code) printf 'Kimi Code' ;;
		mmx) printf 'MMX (MiniMax M3 CLI)' ;;
		pi) printf 'pi (π coding agent)' ;;
		qwen) printf 'Qwen Code' ;;
		kilo) printf 'Kilo Code' ;;
		omp) printf 'oh-my-pi (omp)' ;;
		reasonix) printf 'Reasonix' ;;
		crush) printf 'Crush' ;;
		opencode) printf 'OpenCode' ;;
		vibe) printf 'Mistral Vibe' ;;
		cursor) printf 'Cursor CLI (cursor-agent)' ;;
		copilot) printf 'GitHub Copilot CLI' ;;
		hermes) printf 'Hermes (contributor scope)' ;;
		goose) printf 'Goose (contributor scope)' ;;
		autoclaw) printf 'AutoClaw (desktop app)' ;;
	esac
}

harness_probe() {
	case "$1" in
		cline) printf 'cline' ;;
		kimi-code) printf 'kimi' ;;
		mmx) printf 'mmx' ;;
		pi) printf 'pi' ;;
		qwen) printf 'qwen' ;;
		kilo) printf 'kilo' ;;
		omp) printf 'omp' ;;
		reasonix) printf 'reasonix' ;;
		crush) printf 'crush' ;;
		opencode) printf 'opencode' ;;
		vibe) printf 'vibe' ;;
		cursor) printf 'cursor-agent' ;;
		copilot) printf 'copilot' ;;
		hermes) printf 'hermes' ;;
		goose) printf 'goose' ;;
		autoclaw) printf 'autoclaw' ;;
	esac
}

harness_methods() {
	# Preference order per platform; see the policy at the top of this file.
	id="$1"
	case "$id" in
		cline|kimi-code|mmx|pi) printf 'npm' ;;
		qwen|kilo|omp|reasonix|crush|opencode)
			if [ "$os" = Darwin ]; then printf 'brew npm'; else printf 'npm brew'; fi ;;
		vibe) printf 'uv' ;;
		cursor)
			if [ "$os" = Darwin ]; then printf 'brew custom'; else printf 'custom'; fi ;;
		copilot)
			if [ "$os" = Darwin ]; then printf 'brew'; else printf ''; fi ;;
		hermes) printf 'custom' ;;
		goose) printf '' ;;
		autoclaw) printf 'manual' ;;
	esac
}

npm_package() {
	case "$1" in
		cline) printf 'cline' ;;
		kimi-code) printf '@moonshot-ai/kimi-code' ;;
		mmx) printf 'mmx-cli' ;;
		pi) printf '@earendil-works/pi-coding-agent' ;;
		qwen) printf '@qwen-code/qwen-code' ;;
		kilo) printf '@kilocode/cli' ;;
		omp) printf '@oh-my-pi/pi-coding-agent' ;;
		reasonix) printf 'reasonix' ;;
		crush) printf '@charmland/crush' ;;
		opencode) printf 'opencode-ai' ;;
	esac
}

brew_package() {
	case "$1" in
		qwen) printf 'qwen-code' ;;
		kilo) printf 'Kilo-Org/tap/kilo' ;;
		omp) printf 'can1357/tap/omp' ;;
		reasonix) printf 'esengine/reasonix/reasonix' ;;
		crush) printf 'charmbracelet/tap/crush' ;;
		opencode) printf 'anomalyco/tap/opencode' ;;
		cursor) printf 'cursor-cli' ;;
		copilot) printf 'copilot-cli' ;;
	esac
}

# soar and flatpak ids stay empty until verified against the package indexes;
# the methods are wired so a verified id only needs a case line here.
soar_package() { printf ''; }
flatpak_package() { printf ''; }

uv_package() {
	case "$1" in
		vibe) printf 'mistral-vibe' ;;
	esac
}

# --- helpers ----------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

probe_harness() {
	probe=$(harness_probe "$1")
	if have "$probe"; then
		version=$("$probe" --version 2>/dev/null | head -1 || printf 'unknown')
		return 0
	fi
	return 1
}

method_available() {
	case "$1" in
		npm) have npm ;;
		brew) have brew ;;
		uv) have uv ;;
		soar) have soar && [ -n "$(soar_package "$2")" ] ;;
		flatpak) have flatpak && [ -n "$(flatpak_package "$2")" ] ;;
		custom|manual) return 0 ;;
	esac
}

method_command() {
	case "$1" in
		npm) printf 'npm i -g %s' "$(npm_package "$2")" ;;
		brew) printf 'brew install %s' "$(brew_package "$2")" ;;
		uv) printf 'uv tool install %s' "$(uv_package "$2")" ;;
		soar) printf 'soar install %s' "$(soar_package "$2")" ;;
		flatpak) printf 'flatpak install -y %s' "$(flatpak_package "$2")" ;;
		custom)
			case "$2" in
				cursor) printf 'curl -fsSL https://cursor.com/install | bash' ;;
				hermes) printf 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash' ;;
			esac ;;
		manual)
			case "$2" in
				autoclaw) printf 'download the desktop installer from https://autoclaw.z.ai' ;;
			esac ;;
	esac
}

run_method() {
	id="$1"
	method="$2"
	case "$method" in
		npm) npm i -g "$(npm_package "$id")" ;;
		brew) brew install "$(brew_package "$id")" ;;
		uv) uv tool install "$(uv_package "$id")" ;;
		soar) soar install "$(soar_package "$id")" ;;
		flatpak) flatpak install -y "$(flatpak_package "$id")" ;;
		custom)
			case "$id" in
				cursor) curl -fsSL https://cursor.com/install | bash ;;
				hermes) curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash ;;
			esac ;;
		manual)
			printf '  manual step: %s\n' "$(method_command manual "$id")"
			return 3 ;;
	esac
}

# --- --list ------------------------------------------------------------------

if [ "$list" = 1 ]; then
	printf '%-12s %-14s %s\n' HARNESS PROBE METHODS
	for id in $harness_ids; do
		printf '%-12s %-14s %s\n' "$id" "$(harness_probe "$id")" "$(harness_methods "$id" | tr ' ' ',')"
	done
	exit 0
fi

# --- selection ---------------------------------------------------------------

selected="$harness_ids"
if [ -n "$only" ]; then
	selected=$(printf '%s' "$only" | tr ',' ' ')
	for id in $selected; do
		case " $harness_ids " in
			*" $id "*) ;;
			*) printf 'unknown harness id: %s (see --list)\n' "$id" >&2; exit 2 ;;
		esac
	done
fi

# --- --check ------------------------------------------------------------------

if [ "$check" = 1 ]; then
	installed=0
	missing=0
	for id in $selected; do
		if probe_harness "$id"; then
			installed=$((installed + 1))
			printf '[ok]       %-10s %s (%s)\n' "$id" "$(harness_label "$id")" "$version"
		else
			missing=$((missing + 1))
			printf '[missing]  %-10s %s\n' "$id" "$(harness_label "$id")"
		fi
	done
	printf '%d installed, %d missing\n' "$installed" "$missing"
	exit 0
fi

# --- install loop --------------------------------------------------------------

if [ "$yes" != 1 ] && [ ! -t 0 ]; then
	printf 'stdin is not interactive — pass --yes for the non-interactive flow.\n' >&2
	exit 2
fi

failures=0
for id in $selected; do
	label=$(harness_label "$id")
	if probe_harness "$id"; then
		printf '[installed] %s — %s\n' "$id" "$version"
		continue
	fi

	methods=$(harness_methods "$id")
	if [ -z "$methods" ]; then
		printf '[skip]      %s — no install method on %s (see CONTRIBUTING.md "per-harness install")\n' "$id" "$os"
		continue
	fi

	# keep only methods whose tool is present, in registry order
	available=''
	for method in $methods; do
		if method_available "$method" "$id"; then
			available="$available $method"
		fi
	done
	if [ -z "$available" ]; then
		tools=$(for method in $methods; do printf '%s ' "$method"; done)
		printf '[skip]      %s — method tools missing on this host: %s\n' "$id" "${tools% }"
		continue
	fi

	if [ "$yes" = 1 ]; then
		method=${available# }
		method=${method%% *}
		printf '[install]   %s via %s: %s\n' "$id" "$method" "$(method_command "$method" "$id")"
		if run_method "$id" "$method"; then
			:
		elif [ "$?" = 3 ]; then
			printf '[manual]    %s — needs a manual step (printed above)\n' "$id"
		else
			printf '[fail]      %s — install command exited nonzero\n' "$id" >&2
			failures=$((failures + 1))
		fi
		continue
	fi

	# interactive: number the methods in preference order, ask, then run
	printf '\n%s — %s\n' "$id" "$label"
	i=1
	for method in $available; do
		printf '  %d) %-8s %s\n' "$i" "$method" "$(method_command "$method" "$id")"
		i=$((i + 1))
	done
	printf '  s) skip this harness\n'
	printf '? '
	read -r answer
	case "$answer" in
		s|S|'') continue ;;
		*[!0-9]*) printf '  not a choice — skipped\n'; continue ;;
	esac
	i=1
	chosen=''
	for method in $available; do
		if [ "$i" = "$answer" ]; then chosen=$method; fi
		i=$((i + 1))
	done
	if [ -z "$chosen" ]; then
		printf '  no such choice — skipped\n'
		continue
	fi
	printf '  running: %s\n' "$(method_command "$chosen" "$id")"
	if run_method "$id" "$chosen"; then
		:
	elif [ "$?" = 3 ]; then
		printf '  [manual] needs a manual step (printed above)\n'
	else
		printf '  [fail] install command exited nonzero\n' >&2
		failures=$((failures + 1))
	fi
done

if [ "$failures" -gt 0 ]; then
	printf '%d install command(s) failed\n' "$failures" >&2
	exit 1
fi
exit 0
