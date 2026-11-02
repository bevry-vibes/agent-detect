#!/usr/bin/env bash
# macOS detached fixtures-daemon lifecycle.
#
# The daemon refuses to start inside an agent session (env markers + process
# ancestry). launchd gives it a clean launchd ancestry and an environment with
# only what the plist declares, which satisfies the guard without a terminal.
#
# usage: scripts/launch-daemon-macos.sh <start|stop|restart|status|logs|uninstall>
set -euo pipefail

label="com.agent-detect.fixtures"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$repo/zig-out/bin/agent-detect-dev"
plist="$HOME/Library/LaunchAgents/$label.plist"
log_dir="$HOME/Library/Logs"
out_log="$log_dir/agent-detect-fixtures.out.log"
err_log="$log_dir/agent-detect-fixtures.err.log"
domain="gui/$(id -u)"

usage() {
	cat <<EOF
usage: $0 <start|stop|restart|status|logs|uninstall>

  start      write ~/Library/LaunchAgents/$label.plist and bootstrap it
  stop       boot out the service and disable automatic login start
  restart    stop, then start
  status     print the launchd state and the daemon pid
  logs       tail the daemon log (and the launchd stderr log when present)
  uninstall  stop, remove the plist, and delete the launchd logs
EOF
}

xml_escape() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

write_plist() {
	mkdir -p "$(dirname "$plist")" "$log_dir"
	local path_xml home_xml
	path_xml="$(xml_escape "$PATH")"
	home_xml="$(xml_escape "$HOME")"
	cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$bin</string>
    <string>fixtures</string>
    <string>daemon</string>
    <string>--write-log</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$path_xml</string>
    <key>HOME</key><string>$home_xml</string>
  </dict>
  <key>WorkingDirectory</key><string>$repo</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$out_log</string>
  <key>StandardErrorPath</key><string>$err_log</string>
</dict>
</plist>
PLIST
	plutil -lint "$plist" >/dev/null
}

start() {
	if [[ ! -x "$bin" ]]; then
		echo "missing $bin — run \`zig build dev\` first" >&2
		exit 1
	fi
	# one daemon per host: replace any prior registration before bootstrapping
	launchctl bootout "$domain/$label" 2>/dev/null || true
	launchctl enable "$domain/$label" 2>/dev/null || true
	write_plist
	launchctl bootstrap "$domain" "$plist"
	launchctl kickstart -k "$domain/$label" >/dev/null 2>&1 || true
	echo "started $label"
	echo "  plist: $plist"
	echo "  log:   $repo/fixtures/daemon.log"
}

stop() {
	launchctl bootout "$domain/$label" 2>/dev/null || true
	launchctl disable "$domain/$label" 2>/dev/null || true
	echo "stopped $label"
}

status() {
	if launchctl print "$domain/$label" >/dev/null 2>&1; then
		launchctl print "$domain/$label" | grep -E '^\s+(state|pid|last exit code|program) =' | sed 's/^[[:space:]]*/  /'
		pgrep -f "$bin fixtures daemon" >/dev/null && echo "  daemon: running" || echo "  daemon: not running"
	else
		echo "  $label is not loaded"
	fi
}

logs() {
	if [[ -f "$repo/fixtures/daemon.log" ]]; then
		tail -n 50 -f "$repo/fixtures/daemon.log"
	elif [[ -f "$err_log" ]]; then
		tail -n 50 -f "$err_log"
	else
		echo "no daemon log yet — start the service first" >&2
		exit 1
	fi
}

case "${1:-}" in
start) start ;;
stop) stop ;;
restart)
	stop
	start
	;;
status) status ;;
logs) logs ;;
uninstall)
	stop
	rm -f "$plist" "$out_log" "$err_log"
	echo "removed $plist and launchd logs"
	;;
help | -h | --help | "") usage ;;
*)
	echo "unknown command: $1" >&2
	usage >&2
	exit 2
	;;
esac
