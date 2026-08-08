#!/bin/bash
#
# quicknote.sh — single-line capture
#
# Pops a dialog, appends the note to a local Markdown file, then pushes a row
# to a Notion database. The local write happens FIRST so a network failure or
# bad token can never lose a note.

set -uo pipefail

CONFIG="${QUICKNOTE_CONFIG:-$HOME/.config/quicknote/env}"
NOTE_FILE="${QUICKNOTE_FILE:-$HOME/Notes/inbox.md}"

if [ ! -r "$CONFIG" ]; then
  /usr/bin/osascript -e 'display notification "Missing config file" with title "Quick capture"'
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

TEXT=$(/usr/bin/osascript \
  -e 'tell application "System Events" to activate' \
  -e 'tell application "System Events" to text returned of (display dialog "Note:" default answer "" with title "Quick capture" buttons {"Cancel","Save"} default button "Save")' \
  2>/dev/null)
STATUS=$?

# Cancel button or Esc
[ $STATUS -ne 0 ] && exit 0
# Saved but empty
[ -z "$TEXT" ] && exit 0

# A leading "todo" ("todo buy milk", "Todo: buy milk") sets the Label
# property to Todo on the Notion row and is stripped from the note text.
TODO=false
if [[ $TEXT =~ ^[Tt][Oo][Dd][Oo]:?[[:space:]]+(.*)$ ]]; then
  TODO=true
  TEXT=${BASH_REMATCH[1]}
  [ -z "$TEXT" ] && exit 0
fi

# --- Local copy first -------------------------------------------------------
mkdir -p "$(dirname "$NOTE_FILE")"
MARKER=""
[ "$TODO" = true ] && MARKER="TODO: "
printf -- '- [%s] %s%s\n' "$(date '+%Y-%m-%d %H:%M')" "$MARKER" "$TEXT" >> "$NOTE_FILE"

# --- Notion -----------------------------------------------------------------
# Minimal JSON escaping. A single-line dialog cannot produce newlines or
# control characters, so backslash and double-quote are the only cases.
ESC=${TEXT//\\/\\\\}
ESC=${ESC//\"/\\\"}

PROPS="\"Note\":{\"rich_text\":[{\"text\":{\"content\":\"$ESC\"}}]}"
[ "$TODO" = true ] && PROPS="$PROPS,\"Label\":{\"select\":{\"name\":\"Todo\"}}"

RESPONSE=$(/usr/bin/curl -sS -X POST https://api.notion.com/v1/pages \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d "{\"parent\":{\"database_id\":\"$NOTION_DB\"},\"properties\":{$PROPS}}" 2>&1)

case "$RESPONSE" in
  *'"object":"error"'*|*curl:*)
    /usr/bin/osascript -e 'display notification "Saved locally only — Notion sync failed" with title "Quick capture"'
    mkdir -p "$(dirname "$CONFIG")"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RESPONSE" >> "$(dirname "$CONFIG")/error.log"
    ;;
esac
