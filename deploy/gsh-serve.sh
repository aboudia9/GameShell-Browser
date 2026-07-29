#!/usr/bin/env bash
#
# gsh-serve.sh — start the ttyd web terminal that serves GameShell.
#
# Normally run by systemd (deploy/systemd/gameshell-ttyd.service), but it works
# standalone too. Keeping the flags here instead of in the unit file means the
# config is version-controlled and we avoid systemd's quoting rules mangling the
# theme JSON.
#
# Pairs with deploy/gsh-janitor.sh, which MUST also be running -- ttyd cannot
# clean up its own containers. See gsh-session.sh for why.

set -uo pipefail

PORT="${GSH_PORT:-7682}"
IFACE="${GSH_IFACE:-lo}"
SESSION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsh-session.sh"

# High-contrast dark theme, chosen for low-vision accessibility (21:1 on the
# base colours). Two deliberate deviations from standard ANSI:
#   - `black` is dark grey, not #000000, or black text would be invisible.
#   - `blue` is lightened; true ANSI blue (#0000EE) on black is unreadable.
THEME='{
  "background": "#000000",
  "foreground": "#FFFFFF",
  "cursor": "#FFFFFF",
  "cursorAccent": "#000000",
  "selectionBackground": "#4D4D4D",
  "black": "#4D4D4D",
  "red": "#FF6B6B",
  "green": "#5FFF5F",
  "yellow": "#FFFF5F",
  "blue": "#6FB7FF",
  "magenta": "#FF87FF",
  "cyan": "#5FD7FF",
  "white": "#E6E6E6",
  "brightBlack": "#808080",
  "brightRed": "#FF9C9C",
  "brightGreen": "#9CFF9C",
  "brightYellow": "#FFFF9C",
  "brightBlue": "#A0D2FF",
  "brightMagenta": "#FFB3FF",
  "brightCyan": "#9CE7FF",
  "brightWhite": "#FFFFFF"
}'

# -W          writable (without it, typing is silently ignored)
# -s 9        SIGKILL on disconnect -- the docker CLI ignores the default SIGHUP
# -i lo       bind loopback ONLY; Caddy is the public listener
# fontSize 16 up from the default 14, for readability and projectors
exec ttyd \
    -W \
    -s 9 \
    -i "$IFACE" \
    -p "$PORT" \
    -t "theme=${THEME}" \
    -t fontSize=16 \
    -t 'titleFixed=GameShell' \
    "$SESSION"
