#!/bin/bash
#
# install.sh — copies the script into ~/bin, generates the Karabiner rule with
# absolute paths, and scaffolds the config file.
#
# Karabiner does not expand ~ and runs shell commands with a minimal PATH,
# which is why the rule file needs absolute paths written in at install time.

set -euo pipefail

BIN="$HOME/bin"
CONFIG_DIR="$HOME/.config/quicknote"
KARABINER_DIR="$HOME/.config/karabiner/assets/complex_modifications"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$BIN" "$CONFIG_DIR" "$KARABINER_DIR"

install -m 755 "$SRC/quicknote.sh" "$BIN/quicknote.sh"
echo "Installed script to $BIN"

sed "s|__BIN__|$BIN|g" \
  "$SRC/karabiner/quicknote.json.template" \
  > "$KARABINER_DIR/quicknote.json"
echo "Wrote $KARABINER_DIR/quicknote.json"

if [ -f "$CONFIG_DIR/env" ]; then
  echo "Config already exists at $CONFIG_DIR/env — left untouched"
else
  cp "$SRC/env.example" "$CONFIG_DIR/env"
  chmod 600 "$CONFIG_DIR/env"
  echo "Created $CONFIG_DIR/env — edit it with your token and database ID"
fi

if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$KARABINER_DIR/quicknote.json" > /dev/null \
    && echo "Karabiner JSON validates"
fi

cat <<'DONE'

Remaining manual steps:
  1. Edit ~/.config/quicknote/env with your integration token and database ID
  2. In Notion: open the database, ... menu, Connections, connect the integration
  3. Karabiner-Elements, Complex Modifications, Add rule, enable what you want
  4. Test with: ~/bin/quicknote.sh
     (first run triggers a macOS automation permission prompt)
DONE
