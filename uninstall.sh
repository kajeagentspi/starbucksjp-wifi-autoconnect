#!/bin/bash
# uninstall.sh — reverse install.sh.
set -u

PLIST_LABEL="com.user.starbucks-wifi-watch"
PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
INSTALL_DIR="$HOME/.starbucks-wifi"
SUDO=/usr/bin/sudo

echo ">> Stopping LaunchAgent"
[ -f "$PLIST_DST" ] && /bin/launchctl unload "$PLIST_DST" 2>/dev/null || true
/bin/rm -f "$PLIST_DST"

echo ">> Removing scoped sudoers entry"
if [ -f /etc/sudoers.d/starbucks-wifi ]; then
    if $SUDO -n true 2>/dev/null; then
        $SUDO /bin/rm -f /etc/sudoers.d/starbucks-wifi
    elif [ -n "${SUDOPW:-}" ]; then
        printf '%s\n' "$SUDOPW" | $SUDO -S /bin/rm -f /etc/sudoers.d/starbucks-wifi 2>/dev/null
    else
        echo ">> sudo required to remove sudoers. Enter your password:" >&2
        $SUDO /bin/rm -f /etc/sudoers.d/starbucks-wifi
    fi
fi

echo ">> Removing install dir $INSTALL_DIR"
/bin/rm -rf "$INSTALL_DIR"

echo ">> Done. Logs remain at $HOME/Library/Logs/starbucks-wifi-watch*.log (remove manually if desired)."
