#!/usr/bin/env bash
# =============================================================================
# ClaudeCode-Proxmox Mock-Harness (kein Proxmox-Host nötig)
#
# Läuft als unprivilegierter User: `unshare -rm` mappt den User auf root
# (EUID 0 → Root-Prüfung des Production-Scripts testbar) und isoliert die
# Schreibpfade per Mount-Namespace (tmpfs über /opt, /root, /usr/local/bin,
# /var/log, /etc/dhcp, /etc/systemd/system; bind-mount über /etc/resolv.conf).
# Alle pct/pveam/curl/systemctl/...-Aufrufe werden über tests/fakebin gemockt.
#
# Aufruf:   tests/run-tests.sh            (alle Cases)
#           tests/run-tests.sh <name> ... (nur bestimmte Cases)
# =============================================================================
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HARNESS_DIR")"
FAKEBIN="$HARNESS_DIR/fakebin"
ASSETS="$HARNESS_DIR/assets"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
WORK="/tmp/claudecode-harness.$$"
INSTALLER="$REPO/install/claudecode.sh"

PASS=0
FAIL=0
FAILED_CASES=()

# ── Assertions (inner- und host-seitig benutzt) ────────────────────────────
ok()   { echo "OK   $*" >> "$RESULTS_FILE"; }
fail() { echo "FAIL $*" >> "$RESULTS_FILE"; }

assert_eq() {
    local got="$1" want="$2" msg="$3"
    if [[ "$got" == "$want" ]]; then ok "$msg"; else fail "$msg (got=[$got] want=[$want])"; fi
}

assert_contains() {
    local hay="$1" needle="$2" msg="$3"
    if grep -qF -- "$needle" <<< "$hay"; then ok "$msg"; else fail "$msg (fehlt: [$needle])"; fi
}

assert_file() {
    if [[ -e "$1" ]]; then ok "$2"; else fail "$2 (Datei fehlt: $1)"; fi
}

assert_no_file() {
    if [[ ! -e "$1" ]]; then ok "$2"; else fail "$2 (sollte fehlen, existiert: $1)"; fi
}

assert_mode() {
    local m
    m=$(stat -c %a "$1" 2>/dev/null || echo "?")
    assert_eq "$m" "$2" "$3"
}

# ── Installer-Lauf (innerhalb NS) ──────────────────────────────────────────
run_installer() {
    OUT=$(bash "$INSTALLER" "$@" < /dev/null 2>&1)
    RC=$?
}

# ── Presets (State-Seeding, läuft im NS) ───────────────────────────────────
seed_full_ct() {
    # Ein "fertig installierter" CT: Unit mit Passwort, claude-Mock, tmux an
    local pw="${1:-seedpw9876}"
    mkdir -p /etc/systemd/system /root/.local/bin /opt/claude-code /root/claude-workspace
    printf 'ExecStart=/usr/local/bin/ttyd -p 7681 -c claude:%s -W /usr/bin/tmux attach -t claude\n' "$pw" \
        > /etc/systemd/system/claudecode-web.service
    cat > /root/.local/bin/claude <<'LAUNCHER'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "2.1.326 (Claude Code)"
    exit 0
fi
echo "mock-claude: $*"
exit 0
LAUNCHER
    chmod +x /root/.local/bin/claude
    echo 1 > "$HARNESS_STATE/tmux.session"
}

seed_preset() {
    local preset="$1"
    mkdir -p "$HARNESS_STATE/cts" "$HARNESS_STATE/systemd"
    case "$preset" in
        fresh) ;;
        occupied200) printf 'running other-ct 10.0.0.200\n' > "$HARNESS_STATE/cts/200" ;;
        dup) printf 'running claudecode 10.0.0.208\n' > "$HARNESS_STATE/cts/208" ;;
        existing-stopped)
            printf 'stopped claudecode 10.0.0.205\n' > "$HARNESS_STATE/cts/205"
            mkdir -p /etc/systemd/system
            printf 'ExecStart=/usr/local/bin/ttyd -p 7681 -c claude:oldpw123 -W /usr/bin/tmux attach -t claude\n' \
                > /etc/systemd/system/claudecode-web.service
            ;;
        status-running)
            printf 'running claudecode 10.0.0.42\n' > "$HARNESS_STATE/cts/206"
            seed_full_ct seedpw9876
            touch "$HARNESS_STATE/systemd/claudecode-session.service.active"
            touch "$HARNESS_STATE/systemd/claudecode-web.service.active"
            ;;
        status-stopped)
            printf 'stopped claudecode 10.0.0.42\n' > "$HARNESS_STATE/cts/206"
            seed_full_ct seedpw9876
            ;;
        uninstall)
            printf 'running claudecode 10.0.0.207\n' > "$HARNESS_STATE/cts/207"
            ;;
        *)
            echo "unbekanntes Preset: $preset" >&2
            exit 64
            ;;
    esac
}

