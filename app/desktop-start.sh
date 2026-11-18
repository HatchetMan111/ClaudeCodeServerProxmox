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
#
# WICHTIG (Live-Fund 2026-11-18): noVNC hat KEINE index.html – ohne Zieldatei
# liefert websockify ein Directory-Listing ("Directory listing for /"). Der
# echte Einstieg heißt vnc.html. Da vnc.html seine Assets RELATIV einbindet
# (app/, core/, vendor/), muss es im Wurzelverzeichnis des --web-Pfads liegen.
# /usr/share/novnc ist genau dieses Wurzelverzeichnis → wir legen dort eine
# index.html als Weiterleitung auf vnc.html (bleibt beim Reload/Deep-Link stabil).
if [[ ! -e /usr/share/novnc/index.html ]]; then
    cat > /usr/share/novnc/index.html <<'HTML'
<!DOCTYPE html>
<html lang="de">
<head><meta charset="utf-8"><title>Claude Desktop (noVNC)</title>
<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=1&resize=scale">
<style>html{background:#1e1e1e;color:#eee;font-family:system-ui,sans-serif;
display:flex;height:100vh;align-items:center;justify-content:center}</style></head>
<body><p>Claude Desktop startet … <a style="color:#9cf" href="vnc.html?autoconnect=1&resize=scale">noVNC öffnen</a></p></body>
</html>
HTML
fi

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