#!/bin/bash
#
# quicknote.sh — quick capture
#
# Pops a dialog, appends the note to a local Markdown file, then pushes a row
# to a Notion database. The local write happens FIRST so a network failure or
# bad token can never lose a note.
#
# Return saves; Cmd+Return (via the Karabiner rule) or Option+Return (native)
# inserts a line break. Pasted multi-line text works too.

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

# Line breaks arrive as CR, LF, or CRLF depending on how they were typed or
# pasted; normalize them all to LF before anything looks at the text.
TEXT=${TEXT//$'\r\n'/$'\n'}
TEXT=${TEXT//$'\r'/$'\n'}

# A leading "todo" ("todo buy milk", "Todo: buy milk") or "link"
# ("link https://…") sets the Label property on the Notion row and is
# stripped from the note text.
LABEL=""
if [[ $TEXT =~ ^[Tt][Oo][Dd][Oo]:?[[:space:]]+(.*)$ ]]; then
  LABEL="Todo"
  TEXT=${BASH_REMATCH[1]}
elif [[ $TEXT =~ ^[Ll][Ii][Nn][Kk]:?[[:space:]]+(.*)$ ]]; then
  LABEL="Link"
  TEXT=${BASH_REMATCH[1]}
fi
[ -z "$TEXT" ] && exit 0

# --- Local copy first -------------------------------------------------------
mkdir -p "$(dirname "$NOTE_FILE")"
MARKER=""
case "$LABEL" in
  Todo) MARKER="TODO: " ;;
  Link) MARKER="LINK: " ;;
esac
# Continuation lines are indented so the file stays one list item per note.
printf -- '- [%s] %s%s\n' "$(date '+%Y-%m-%d %H:%M')" "$MARKER" "$TEXT" \
  | sed '2,$s/^/  /' >> "$NOTE_FILE"

# --- Notion -----------------------------------------------------------------
# Minimal JSON escaping: backslash, double-quote, and the control characters
# the dialog can actually produce (newlines via Option+Return or paste, tabs
# via paste). Escaping newlines also keeps each body on a single line, which
# the queue format depends on.
ESC=${TEXT//\\/\\\\}
ESC=${ESC//\"/\\\"}
ESC=${ESC//$'\n'/\\n}
ESC=${ESC//$'\t'/\\t}

PROPS="\"Note\":{\"rich_text\":[{\"text\":{\"content\":\"$ESC\"}}]}"
[ -n "$LABEL" ] && PROPS="$PROPS,\"Label\":{\"select\":{\"name\":\"$LABEL\"}}"

BODY="{\"parent\":{\"database_id\":\"$NOTION_DB\"},\"properties\":{$PROPS}}"

CONFIG_DIR=$(dirname "$CONFIG")
QUEUE="$CONFIG_DIR/queue.jsonl"

# POST one JSON body to Notion. Sets NOTION_ERROR to the response/curl message
# and returns:
#   0  success
#   1  transient failure — worth retrying, so queue it
#   2  permanent failure (Notion rejected the request) — retrying won't help
# Each body is a single line, which is what lets the queue be a plain .jsonl.
#
# Transport failures (offline, DNS, timeout) are told apart from HTTP failures
# by curl's exit status, not by scanning the body — Notion echoes the note text
# back on success, so a note containing "curl:" would otherwise be misread as a
# connection error. Among HTTP errors, 429/5xx are transient (rate limit, server
# hiccup) and stay queued; other 4xx are the request itself being rejected.
notion_post() {
  local resp rc http
  resp=$(/usr/bin/curl -sS -w '\n%{http_code}' -X POST https://api.notion.com/v1/pages \
    -H "Authorization: Bearer $NOTION_TOKEN" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    -d "$1" 2>&1)
  rc=$?
  NOTION_ERROR=$resp
  [ "$rc" -ne 0 ] && return 1          # curl could not complete the request
  http=${resp##*$'\n'}                 # -w appended the status as the last line
  case "$http" in
    2*)      return 0 ;;               # created
    429|5*)  return 1 ;;               # rate limited / server error — retry
    *)       return 2 ;;               # 4xx — permanent rejection
  esac
}

log_error() {  # $1 = message
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$CONFIG_DIR/error.log"
}

# Drain previously queued notes, oldest first. A transient failure stops the
# flush and keeps the note (plus everything behind it) for next time, so we
# don't hammer curl while still offline. A permanent rejection is dropped and
# logged rather than wedging the queue forever — it stays in the local file.
#
# Concurrency: two runs can overlap (a capture fires while a slow offline flush
# is draining). We claim the backlog with a single atomic rename, so exactly one
# run ever processes a given set of notes — no double-sends. The loser of the
# rename simply skips flushing. Unsent notes and concurrent captures are only
# ever *appended* back to the queue, never written over it, so nothing is lost.
flush_queue() {
  [ -s "$QUEUE" ] || return 0
  local work="$QUEUE.$$.flushing" line stalled=false rc
  # Same-directory rename is atomic; the run that wins owns $work exclusively,
  # and a fresh $QUEUE catches any captures that arrive mid-flush.
  mv "$QUEUE" "$work" 2>/dev/null || return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$stalled" = true ]; then
      printf '%s\n' "$line" >> "$QUEUE"
      continue
    fi
    notion_post "$line"; rc=$?
    case "$rc" in
      0) : ;;                                              # sent — drop it
      1) stalled=true; printf '%s\n' "$line" >> "$QUEUE" ;; # retry — requeue it
      2) log_error "dropped from queue: $NOTION_ERROR" ;;  # rejected — drop it
    esac
  done < "$work"
  rm -f "$work"
}

mkdir -p "$CONFIG_DIR"

# Flush the backlog first so notes reach Notion in capture order, then send the
# current note. Only transient failures are queued for retry; a rejection is
# handled as before (already safe in the local file, logged for inspection).
flush_queue
notion_post "$BODY"; RC=$?
case "$RC" in
  1)
    printf '%s\n' "$BODY" >> "$QUEUE"
    /usr/bin/osascript -e 'display notification "Saved locally + queued — will retry Notion" with title "Quick capture"'
    log_error "$NOTION_ERROR" ;;
  2)
    /usr/bin/osascript -e 'display notification "Saved locally only — Notion rejected the note" with title "Quick capture"'
    log_error "$NOTION_ERROR" ;;
esac