# ── Cases (laufen im NS; non_root bewusst nicht) ───────────────────────────
case_fresh_install() {
    run_installer
    assert_eq "$RC" 0 "Install-Exit-Code 0"
    assert_contains "$OUT" "Claude Code ist bereit!" "Summary erscheint"
    assert_contains "$OUT" "http://10.0.0.42:7681" "Summary zeigt CT-IP + Port"
    assert_contains "$OUT" "2.1.326 (Claude Code)" "claude --version verifiziert"
    assert_contains "$OUT" "HTTP 200" "Web-Terminal HTTP-Check mit Basic-Auth"
    assert_contains "$OUT" "aabbccdd00112233aabbccdd00112233" "generiertes Web-PW in Summary"

    assert_file /etc/systemd/system/claudecode-session.service "Session-Unit installiert"
    assert_file /etc/systemd/system/claudecode-web.service "Web-Unit installiert"
    local u
    u=$(cat /etc/systemd/system/claudecode-web.service)
    assert_contains "$u" "-p 7681" "__PORT__ wurde ersetzt (7681)"
    assert_contains "$u" "-c claude:aabbccdd00112233aabbccdd00112233" "__WEB_PASSWORD__ wurde ersetzt"
    assert_contains "$u" "-W /usr/bin/tmux attach -t claude" "ttyd hängt an tmux-Session 'claude'"
    local s
    s=$(cat /etc/systemd/system/claudecode-session.service)
    assert_contains "$s" "new-session -d -s claude" "Session-Unit erzeugt tmux-Session 'claude'"
    assert_contains "$s" "Restart=on-failure" "Session-Unit hat Restart-Policy"

    local w
    w=$(cat /opt/claude-code/session.sh)
    assert_contains "$w" "while true" "Respawn-Wrapper vorhanden"
    assert_contains "$w" "/root/.local/bin" "Wrapper setzt PATH auf Claude-Binary"
    assert_contains "$w" "claude-workspace" "Wrapper wechselt in Workspace"

    assert_file /usr/local/bin/claude "claude-Symlink vorhanden"
    assert_file /root/claude-workspace "Workspace angelegt"
    assert_file /opt/claude-code/claude.env "claude.env angelegt"
    assert_mode /opt/claude-code/claude.env 600 "claude.env ist chmod 600"
    local e
    e=$(cat /opt/claude-code/claude.env)
    if grep -q "^ANTHROPIC_API_KEY=sk-" <<< "$e"; then
        fail "ohne --api-key darf kein Key gesetzt sein"
    else
        ok "ohne --api-key bleibt claude.env ohne Key"
    fi
    if grep -q "claude.env" /root/.bashrc 2>/dev/null; then ok ".bashrc source-Zeile vorhanden"; else fail ".bashrc source-Zeile fehlt"; fi

    assert_file "$HARNESS_STATE/systemd/claudecode-session.service.active" "Session-Service aktiv"
    assert_file "$HARNESS_STATE/systemd/claudecode-web.service.active" "Web-Service aktiv"

    local r
    r=$(cat /etc/resolv.conf)
    assert_contains "$r" "nameserver 1.1.1.1" "resolv.conf mit Fallback-Nameservern"
    assert_file /etc/dhcp/dhclient-enter-hooks.d/no-dns "DHCP-DNS-Überschreib-Hook gesetzt"

    local c t
    c=$(cat "$HARNESS_STATE/pct-create-200.args" 2>/dev/null || echo "")
    assert_contains "$c" "--hostname claudecode" "CT heißt 'claudecode'"
    assert_contains "$c" "--onboot 1" "onboot=1 (Reboot-sicher)"
    assert_contains "$c" "--unprivileged 1" "unprivilegierter CT"
    assert_contains "$c" "nesting=1" "nesting=1"
    assert_contains "$c" "--memory 4096" "RAM 4096 MB"
    assert_contains "$c" "--cores 2" "2 vCPUs"
    assert_contains "$c" "local:vztmpl/debian-12-standard" "Debian-12-Template"

    t=$(cat "$HARNESS_STATE/tmux-calls.log" 2>/dev/null || echo "")
    assert_contains "$t" "new-session -d -s claude" "tmux-Session 'claude' erzeugt"

    if [[ -f "$HARNESS_STATE/cts/200" ]]; then ok "CT-ID 200 vergeben (erste freie ab 200)"; else fail "CT-ID 200 vergeben (erste freie ab 200)"; fi
}

