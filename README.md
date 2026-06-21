# starbucksjp-wifi-autoconnect

Automatically re-authenticates a Wi2-powered captive Wi-Fi (e.g. Starbucks Japan)
when the timed session expires — **in place, without dropping the Wi-Fi connection**
— and only ever acts on this network.

## What it does

A small always-on watchdog (`wifi-watch.sh`) runs at login and watches for the
moment your captive session expires (real internet stops). When that happens it
re-submits the portal's "agree / connect" step via HTTP, restoring internet
**without disconnecting Wi-Fi**. If the in-place re-auth can't be verified, it
falls back to the known-good manual fix (toggle Wi-Fi power off/on).

**Detection** uses two triggers that feed one handler:
- **Ping heartbeat** to a public host (default `8.8.8.8` / Google), ~1s apart.
  3 consecutive misses ⇒ session expired (~3s detection).
- **Captive probe** (`captive.apple.com`) every ~10s — a safety net for the case
  where the portal redirects HTTP but leaves ICMP flowing (ping can't see it).

A ping alone isn't enough: at expiry the link often stays associated and the
gateway keeps answering ICMP, while only HTTP gets redirected. The captive probe
closes that gap.

**Network gating:** it only acts when the captive redirect points at the Wi2
portal (`wi2.ne.jp`). On any other network it does nothing — no relogin, no Wi-Fi
toggle, no log noise. The toggle fallback also requires a recent Wi2 sighting, so
it never touches Wi-Fi on a network it doesn't recognize.

## Requirements

- macOS (uses `networksetup`, `launchctl`, `ping`, `curl`).
- [`uv`](https://docs.astral.sh/uv/) at `~/.local/bin/uv` (used to run the
  stdlib-only `relogin_wi2.py` with no runtime network installs).

## Install

```bash
./install.sh
```

`install.sh`:
1. Copies `wifi-watch.sh` + `relogin_wi2.py` to `~/.starbucks-wifi/`.
2. Ensures a uv-managed Python exists (so relogin works while captive).
3. Installs a **scoped** sudoers entry allowing *only*
   `networksetup -setairportpower en0 off|on` without a password (for the toggle
   fallback). Validated with `visudo -c` before install.
4. Installs + loads the user LaunchAgent (`~/Library/LaunchAgents/`).

The in-place re-auth needs **no sudo**. The password is used **once**, during
install, to write the sudoers file + load the agent — and is **never** written to
disk. To run install non-interactively:

```bash
SUDOPW='your-password' ./install.sh
```

## Check it's running

```bash
launchctl list | grep starbucks                       # should list the agent
tail -f ~/Library/Logs/starbucks-wifi-watch.log       # shows ONLINE probes
tail -f ~/Library/Logs/starbucks-wifi-watch-capture.log   # portal capture (on expiry)
sudo visudo -c                                        # sudoers valid
```

## Tuning (env vars in the LaunchAgent or shell)

| Var | Default | Meaning |
|-----|---------|---------|
| `PING_HOST` | `8.8.8.8` | host the heartbeat pings |
| `PING_INTERVAL` | `1` | seconds between heartbeats |
| `PING_FAIL` | `3` | consecutive misses ⇒ expiry |
| `PROBE_INTERVAL` | `10` | captive-probe cadence (s) |
| `GATE_HOSTS` | `wi2.ne.jp` | space-separated portal signatures to gate on |
| `GATEWAY` | _(auto)_ | local gateway override; auto-detected from the en0 default route if unset |
| `RELOGIN_RETRY` | `3` | in-place relogin attempts before fallback |
| `COOLDOWN` | `15` | seconds after an action before re-arming |
| `WI2_WINDOW` | `300` | seconds a Wi2 sighting authorizes the toggle fallback |
| `WIFI_IFACE` | `en0` | Wi-Fi interface |

## Uninstall

```bash
./uninstall.sh
```

Removes the LaunchAgent, the scoped sudoers entry, and `~/.starbucks-wifi/`.

## Notes / limitations

- **No personal data is hardcoded.** The Wi-Fi gateway is auto-detected from the
  routing table, and portal URLs are logged with `mac`/`ip`/`token`/`key` params
  redacted. No MAC address, password, or username lives in this repo.
- The exact Wi2 login replay is auto-captured to `starbucks-wifi-watch-capture.log`
  at the first real expiry; if the portal ever becomes JS-only, the in-place POST
  won't fire and the Wi-Fi toggle fallback takes over (the capture log shows what
  to adapt).
- If the captive redirect host differs from `wi2.ne.jp`, update `GATE_HOSTS`.
