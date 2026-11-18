# 🤖 ClaudeCodeServerProxmox

**Claude Code als dauerhaft laufende Session auf dem Proxmox-Server** — installierbar mit einem Einzeiler im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/).

Der Installer erstellt einen unprivilegierten LXC-Container (`claudecode`) und richtet darin ein:

- **Claude Code** (offizieller Native-Installer von `claude.ai`, SHA-256-verifiziert, kein Node nötig)
- **tmux-Dauersession** (`claude`) unter systemd — läuft nach Reboot automatisch weiter, startet sich bei Beenden/Crash selbst neu (Respawn-Wrapper)
- **ttyd-Webterminal** als Web-UI: die Live-Session im Browser, geschützt mit generiertem Basic-Auth-Passwort
- beides reboot-sicher als systemd-Services (`onboot: 1`, `Restart=always/on-failure`)

## 🚀 Installation (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ClaudeCodeServerProxmox/main/install/claudecode.sh)"
```

Mit Optionen (direkt hinter dem schließenden Anführungszeichen anhängen):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ClaudeCodeServerProxmox/main/install/claudecode.sh)" \
  --id 210 --memory 4096 --api-key sk-ant-...
```

### Optionen

| Option | Default | Bedeutung |
|---|---|---|
| `--id ID` | nächste freie ab 200 | Container-ID |
| `--hostname NAME` | `claudecode` | Container-Hostname |
| `--storage NAME` | `local-lvm` | Storage für rootfs |
| `--rootfs GB` | `16` | Disk-Größe |
| `--cores N` | `2` | vCPUs |
| `--memory MB` | `4096` | RAM |
| `--swap MB` | `512` | Swap |
| `--bridge BR` | `vmbr0` | Netzwerk-Bridge |
| `--ip CIDR` | `dhcp` | Statische IP, z. B. `192.168.1.50/24` (+ `--gateway`) |
| `--password PW` | automatisch | Root-Passwort des CT |
| `--port PORT` | `7681` | Web-Terminal-Port im Container |
| `--claude-version VER` | `latest` | Claude-Code-Version (`latest`/`stable`/z. B. `2.1.326`) |
| `--api-key KEY` | – | `ANTHROPIC_API_KEY` setzen (sonst OAuth-Login im ersten Lauf) |
| `--desktop` | – | Claude Desktop App (Linux-Beta) + virtueller Bildschirm (Xvfb) + noVNC im Browser (Port 6080) |
| `--desktop-port PORT` | `6080` | noVNC-Web-Port im Container |
| `--desktop-only` | – | Nur die Desktop-App im **bestehenden** Container nachrüsten (Claude Code bleibt unangetastet) |
| `--webui` | – | **CloudCLI-Web-Dashboard** (Community-UI im ZCode-Stil: modernes Browser-UI für die Sessions, **kein VNC**, Port 8090) |
| `--webui-port PORT` | `8090` | Dashboard-Port im Container |
| `--webui-only` | – | Nur das Dashboard im **bestehenden** Container nachrüsten |
| `--force` | – | Vorhandenen CT mit gleichem Hostname löschen + neu anlegen |
| `--yes / -y` | – | Rückfragen überspringen |
| `--update` | – | Claude-Code-Version im bestehenden CT erneuern |
| `--uninstall` | – | CT stoppen und löschen |
| `--status` | – | Status anzeigen |
| `--debug` | – | Vollständiges `bash -x`-Trace |

## 🔑 Erster Login (einmalig)

Der Installer richtet alles ein, aber **die Claude-Anmeldung macht Claude selbst** beim ersten Start der Session:

1. **Web-Terminal öffnen** — die Summary nach der Installation zeigt URL + Login:
   `http://<CT-IP>:7681` (Basic-Auth: `claude` / generiertes Passwort)
2. **Claude startet im Onboarding** → Theme wählen → *„Claude account with subscription“* (oder API-Key) → die angezeigte **OAuth-URL im lokalen Browser öffnen**, bei Anthropic anmelden, den **Code zurück ins Terminal kopieren**
3. Fertig — der Login wird im Container gespeichert (`/root/.claude`) und **überlebt Reboots und Updates**. Die Session läuft weiter, auch wenn du den Browser schließt.

Alternativ:

- **API-Key statt OAuth:** Installation mit `--api-key sk-ant-...` (oder nachträglich in `/opt/claude-code/claude.env` eintragen + `systemctl restart claudecode-session` im CT)
- **Long-lived Token (Max-Subscription):** im Terminal `claude setup-token` ausführen
- **Terminal statt Browser:** `pct enter <CT-ID>` → `tmux attach -t claude`

## 🖥️ Moderne Web-Oberfläche / Desktop (optional)

Claude Code hat neben dem Terminal noch eine **moderne UI** — die aber **nicht** im LXC läuft:

| Oberfläche | Wo sie läuft | Wie sie mit dem LXC verbunden wird |
|---|---|---|
| **Remote Control** (claude.ai/code, Browser & Handy) | Anthropic-Cloud, zeigt **diese** Session | In der Session `/login` (OAuth, **Claude-Plan Pro/Max/Ultra/Team/Enterprise nötig, kein API-Key**) → Browser öffnen → Session `claudecode` wählen |
| **Claude Desktop App** (Linux-Beta) | **im LXC** (Xvfb + noVNC) | Installation mit `--desktop` → `http://<CT-IP>:6080` (noVNC im Browser) |
| **Claude Desktop App** (nativen PC) | nativ auf deinem PC (macOS/Windows/Linux .deb) | Per **SSH** auf den CT verbinden (Remote-SSH) |
| **Web-Terminal** (ttyd) | im LXC | `http://<CT-IP>:7681` (Basic-Auth) |

