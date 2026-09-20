#!/bin/sh
# agent-detect — ship the harness configs from macOS to Linux over rsync.
#
# Run this ON the macOS host. It pushes each harness's config/auth/state
# directory (the set from CONTRIBUTING.md "per-harness config locations") to
# the Linux host over ssh, so a freshly provisioned daemon host can run the
# harnesses without re-configuring each one by hand.
#
# Safety rails:
#   - dry-run by default; pass --apply to transfer for real
#   - never deletes on the destination (no --delete, ever)
#   - closes nothing for you: quit the harnesses on both hosts first, so the
#     sqlite stores (.db/-wal/-shm) are not copied mid-write
#   - macOS Keychain tokens are not files and do not transfer — expect a
#     one-time re-login per harness that keeps its auth in the keychain

set -eu

usage() {
	cat <<'EOF'
usage: scripts/sync-harness-configs.sh [--apply] [--harness=<id>[,<id>]] <user@linux-host>

  (no flags)      dry-run: print what rsync would transfer, transfer nothing
  --apply         transfer for real (rsync -a; the destination keeps extra files)
  --harness       restrict to the named harness ids (comma separated)

EOF
}

apply=0
only=
remote=
for arg in "$@"; do
	case "$arg" in
		--apply) apply=1 ;;
		--harness=*) only=${arg#--harness=} ;;
		-h|--help) usage; exit 0 ;;
		-*) printf 'unknown argument: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
		*) remote="$arg" ;;
	esac
done

if [ -z "$remote" ]; then
	printf 'missing <user@linux-host> argument\n\n' >&2
	usage >&2
	exit 2
fi

os=$(uname -s)
if [ "$os" != Darwin ]; then
	printf 'run this on the macOS host (detected: %s)\n' "$os" >&2
	exit 2
fi

if ! command -v rsync >/dev/null 2>&1; then
	printf 'rsync not found on PATH\n' >&2
	exit 2
fi

# --- what ships: the config-location table, one directory per harness ----------

harness_ids='cline kimi-code mmx pi qwen kilo omp reasonix crush opencode vibe cursor copilot hermes goose zcode'

harness_paths() {
	# HOME-relative paths; a trailing slash copies the directory contents.
	case "$1" in
		cline) printf '.cline/' ;;
		kimi-code) printf '.kimi-code/' ;;
		mmx) printf '.mmx/' ;;
		pi) printf '.pi/' ;;
		qwen) printf '.qwen/' ;;
		kilo) printf '.local/share/kilo/' ;;
		omp) printf '.omp/' ;;
		reasonix) printf '.reasonix/' ;;
		crush) printf '.local/share/crush/' ;;   # config only; project .crush/ stores stay per-project
		opencode) printf '.local/share/opencode/' ;;
		vibe) printf '.vibe/' ;;
		cursor) printf '.cursor/' ;;
		copilot) printf '.copilot/' ;;
		hermes) printf '.hermes/' ;;
		goose) printf '.config/goose/' ;;
		zcode) printf '.zcode/' ;;
	esac
}

selected="$harness_ids"
if [ -n "$only" ]; then
	selected=$(printf '%s' "$only" | tr ',' ' ')
	for id in $selected; do
		case " $harness_ids " in
			*" $id "*) ;;
			*) printf 'unknown harness id: %s\n' "$id" >&2; exit 2 ;;
		esac
	done
fi

# --- preflight -------------------------------------------------------------------

printf 'checking ssh: %s\n' "$remote"
if ! ssh -o BatchMode=yes "$remote" true 2>/dev/null; then
	printf 'ssh to %s needs a login (BatchMode failed) — authenticate, then re-run\n' "$remote" >&2
	exit 2
fi

flags='-a'
label='APPLY'
if [ "$apply" = 0 ]; then
	flags='-an'
	label='DRY-RUN (pass --apply to transfer)'
fi

excludes=''
for pattern in .DS_Store '*.log' node_modules/ cache/ Cache/ Cache_Data/ logs/ tmp/; do
	excludes="$excludes --exclude=$pattern"
done

# shellcheck disable=SC2086
rsync_flags="$flags $excludes"

# --- transfer ----------------------------------------------------------------------

printf '%s — %s → %s\n\n' "$label" "$(hostname)" "$remote"
for id in $selected; do
	paths=$(harness_paths "$id")
	for path in $paths; do
		src="$HOME/$path"
		if [ ! -d "$src" ]; then
			printf '[skip]   %-10s %s (absent on this host)\n' "$id" "$path"
			continue
		fi
		dest_dir=$(dirname "$path")
		printf '[sync]   %-10s %s\n' "$id" "$path"
		# the destination parent must exist; rsync -a with a trailing slash
		# copies contents into the destination directory, and never deletes.
		# the mkdir is a write, so it runs only under --apply.
		if [ "$apply" = 1 ]; then
			ssh "$remote" "mkdir -p \"\$HOME/$dest_dir\""
		fi
		# shellcheck disable=SC2086
		rsync $rsync_flags --info=stats1 -e ssh "$src" "$remote:\$HOME/$path"
	done
done

printf '\ndone. re-login per harness whose auth lived in the macOS keychain, then run: ./scripts/install-harnesses.sh --check on the linux host\n'
