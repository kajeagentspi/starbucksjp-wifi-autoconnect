# CLAUDE.md

Guidance for Claude Code working in this repo.

## What this is
A macOS watchdog that auto-re-authenticates a Wi2-powered captive Wi-Fi (Starbucks
Japan) when the timed session expires — **in place, without dropping the Wi-Fi link**.
It runs as a user LaunchAgent and only ever acts when the captive redirect points at
the Wi2 portal.

## How the Wi2 login actually works (the non-obvious part)
The portal is JavaScript-driven, so a plain HTML form submit cannot finish it.
Reverse-engineered from `https://service.wi2.ne.jp/freewifi/starbucks/js/login-1.0-min.js`:

1. Captive redirect → `/freewifi/starbucks/index.html` (registers session, sets cookies).
2. "Connect" button → `GET agreement.html`.
3. "Accept" button → AJAX `POST /wi2auth/xhr/login` with JSON body
   `{"login_method":"onetap","login_params":{"agree":"1"}}`
   (`Content-Type: application/json`). Success = response JSON `result` ∈ {1, "1", true, "true"}.

`relogin_wi2.py` replays this directly with `urllib` + a cookie jar — no JS engine, no
browser. The watchdog verifies real connectivity afterwards via the captive probe.

## Files
- `wifi-watch.sh` — bash 3.2 watchdog. Ping heartbeat (8.8.8.8, ~1s, 3-strike) + 10s
  captive probe feed `handle_expiry()` → in-place relogin → Wi-Fi power-toggle fallback.
  Network-gated on `wi2.ne.jp`. Personal params redacted in logs; gateway auto-detected.
- `relogin_wi2.py` — stdlib-only Wi2 relogin, invoked via `uv run --no-project`.
- `com.user.starbucks-wifi-watch.plist` — LaunchAgent template with `__HOME__` / `__INSTALL_DIR__` placeholders.
- `install.sh` / `uninstall.sh` — deploy to `~/.starbucks-wifi`, install scoped sudoers, load/unload agent.
- `README.md` — user-facing docs.

## Key constraints / gotchas
- **bash 3.2 only** (macOS `/bin/bash`): no associative arrays, `mapfile`, or `${v,,}`.
- **LaunchAgents run with a minimal PATH** → every tool is called by absolute path
  (`/usr/sbin/networksetup`, `~/.local/bin/uv`, `/sbin/route`, …).
- **`uv run --no-project` must work offline while captive** → `install.sh` runs
  `uv python install 3.11` once; `relogin_wi2.py` is stdlib-only (no package fetch at runtime).
- **Do not re-probe inside `handle_expiry`**: the captive trigger passes its known
  `PROBE_RESULT`/`PROBE_LOC` as hints; only the ping trigger probes. Re-probing races
  on a flapping link and turns a real `REDIR` into `OFFLINE`, skipping the relogin.
- **sudoers is scoped** to exactly `networksetup -setairportpower en0 off|on`
  (fallback toggle only). The in-place relogin needs no sudo.
- **Editing `wifi-watch.sh`/`relogin_wi2.py` is not hot** — copy to `~/.starbucks-wifi/`
  and `launchctl kickstart -k gui/$(id -u)/com.user.starbucks-wifi-watch` to load changes.

## Security
- **No secrets in the repo**: no MAC/IP/password/username. `.gitignore` excludes `*.log`, cookie jars, `__pycache__`.
- The sudo password is used **once** at install via `SUDOPW='...' ./install.sh`
  (`sudo -S`, in-memory only) and is never written to disk.
- Runtime logs may show portal URLs with `mac`/`ip`/`token`/`key` query params **redacted**.

## Run / test
- Foreground smoke test: `bash wifi-watch.sh` (Ctrl-C to stop); tail `~/Library/Logs/starbucks-wifi-watch.log`.
- Install: `./install.sh` (or `SUDOPW='...' ./install.sh`). Uninstall: `./uninstall.sh`.
- Status: `launchctl list | grep starbucks`.
- Real proof of the relogin only comes at an **unauthenticated** session (disconnect &
  reconnect to the Wi2 SSID, or wait for the hourly expiry).

## Config (env vars; see README table)
`PING_HOST`, `PING_INTERVAL`, `PING_FAIL`, `PROBE_INTERVAL`, `GATE_HOSTS`, `GATEWAY`,
`RELOGIN_RETRY`, `COOLDOWN`, `WIFI_IFACE`.
