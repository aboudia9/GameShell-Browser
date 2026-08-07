# Browser deployment guide

How to run GameShell in a web browser, so players need nothing installed but a
browser and a URL. This is what the `deploy/` directory in this fork is for.

Written for someone reproducing the deployment on their own VM. Assumes Ubuntu
22.04/24.04 with Docker already installed, and a domain you control.

---

## How it works

```
Player's browser
      │  https://  (nothing to install)
      ▼
   [ Caddy ]          reverse proxy, automatic HTTPS, the only public listener
      │  127.0.0.1:7682
      ▼
   [ ttyd ]           bridges a pseudo-terminal to a WebSocket
      │  one process per connection
      ▼
   [ Docker container ]   fresh, isolated, throwaway GameShell
      └── dies when the player leaves

   [ janitor ]        separate service; removes containers nobody is attached to
```

GameShell needs a *real* bash shell, so each player gets a real container. `ttyd`
streams that container's terminal to the browser, and Caddy puts TLS in front.

Three things run on the VM, and **all three are required**:

| Component | What it is |
|---|---|
| `gameshell-ttyd.service` | The web terminal (bash shell). Launches one container per connection. |
| `gameshell-janitor.service` | Cleans up abandoned containers. Not optional — see [Why the janitor exists](#why-the-janitor-exists). |
| `caddy.service` | HTTPS + reverse proxy. Installed from Caddy's own apt repo. |

Sessions are intentionally **throwaways**: no progress is saved, and every
connection starts a fresh game. If a player's terminal resets, they start
over (or if they type in process-ending commands lol).

---

## Prerequisites

- A Linux VM with a public IP. 1 GB RAM is enough to build the image and serve
  roughly 10-15 concurrent players; see [Capacity](#capacity).
- Docker installed and running, and your user in the `docker` group.
  Note that **the `docker` group is effectively root** — anyone in it can mount
  the host filesystem into a container. Don't hand it out casually.
- A domain (or subdomain) whose `A` record points at the VM. Required —
  Let's Encrypt will not issue certificates for a bare IP address.
- Ports 80 and 443 reachable from the internet.

---

## 1. Clone and build

```sh
git clone https://github.com/aboudia9/GameShell-Browser.git
cd GameShell-Browser
docker build -t gameshell .
chmod +x deploy/*.sh
```

The image **must** be tagged `gameshell` — `deploy/gsh-session.sh` looks for
that name. (Can be changed with the `GSH_IMAGE` environment variable if you need a
different one.)

The build prints a `LegacyKeyValueFormat` warning about the `ENV` line in the
Dockerfile. It is harmless.

Verify:

```sh
docker images | grep gameshell     # ~356 MB
```

---

## 2. Install ttyd

```sh
sudo apt install -y ttyd
ttyd --version
```

**Must be 1.7.0 or newer.** Older versions lack the `-W` flag, and without it
the terminal renders correctly but silently ignores everything the player
types — a fun (confusing) failure to debug.

---

## 3. Edit the systemd units

The units in `deploy/systemd/` are checked in with the original author's
username and paths hardcoded. **Edit both files before installing them.**

In `deploy/systemd/gameshell-ttyd.service` and
`deploy/systemd/gameshell-janitor.service`, change:

```ini
User=bou
ExecStart=/home/bou/GameShell-Browser/deploy/gsh-serve.sh
```

to your username and the path where you cloned the repo. The `User=` must be an
account in the `docker` group. Do NOT run these as root.

---

## 4. Install and start the services

```sh
sudo cp deploy/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gameshell-janitor.service gameshell-ttyd.service
```

`daemon-reload` is required — systemd caches unit files and will not notice new
or edited ones without it. This is the most common reason a unit change appears
to do nothing.

`enable --now` both starts the service immediately and registers it to start at
boot.

Check:

```sh
systemctl status gameshell-ttyd.service gameshell-janitor.service --no-pager
```

Both should report `active (running)`, and ttyd's line should say `enabled`.

---

## 5. Install Caddy

Caddy is not in Ubuntu's default repositories. From
[Caddy's official instructions](https://caddyserver.com/docs/install#debian-ubuntu-raspbian):

```sh
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

---

## 6. Configure Caddy

Edit `deploy/Caddyfile` and replace the hostname with your own:

```
your.domain.here {
	reverse_proxy 127.0.0.1:7682
}
```

Then install and reload:

```sh
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Use `reload`, not `restart` — it applies config gracefully without dropping live
sessions, and it refuses to apply a config that fails to parse rather than
taking the site down.

Caddy obtains and renews the TLS certificate automatically, redirects HTTP to
HTTPS, and handles ttyd's WebSocket upgrade. None of that needs configuring.

---

## 7. Firewall

```sh
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

Always allow SSH **before** enabling `ufw`, or you will lock yourself out.

**Do not open port 7682.** ttyd binds to loopback only (`-i lo`), so Caddy is
the sole public entrance. Exposing 7682 would publish an unauthenticated
terminal directly to the internet.

---

## Verifying it works

1. Browse to `https://your.domain.here` — GameShell should load, with a padlock.
2. Open a second tab. Confirm two independent games.
3. Close one tab, wait ~10 seconds, then on the VM:

   ```sh
   docker ps --filter "name=^gsh-"
   ```

   The closed session's container should be gone. If it is still listed, the
   janitor is not running.

4. Reboot the VM. Everything should come back with no manual intervention.

Optional stress check — from inside a game session, run a fork bomb:

```sh
:(){ :|:& };:
```

It should fizzle with `Resource temporarily unavailable` rather than affecting
the host. That is `--pids-limit` doing its job.

---

## Configuration

`deploy/gsh-session.sh` — per-player container:

| Flag | Purpose |
|---|---|
| `--rm` | Throwaway. No saved progress by design. |
| `--memory 256m` | Ceiling, not a reservation. Real usage is ~30 MB. |
| `--cpus 0.5` | One player cannot starve the others. |
| `--network none` | No network inside the game. Verified: no mission needs it. |
| `--pids-limit 128` | Fork-bomb protection. Generous for legitimate play. |

`deploy/gsh-serve.sh` — the ttyd invocation. Environment variables `GSH_PORT`
(default 7682) and `GSH_IFACE` (default `lo`). Also contains the high-contrast
terminal theme and font size, kept here rather than in the systemd unit so the
JSON is version-controlled and safe from systemd's quoting rules.

`deploy/gsh-janitor.sh` — the reaper. `GSH_JANITOR_INTERVAL` (default 5 seconds)
controls poll frequency. It only ever touches containers named `gsh-*`.

---

## Operations

```sh
# Logs
sudo journalctl -u gameshell-ttyd -n 50 --no-pager
sudo journalctl -u gameshell-janitor -f      # follow reaping live
sudo journalctl -u caddy -n 50 --no-pager    # certificate problems show here

# Restart after changing a script
sudo systemctl restart gameshell-ttyd

# Restart after editing a unit file
sudo systemctl daemon-reload && sudo systemctl restart gameshell-ttyd

# Update to a newer version of the game
cd ~/GameShell-Browser
git pull
docker build -t gameshell .
sudo systemctl restart gameshell-ttyd
```

Rebuilding the image does not disturb players already connected — running
containers keep using the old image layers until they exit.

### Testing without exposing anything

To reach ttyd directly while Caddy is not yet configured, tunnel over SSH
rather than opening the port:

```sh
ssh -L 7682:127.0.0.1:7682 user@your-vm
# then browse to http://localhost:7682
```

---

## Capacity

Ubuntu plus Docker use roughly 450 MB. Each real session uses ~30 MB, not the
256 MB ceiling. On a 1 GB VM that works out to somewhere around 15–18
concurrent players before swapping starts.

There is currently **no cap on concurrent sessions** — see
[Known limitations](#known-limitations).

If you need more capacity, resizing RAM and CPU is straightforward on most
cloud providers. Note that on DigitalOcean specifically, growing a disk is
permanent — disks cannot be shrunk — so prefer the "CPU and RAM only" resize.

---

## Why the janitor exists

Worth understanding before assuming it is redundant, because three intuitive
approaches all fail:

1. **Killing the `docker run` client does not stop the container.** The client
   is only a remote control. When a player closes their tab, ttyd kills the
   client and the container keeps running indefinitely.

2. **ttyd's default kill signal is SIGHUP, which the Docker CLI ignores.**
   Without `-s 9` (SIGKILL) in `gsh-serve.sh`, sessions never terminate at all.

3. **Cleanup cannot live inside the session script.** Two separate reasons:
   trapping `HUP` makes bash *survive* the signal, which keeps the session alive
   and defeats the purpose; and ttyd SIGKILLs its entire process group, so any
   watchdog the script spawns dies with it. `nohup` does not help (it blocks
   SIGHUP, not SIGKILL).

Hence an external service. The janitor lists `gsh-*` containers and removes any
with no live `docker run` client, from outside ttyd's process group where
nothing can kill it.

Also relevant: `docker run --rm` is not fully reliable when a container's main
process dies messily. The janitor covers that gap too.

---

## Troubleshooting

**Terminal loads but typing does nothing.**
ttyd is missing `-W`, or is older than 1.7.

**Browser reconnects in a loop; logs show the process exiting within
milliseconds.**
ttyd cannot execute the script. Almost always a wrong path or a missing
executable bit. Check `ExecStart=` in the unit and run `chmod +x deploy/*.sh`.

**`lws_socket_bind: ERROR on binding fd ... to port 7682 (-1 98)`.**
Error 98 is "address already in use" — something else holds that port. Check
with `pgrep -a ttyd` before killing anything. On DigitalOcean droplets, the
`droplet-agent` runs its own ttyd on `127.0.0.1:7681` to power the dashboard's
web console; **do not kill it**, that console is out-of-band recovery access if
SSH ever breaks. This is why the default port here is 7682.

**Containers accumulate and are never removed.**
The janitor is not running, or its `User=` is not in the `docker` group.
Check `systemctl status gameshell-janitor`.

**Caddy cannot obtain a certificate.**
Check `journalctl -u caddy`. Usual causes: the domain's `A` record does not
point at this VM, port 80 is not reachable, or the DNS is behind a proxy. If
DNS is on Cloudflare, the record must be **DNS only (grey cloud)** — proxying
terminates TLS at Cloudflare and breaks the ACME challenge.

**DNS edits appear to work but nothing resolves.**
The zone you edited may not be authoritative. Verify with
`dig +short NS your-domain @1.1.1.1` and confirm the nameservers belong to the
provider whose panel you edited. A correct answer from
`dig +short your.domain @1.1.1.1` is proof the record is live.

**`channel N: open failed: connect failed` spam in an SSH session.**
Harmless. An SSH port-forward's target is down — usually a stale browser tab
retrying against a tunnel.

---

## Known limitations

- **No cap on concurrent sessions.** Nothing prevents more players than the VM
  can handle from connecting. Planned.
- **No maximum session lifetime.** A player who leaves a tab open indefinitely
  holds a container indefinitely — the janitor only reaps sessions whose client
  has disconnected. Planned.
- **No authentication.** Anyone with the URL can start a session. This is a
  deliberate choice for a classroom tool, and it rests on the container
  sandboxing: non-root, no network, memory- and PID-capped, throwaway. Add
  Caddy's `basic_auth` directive if your situation differs.
- **The `intermediate/04_bg_xeyes` mission cannot work.** It runs `xeyes`, an
  X11 graphical program, which has no display in a headless container.
- **No saved progress.** By design, but worth telling players explicitly.
