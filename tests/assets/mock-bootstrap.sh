#!/usr/bin/env bash
# Mock: offizieller Claude-Code-Bootstrap (claude.ai/install.sh).
# Verhält sich grob wie das Original: nimmt eine Version entgegen und legt
# einen Launcher unter /root/.local/bin/claude an (den der Installer dann
# via command -v findet und nach /usr/local/bin symlinkt).
set -euo pipefail

TARGET="${1:-latest}"
echo "mock-bootstrap: installing Claude Code (${TARGET})"
echo "mock-bootstrap: verifying checksum (simuliert)"

mkdir -p /root/.local/bin
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

echo "mock-bootstrap: installed to /root/.local/bin/claude"
