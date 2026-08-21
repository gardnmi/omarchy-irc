#!/bin/bash

set -euo pipefail

plugin_dir="$HOME/.config/omarchy/plugins/io.github.gardnmi.omarchy-irc"
session_omarchy_path="${OMARCHY_PATH:-/usr/share/omarchy}"
shell_dir="$session_omarchy_path/shell"

[[ -f $shell_dir/shell.qml ]] || { echo "Omarchy shell config not found: $shell_dir" >&2; exit 1; }

while timeout 5 quickshell kill -p "$shell_dir" --any-display >/dev/null 2>&1; do :; done

install -d "$plugin_dir"
install -m 644 Panel.qml irc_helper.py README.md manifest.json "$plugin_dir/"

omarchy restart shell
