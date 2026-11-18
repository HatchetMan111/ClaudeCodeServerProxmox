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
