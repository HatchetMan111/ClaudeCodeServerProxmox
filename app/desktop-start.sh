#!/usr/bin/env bash
# Claude Desktop (Electron) auf virtuellem Bildschirm + noVNC-Web.
# Wird vom Installer nach /opt/claude-code/desktop-start.sh kopiert und von
# der systemd-Unit claudecode-desktop.service gestartet.
# __DESKTOP_PORT__ wird vom Installer ersetzt.
set -uo pipefail

export DISPLAY=:99
PORT="__DESKTOP_PORT__"

# Virtueller Bildschirm (Xvfb) – die Electron-App braucht zwingend ein Display
Xvfb :99 -screen 0 1600x900x24 &
XVFB_PID=$!
sleep 2

# x11vnc: VNC-Server auf :99 (nur lokal, kein Passwort – Zugriffsschutz liegt
# auf dem noVNC-Web-Frontend bzw. der Firewall)
x11vnc -display :99 -forever -shared -nopw -bg -o /var/log/x11vnc.log
sleep 1

# noVNC: WebSocket-Bridge + statisches Web-Frontend auf Port $PORT
websockify --web=/usr/share/novnc "$PORT" localhost:5900 &
WS_PID=$!

sleep 1

# Claude Desktop App starten (Electron). LXC-spezifische Flags:
#   --no-sandbox            im unprivilegierten LXC fehlen User-Namespaces
#   --disable-dev-shm-usage /dev/shm ist im CT oft nur 64 MB → Chromium-Crash,
#                           Ausweichen auf /tmp
#   --disable-gpu           kein GPU-Zugriff im Container; Software-Rendering
#                           über Xvfb ist stabiler
export LIBGL_ALWAYS_SOFTWARE=1
claude-desktop --no-sandbox --disable-dev-shm-usage --disable-gpu \
    >/var/log/claude-desktop.log 2>&1 &
CD_PID=$!

# Beim Beenden alle Kindprozesse sauber mitnehmen (systemd restartet dann den Stack)
cleanup() {
    kill "$CD_PID" 2>/dev/null || true
    kill "$WS_PID" 2>/dev/null || true
    kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wenn die App stirbt, soll systemd den ganzen Stack neu starten:
wait "$CD_PID"