case_id_skip() {
    run_installer
    assert_eq "$RC" 0 "Install-Exit-Code 0 (belegte ID 200)"
    assert_no_file "$HARNESS_STATE/pct-create-200.args" "belegte ID 200 nicht erneut vergeben"
    assert_file "$HARNESS_STATE/pct-create-201.args" "nächste freie ID 201 vergeben"
}

case_dns_late() {
    run_installer
    assert_eq "$RC" 0 "Install-Exit-Code 0 (DNS erst ab 11. Aufruf ok → Fallback)"
    assert_contains "$OUT" "DNS-Fallback aktiv" "DNS-Fallback-Pfad wurde durchlaufen"
    assert_file /etc/dhcp/dhclient-enter-hooks.d/no-dns "Fallback-Hook geschrieben"
}

case_dns_flaky() {
    run_installer
    assert_eq "$RC" 0 "Install-Exit-Code 0 (flaky DNS, 3-Erfolge-Fenster)"
    if grep -q "DNS-Fallback aktiv" <<< "$OUT"; then
        fail "flaky4 ohne dauerhaften Defekt löst KEINEN Fallback aus (Grube 11a)"
    else
        ok "flaky4 ohne dauerhaften Defekt löst KEINEN Fallback aus (Grube 11a)"
    fi
    assert_contains "$OUT" "DNS im Container funktioniert (3x bestätigt)" "3 konsekutive Erfolge erkannt"
}

case_dns_dead() {
    run_installer
    assert_eq "$RC" 1 "DNS tot → Installer bricht ab (Exit 1)"
    assert_contains "$OUT" "DNS im Container weiterhin ohne Funktion" "Diagnose-Message bei totalem DNS"
    assert_contains "$OUT" "getent hosts" "Debug-Hinweis enthält getent-Kommando"
}

case_update_stopped() {
    run_installer --update
    assert_eq "$RC" 0 "Update-Exit-Code 0 (CT war gestoppt)"
    local calls
    calls=$(cat "$HARNESS_STATE/pct-calls.log" 2>/dev/null || echo "")
    assert_contains "$calls" "pct start 205" "gestoppter CT wurde automatisch gestartet"
    assert_contains "$OUT" "Update abgeschlossen" "Update-Summary erscheint"
    local u
    u=$(cat /etc/systemd/system/claudecode-web.service)
    assert_contains "$u" "claude:oldpw123" "Web-PW wurde vom bestehenden CT übernommen (nicht rotiert)"
    assert_file "$HARNESS_STATE/systemd/claudecode-session.service.active" "Session-Service nach Update aktiv"
    assert_file "$HARNESS_STATE/systemd/claudecode-web.service.active" "Web-Service nach Update aktiv"
}

case_status_running() {
    run_installer --status
    assert_eq "$RC" 0 "Status-Exit-Code 0"
    assert_contains "$OUT" "claudecode-session.service läuft" "Session-Service-Status"
    assert_contains "$OUT" "claudecode-web.service läuft" "Web-Service-Status"
    assert_contains "$OUT" "Session 'claude' vorhanden" "tmux-Session-Status"
    assert_contains "$OUT" "http://10.0.0.42:7681" "Web-Terminal-URL mit IP"
    assert_contains "$OUT" "Login: claude / seedpw9876" "Web-PW aus Unit gelesen"
    assert_contains "$OUT" "2.1.326 (Claude Code)" "Claude-Version im Status"
}

case_status_stopped() {
    run_installer --status
    assert_eq "$RC" 0 "Status-Exit-Code 0 (CT gestoppt)"
    assert_contains "$OUT" "Container ist gestoppt" "Stopp-Warnung erscheint"
    assert_contains "$OUT" "pct start 206" "Start-Hinweis mit CT-ID"
}

case_uninstall_yes() {
    run_installer --uninstall --yes
    assert_eq "$RC" 0 "Deinstall-Exit-Code 0"
    assert_no_file "$HARNESS_STATE/cts/207" "CT 207 gelöscht"
    assert_contains "$OUT" "entfernt" "Deinstall-Bestätigung"
}

