#!/usr/bin/env bash
# Mock: ttyd 1.7.7 – verhält sich wie das echte Binary:
# ohne Argument → Usage auf stderr + Exit 1.
cat >&2 <<'USAGE'
ttyd version 1.7.7
USAGE
exit 1