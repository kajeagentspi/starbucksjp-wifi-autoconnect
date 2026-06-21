#!/bin/bash
# install.sh — install the Wi2 (Starbucks JP) Wi-Fi auto-relogin watchdog.
#
# - Copies wifi-watch.sh + relogin_wi2.py to a stable dir (~/.starbucks-wifi)
# - Ensures a uv-managed python exists (so relogin runs with no network at runtime)
# - Installs a SCOPED sudoers entry so the toggle fallback can run unattended
# - Installs + loads the user LaunchAgent
#
# Privileged steps use sudo. To run non-interactively, pass the password via the
# SUDOPW env var (used only in-memory via `sudo -S`, never written to disk):
#     SUDOPW='your-password' ./install.sh
# Otherwise you will be prompted for your password.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.starbucks-wifi"
PLIST_LABEL="com.user.starbucks-wifi-watch"
PLIST_SRC="$REPO_DIR/com.user.starbucks-wifi-watch.plist"
PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
UV="${UV:-$HOME/.local/bin/uv}"
USER_NAME="$(id -un)"
IFACE="${WIFI_IFACE:-en0}"
NETSETUP=/usr/sbin/networksetup
SUDO=/usr/bin/sudo

echo ">> Installing scripts to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp "$REPO_DIR/wifi-watch.sh"  "$INSTALL_DIR/wifi-watch.sh"
cp "$REPO_DIR/relogin_wi2.py" "$INSTALL_DIR/relogin_wi2.py"
chmod +x "$INSTALL_DIR/wifi-watch.sh"
mkdir -p "$HOME/Library/Logs"

if [ -x "$UV" ]; then
    echo ">> Ensuring a uv-managed python (offline-capable relogin)"
    "$UV" python install 3.11 >/dev/null 2>&1 || echo "   (uv python install skipped; will use fallback)"
else
    echo "!! uv not found at $UV — the in-place relogin will not work. Install uv first."
fi

# --- sudo helper: use SUDOPW if provided, else prompt ---
need_sudo() {
    if $SUDO -n true 2>/dev/null; then return 0; fi
    if [ -n "${SUDOPW:-}" ]; then
        printf '%s\n' "$SUDOPW" | $SUDO -S -v 2>/dev/null && return 0
    fi
    echo ">> sudo required for the sudoers entry. Enter your password:" >&2
    $SUDO -v
}

echo ">> Installing scoped sudoers (networksetup airport toggle only)"
SUDOERS_TMP="$(/usr/bin/mktemp -t wifi-sudoers)"
cat > "$SUDOERS_TMP" <<EOF
# Managed by starbucksjp-wifi-autoconnect. Allows $USER_NAME to toggle Wi-Fi
# power on $IFACE without a password (wifi-watch.sh fallback only).
$USER_NAME ALL=(root) NOPASSWD: $NETSETUP -setairportpower $IFACE off, $NETSETUP -setairportpower $IFACE on
EOF
need_sudo
if $SUDO /usr/sbin/visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    $SUDO /usr/bin/install -m 0440 -o root -g wheel "$SUDOERS_TMP" /etc/sudoers.d/starbucks-wifi
    echo "   sudoers installed -> /etc/sudoers.d/starbucks-wifi"
else
    echo "!! sudoers file failed validation; NOT installed" >&2
fi
/bin/rm -f "$SUDOERS_TMP"

echo ">> Installing LaunchAgent"
TMP_PLIST="$(/usr/bin/mktemp -t wifi-plist)"
sed -e "s#__HOME__#$HOME#g" -e "s#__INSTALL_DIR__#$INSTALL_DIR#g" "$PLIST_SRC" > "$TMP_PLIST"
mkdir -p "$(dirname "$PLIST_DST")"
cp "$TMP_PLIST" "$PLIST_DST"
/bin/rm -f "$TMP_PLIST"

/bin/launchctl unload "$PLIST_DST" >/dev/null 2>&1 || true
/bin/launchctl load -w "$PLIST_DST" 2>/dev/null

echo ""
echo ">> Done."
echo "   label:    $PLIST_LABEL"
echo "   status:   launchctl list | grep starbucks"
echo "   log:      tail -f $HOME/Library/Logs/starbucks-wifi-watch.log"
echo "   capture:  tail -f $HOME/Library/Logs/starbucks-wifi-watch-capture.log"
echo "   stop:     ./uninstall.sh"