**Desktop-App im LXC (`--desktop`):** Die Linux-Beta (Electron) braucht ein Display — im headless-Container läuft sie auf einem **virtuellen Bildschirm** (Xvfb), per **x11vnc** und **noVNC** im Browser erreichbar: **`http://<CT-IP>:6080/vnc.html`** (eine `index.html` leitet automatisch dorthin weiter). Ohne `/vnc.html` zeigt noVNC nur ein Directory-Listing — noVNC hat keine `index.html`. Hinweis: Das ist eine **Beta** und frisst RAM (Electron ~500 MB+); für den Dauerbetrieb ist Remote Control (Browser/Handy) der schlankere Weg.

### 📊 CloudCLI-Dashboard ohne VNC (`--webui`)

Wie im ZCodeAI-Server-Projekt ein **modernes Browser-Dashboard auf einem Port** — aber ohne VNC: [CloudCLI](https://github.com/siteboon/claudecodeui) (früher Claude Code UI, 14k+ ★) ist eine selbst-hostbare Web-UI, die die Claude-Code-Sessions (`~/.claude`) automatisch entdeckt.

```bash
# Bei Neuinstallation:
... --webui
# Oder im bestehenden Container nachrüsten (schnell, ohne Claude-Code-Reinstall):
... --webui-only
```

→ `http://<CT-IP>:8090` — beim ersten Öffnen legt man das lokale UI-Konto an; die Sessions aus dem Container sind sofort da. Voraussetzung: Node 22 wird bei Bedarf automatisch im CT installiert (offizielles Binary + SHA-256-geprüft). CloudCLI ist eine **Community-UI** (nicht von Anthropic) und nutzt deine eigene Claude-Subscription.

**Wichtig:** Remote Control ist nur ein **Fenster** in die lokal laufende Session — der CT muss laufen, Claude läuft im Container weiter. Die Desktop-App ist ein natives Programm (kein LXC-Paket); sie verbindet sich per SSH.

### Schritt für Schritt: Claude-Oberfläche im Browser nutzen

1. **Login in der Session** (einmalig): Web-Terminal öffnen → `claude` starten → OAuth-URL im Browser öffnen → anmelden → Code zurück ins Terminal
   (Voraussetzung: Claude-Plan **Pro/Max/Ultra/Team/Enterprise** — mit API-Key funktioniert Remote Control **nicht**)
2. **`https://claude.ai/code`** im Browser öffnen (oder Claude-App am Handy)
3. Dort die Session **`claudecode`** (dein CT) auswählen — fertig

Der CT muss dafür laufen; Claude läuft im Container weiter, auch wenn du Browser/App schließt.

### Nach der Installation: Reboot-Test

```bash
pct reboot <CT-ID>          # z. B. pct reboot 204
# danach prüfen:
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ClaudeCodeServerProxmox/main/install/claudecode.sh)" --status
```

Session und Web-Terminal müssen nach dem Reboot wieder laufen (`onboot: 1` + systemd).

> **Tipp:** Der CT bezieht seine IP per DHCP — die IP kann sich ändern (z. B. `10.120.1.141`). Für eine feste IP eine **DHCP-Reservierung** im Router setzen oder bei der Installation `--ip 10.120.1.x/24 --gateway 10.120.1.1` nutzen.

## 📡 Zugriffe

| Was | Wo |
|---|---|
| Web-Terminal (Claude-Session im Browser) | `http://<CT-IP>:7681` — Basic-Auth `claude` / Passwort (steht in der Install-Summary bzw. `claudecode-web.service`) |
| SSH/Konsole | `pct enter <CT-ID>` (Root-PW in der Summary) |
| Claude-Session ansehen/übernehmen | `tmux attach -t claude` (im CT) |
| Workspace | `/root/claude-workspace` (im CT) |

## 🔁 Update / Deinstall / Status

```bash
# Claude-Code-Version erneuern (Login, claude.env und Workspace bleiben erhalten)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ClaudeCodeServerProxmox/main/install/claudecode.sh)" --update

# Status (Services, tmux-Session, IP, Version)
... --status

# Container mitsamt Session stoppen und löschen
... --uninstall            # (Bestätigung mit "ja")
... --uninstall --yes      # ohne Rückfrage
```

## 🧰 Fehlerdiagnose

- Komplettes Install-Log: `/tmp/claudecode-installer-<zeitstempel>.log` (Pfad steht in der Ausgabe)
- Neuer Lauf mit vollem Trace: `... --debug`
- Innerhalb des Containers:
  - Setup-Log: `/var/log/claudecode-setup.log`
  - Session-Logs: `journalctl -u claudecode-session -e`
  - Web-Terminal-Logs: `journalctl -u claudecode-web -e`
- Session manuell neu starten: `systemctl restart claudecode-session`
- Claude-Login-Zustand prüfen: `claude doctor` (im CT)

## ⚠️ Sicherheit

Das Web-Terminal ist ein **Root-Terminal im Container** (Isolation durch unprivilegiertes LXC + Basic-Auth). Port `7681` **nicht ohne VPN/Firewall ins Internet exposen** — Basic-Auth ist kein Vollschutz. Für Fernzugriff empfiehlt sich der Tunnel über den PVE-Host (SSH) oder VPN.

## 🧪 Tests

```bash
tests/run-tests.sh
```

Mock-Harness (kein Proxmox nötig): Install-Happy-Path inkl. Container-Erstellung, ID-Vergabe, DNS-Fallback, `--update` auf gestopptem CT, `--status`, `--uninstall`, `--api-key`, Versions-Pin, `$0`-Options-Fallback.
