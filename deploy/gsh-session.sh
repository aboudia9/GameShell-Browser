#!/usr/bin/env bash
#
# gsh-session.sh — launch one throwaway GameShell container per connection.
#
# Used as the command ttyd runs for each browser connection:
#     ttyd -W -s 9 ./deploy/gsh-session.sh
#
# The `-s 9` matters: ttyd's default kill signal (SIGHUP) is ignored by the
# docker CLI, so sessions never die. SIGKILL is the only one that lands.
#
# NOTE: this script does NOT clean up its own container. It can't -- ttyd
# SIGKILLs its entire process group on disconnect, so anything we leave behind
# here dies too. Killing the `docker run` client also does NOT stop the
# container. Cleanup is handled by deploy/gsh-janitor.sh, which runs outside
# ttyd entirely. Both must be running.

set -uo pipefail

IMAGE="${GSH_IMAGE:-gameshell}"

# The name is the handle the janitor uses to find and reap this container.
# The `gsh-` prefix is load-bearing -- the janitor only ever touches `gsh-*`.
NAME="gsh-$$-${RANDOM}"

# `exec` REPLACES this shell with docker -- same PID, no bash left behind to
# catch or defer signals. docker must be in the foreground for -it to work.
exec docker run --rm -it \
    --name "$NAME" \
    --memory 256m \
    --cpus 0.5 \
    --network none \
    --pids-limit 128 \
    "$IMAGE"