case_uninstall_confirm() {
    run_installer --uninstall
    assert_eq "$RC" 1 "Deinstall ohne Bestätigung bricht ab"
    assert_file "$HARNESS_STATE/cts/207" "CT 207 NICHT gelöscht (Schutz funktioniert)"
    assert_contains "$OUT" "Keine Bestätigung erhalten" "Abbruch-Message"
    assert_contains "$OUT" "--uninstall --yes" "Erzwinge-Hinweis mit exaktem Befehl"
}

case_dup_hostname() {
    run_installer
    assert_eq "$RC" 1 "Duplikat-Hostname → Abbruch"
    assert_contains "$OUT" "existiert bereits" "Duplikat-Diagnose"
    assert_contains "$OUT" "--update" "Hinweis auf --update"
    assert_contains "$OUT" "--force" "Hinweis auf --force"
}

case_api_key() {
    run_installer --api-key "sk-ant-test1234"
    assert_eq "$RC" 0 "Install-Exit-Code 0 (--api-key)"
    local e
    e=$(cat /opt/claude-code/claude.env)
    assert_contains "$e" "ANTHROPIC_API_KEY=sk-ant-test1234" "API-Key in claude.env"
    assert_mode /opt/claude-code/claude.env 600 "claude.env ist chmod 600"
    assert_contains "$OUT" "API-Key:       gesetzt" "Summary meldet API-Key (maskiert)"
    if grep -q "sk-ant-test1234" <<< "$OUT"; then
        fail "API-Key darf NICHT im Klartext in der Summary stehen"
    else
        ok "API-Key nur maskiert in der Summary"
    fi
}

case_version_pin() {
    run_installer --claude-version "2.1.326"
    assert_eq "$RC" 0 "Install-Exit-Code 0 (Versions-Pin)"
    assert_contains "$OUT" "installing Claude Code (2.1.326)" "Bootstrap lief mit gepinnter Version"
}

case_help() {
    run_installer --help
    assert_eq "$RC" 0 "Help-Exit-Code 0"
    assert_contains "$OUT" "--claude-version" "Help listet --claude-version"
    assert_contains "$OUT" "--api-key" "Help listet --api-key"
}

case_zero_fallback() {
    # bash -c "$(wget ...)" --status: $0 ist "--status", kein $1 – der
    # Installer muss die Option trotzdem erkennen ($0-Fallback).
    OUT=$(bash -c "$(cat "$INSTALLER")" --status < /dev/null 2>&1)
    RC=$?
    assert_eq "$RC" 0 "Exit-Code 0 ($0-Fallback)"
    assert_contains "$OUT" "Status ClaudeCode" "Option wurde als --status erkannt"
    assert_contains "$OUT" "claudecode-session.service läuft" "Status-Output vollständig"
}

case_error_chain() {
    run_installer
    assert_eq "$RC" 9 "pct create-Fehler → Exit-Code 9 durchgereicht"
    assert_contains "$OUT" "Installationsfehler – Exit-Code 9" "on_error: Exit-Code genannt"
    assert_contains "$OUT" "Fehlgeschlagener Befehl: pct create" "on_error: fehlgeschlagener Befehl genannt"
    assert_contains "$OUT" "Letzte Logzeilen" "on_error: Log-Auszug"
    assert_contains "$OUT" "--debug" "on_error: bash -x-Hinweis mit exaktem Befehl"
}

case_non_root() {
    # Läuft bewusst AUSSERHALB des unshare-NS (dort wäre man root):
    OUT=$(bash "$INSTALLER" < /dev/null 2>&1)
    RC=$?
    assert_eq "$RC" 1 "nicht-root → Exit 1"
    assert_contains "$OUT" "Bitte als root ausführen" "Root-Prüfung greift"
}

# ── NS-Runner (host-seitig) ────────────────────────────────────────────────
declare -A PRESETS=(
    [fresh_install]=fresh [id_skip]=occupied200 [dns_late]=fresh [dns_flaky]=fresh
    [dns_dead]=fresh [update_stopped]=existing-stopped [status_running]=status-running
    [status_stopped]=status-stopped [uninstall_yes]=uninstall [uninstall_confirm]=uninstall
    [dup_hostname]=dup [api_key]=fresh [version_pin]=fresh [help]=fresh
    [zero_fallback]=status-running [error_chain]=fresh
)
declare -A DNS_MODES=(
    [dns_late]=late [dns_flaky]=flaky4 [dns_dead]=dead
)
declare -A FAIL_CREATE=(
    [error_chain]=1
)

