#!/usr/bin/env bash
#
# gsh-janitor.sh — reap abandoned GameShell session containers.
#
# Run it alongside ttyd, in its own terminal (later: a systemd service):
#     ./deploy/gsh-janitor.sh
#
# Why this exists: when a student closes their browser tab, ttyd kills the
# `docker run` client -- but that does NOT stop the container, which would
# otherwise run forever. Cleanup can't live inside the session script either,
# because ttyd SIGKILLs its whole process group on disconnect. So the janitor
# runs completely outside ttyd's blast radius.
#
# How it decides a container is abandoned: if no `docker run` process on this
# machine still mentions the container's name, nobody is attached to it.
#
# SAFETY: only ever touches containers named `gsh-*`. Anything else on the
# machine (including the dreamy_lichterman personal save) is never matched.

set -uo pipefail

INTERVAL="${GSH_JANITOR_INTERVAL:-5}"

echo "[janitor] watching gsh-* containers, checking every ${INTERVAL}s (Ctrl-C to stop)"

while true; do
    # --filter name=^gsh- is a regex anchored at the start, so only our
    # session containers are ever listed.
    while read -r name; do
        [ -z "$name" ] && continue

        # Is a `docker run` client still holding this container open?
        if pgrep -f "docker run.*${name}" >/dev/null 2>&1; then
            continue
        fi

        echo "[janitor] reaping abandoned session: ${name}"
        docker rm -f "$name" >/dev/null 2>&1 || true
    done < <(docker ps --format '{{.Names}}' --filter 'name=^gsh-')

    sleep "$INTERVAL"
done
