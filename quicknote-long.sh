#!/bin/bash
#
# quicknote-long.sh — multi-line capture
#
# Opens a blank scratch file in its own TextEdit instance and blocks until you
# quit it (Cmd+S then Cmd+Q). First non-blank line becomes the Note property;
# the remainder becomes paragraph blocks in the page body, which sidesteps the
# 2000-character limit on a rich_text property.

set -uo pipefail

CONFIG="${QUICKNOTE_CONFIG:-$HOME/.config/quicknote/env}"
NOTE_FILE="${QUICKNOTE_FILE:-$HOME/Notes/inbox.md}"

if [ ! -r "$CONFIG" ]; then
  /usr/bin/osascript -e 'display notification "Missing config file" with title "Quick capture"'
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

SCRATCH=$(mktemp -d)
TMP="$SCRATCH/note.txt"
: > "$TMP"

# Force plain-text mode so the note can't fill with RTF markup. App-wide
# default: new TextEdit documents elsewhere become plain text too.
/usr/bin/defaults write com.apple.TextEdit RichText -bool false

# -n forces a new instance, -W blocks until that instance quits
/usr/bin/open -a TextEdit -n -W "$TMP"

CONTENT=$(cat "$TMP")
rm -rf "$SCRATCH"
[ -z "$CONTENT" ] && exit 0

SUMMARY=$(printf '%s' "$CONTENT" | sed -n '/[^[:space:]]/{p;q;}')
BODY=$(printf '%s' "$CONTENT" | sed '1,/[^[:space:]]/d')

# A leading "todo" on the first line ("todo buy milk", "Todo: buy milk")
# checks the Todo property on the Notion row and is stripped from the summary.
TODO=false
if [[ $SUMMARY =~ ^[Tt][Oo][Dd][Oo]:?[[:space:]]+(.*)$ ]]; then
  TODO=true
  SUMMARY=${BASH_REMATCH[1]}
fi

# --- Local copy first -------------------------------------------------------
mkdir -p "$(dirname "$NOTE_FILE")"
MARKER=""
[ "$TODO" = true ] && MARKER="TODO: "
{
  printf -- '- [%s] %s%s\n' "$(date '+%Y-%m-%d %H:%M')" "$MARKER" "$SUMMARY"
  [ -n "$BODY" ] && printf '%s\n' "$BODY" | sed 's/^/  /'
} >> "$NOTE_FILE"

# --- Notion -----------------------------------------------------------------
esc() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

BLOCKS=""
if [ -n "$BODY" ]; then
  while IFS= read -r line; do
    if [ -z "$line" ]; then
      BLOCKS="$BLOCKS{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[]}},"
    else
      BLOCKS="$BLOCKS{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[{\"type\":\"text\",\"text\":{\"content\":\"$(esc "$line")\"}}]}},"
    fi
  done <<< "$BODY"
  BLOCKS=${BLOCKS%,}
fi

PROPS="\"Note\":{\"rich_text\":[{\"text\":{\"content\":\"$(esc "$SUMMARY")\"}}]}"
[ "$TODO" = true ] && PROPS="$PROPS,\"Todo\":{\"checkbox\":true}"

RESPONSE=$(/usr/bin/curl -sS -X POST https://api.notion.com/v1/pages \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d "{\"parent\":{\"database_id\":\"$NOTION_DB\"},\"properties\":{$PROPS},\"children\":[$BLOCKS]}" 2>&1)

case "$RESPONSE" in
  *'"object":"error"'*|*curl:*)
    /usr/bin/osascript -e 'display notification "Saved locally only — Notion sync failed" with title "Quick capture"'
    mkdir -p "$(dirname "$CONFIG")"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RESPONSE" >> "$(dirname "$CONFIG")/error.log"
    ;;
esac