run_case() {
    local name="$1"
    local preset="${PRESETS[$name]:-fresh}"
    local state="$WORK/state-$name"
    rm -rf "$state"
    mkdir -p "$state"
    RESULTS_FILE="$WORK/results-$name.log"
    : > "$RESULTS_FILE"
    export HARNESS_STATE="$state" HARNESS_SRC_TARBALL="$WORK/src.tar.gz" \
        HARNESS_ASSETS="$ASSETS" RESULTS_FILE FAKEBIN_PATH="$FAKEBIN" \
        HARNESS_DNS_MODE="${DNS_MODES[$name]:-ok}" HARNESS_FAIL_CREATE="${FAIL_CREATE[$name]:-0}"

    if [[ "$name" == "non_root" ]]; then
        # Läuft bewusst ohne unshare (EUID bleibt unprivilegiert)
        "case_non_root"
    else
        unshare -rm bash "$SELF" --ns-setup --inner "$name" "$preset" < /dev/null
    fi

    # Ergebnis auswerten
    local o x
    o=$(grep -c '^OK' "$RESULTS_FILE" || true)
    x=$(grep -c '^FAIL' "$RESULTS_FILE" || true)
    if [[ "$x" -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo "  ✔ $name  ($o Assertions)"
    else
        FAIL=$((FAIL + 1))
        FAILED_CASES+=("$name")
        echo "  ✘ $name  ($x von $((o + x)) Assertions fehlgeschlagen)"
        grep '^FAIL' "$RESULTS_FILE" | sed 's/^/      /'
    fi
}

CASES=(
    fresh_install
    id_skip
    dns_late
    dns_flaky
    dns_dead
    update_stopped
    status_running
    status_stopped
    uninstall_yes
    uninstall_confirm
    dup_hostname
    api_key
    version_pin
    help
    zero_fallback
    error_chain
    non_root
)

cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── Inner-Dispatch: läuft INNERHALB des unshare-Mount-Namespace ────────────
# (Nach allen Funktionsdefinitionen, damit seed/case verfügbar sind.)
MODE="${1:-host}"
if [[ "$MODE" == "--ns-setup" || "$MODE" == "--inner" ]]; then
    if [[ "$MODE" == "--ns-setup" ]]; then
        shift
        mount --make-rprivate /
        mkdir -p /opt /root /usr/local/bin /var/log /etc/dhcp /etc/systemd/system
        mount -t tmpfs tmpfs /opt
        mount -t tmpfs tmpfs /root
        mount -t tmpfs tmpfs /usr/local/bin
        mount -t tmpfs tmpfs /var/log
        mount -t tmpfs tmpfs /etc/dhcp
        mount -t tmpfs tmpfs /etc/systemd/system
        RESOLV_SCRATCH="/tmp/claudecode-harness-resolv.$$"
        : > "$RESOLV_SCRATCH"
        mount --bind "$RESOLV_SCRATCH" /etc/resolv.conf
    fi
    shift  # --inner Flag ablegen
    CASE_NAME="${1:?Case-Name fehlt}"
    PRESET="${2:?Preset fehlt}"
    shift 2
    export PATH="$FAKEBIN:$PATH"
    seed_preset "$PRESET"
    "case_$CASE_NAME"
    exit 0
fi

# ── Main (host-seitig) ─────────────────────────────────────────────────────
mkdir -p "$WORK"

echo "🧪 ClaudeCode-Proxmox Mock-Harness"
echo "   Installer: $INSTALLER"

# Tarball-Fixture bauen (simuliert den codeload-Download des Repos).
# --owner=0/--group=0: GitHub-Tarballs gehören uid 0 – im User-Namespace
# wäre ein chown auf phil-uid (1000) unmöglich ("Invalid argument").
mkdir -p "$WORK/pkgroot/ClaudeCode-Proxmox-main"
cp -r "$REPO/app" "$WORK/pkgroot/ClaudeCode-Proxmox-main/app"
tar --owner=0 --group=0 -czf "$WORK/src.tar.gz" -C "$WORK/pkgroot" ClaudeCode-Proxmox-main

echo ""
SELECTED=("${CASES[@]}")
if [[ $# -gt 0 ]]; then
    SELECTED=("$@")
fi
for name in "${SELECTED[@]}"; do
    run_case "$name"
done

echo ""
echo "════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
    echo "✅ ALLE ${PASS} TESTS BESTANDEN"
    echo "════════════════════════════════════════"
    exit 0
else
    echo "❌ ${FAIL} von $((PASS + FAIL)) Tests fehlgeschlagen:"
    for c in "${FAILED_CASES[@]}"; do
        echo "   ✘ $c"
    done
    echo "════════════════════════════════════════"
    exit 1
fi
