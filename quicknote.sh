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

# A leading "todo" ("todo buy milk", "Todo: buy milk"), "link"
# ("link https://…"), or "anki" ("anki capital of France") sets the Label
# property on the Notion row and is stripped from the note text.
#
# A leading "j" ("j had a good walk", "J: slept badly") is a journal entry:
# instead of a Quick Notes row it is appended, with the time it was written,
# to today's page in the journal database (created on first entry of the day).
LABEL=""
if [[ $TEXT =~ ^[Jj]:?[[:space:]]+(.*)$ ]]; then
  LABEL="Journal"
  TEXT=${BASH_REMATCH[1]}
elif [[ $TEXT =~ ^[Tt][Oo][Dd][Oo]:?[[:space:]]+(.*)$ ]]; then
  LABEL="Todo"
  TEXT=${BASH_REMATCH[1]}
elif [[ $TEXT =~ ^[Ll][Ii][Nn][Kk]:?[[:space:]]+(.*)$ ]]; then
  LABEL="Link"
  TEXT=${BASH_REMATCH[1]}
elif [[ $TEXT =~ ^[Aa][Nn][Kk][Ii]:?[[:space:]]+(.*)$ ]]; then
  LABEL="Anki"
  TEXT=${BASH_REMATCH[1]}
fi
[ -z "$TEXT" ] && exit 0

# --- Local copy first -------------------------------------------------------
mkdir -p "$(dirname "$NOTE_FILE")"
MARKER=""
case "$LABEL" in
  Todo) MARKER="TODO: " ;;
  Link) MARKER="LINK: " ;;
  Anki) MARKER="ANKI: " ;;
  Journal) MARKER="JOURNAL: " ;;
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

if [ "$LABEL" = Journal ]; then
  # Journal entries are queued as "journal<TAB>date<TAB>time<TAB>text" rather
  # than a ready-made request body, because the body depends on the ID of
  # that day's page, which may not exist yet (or be reachable) at queue time.
  BODY="journal	$(date '+%Y-%m-%d')	$(date '+%H:%M')	$ESC"
else
  PROPS="\"Note\":{\"rich_text\":[{\"text\":{\"content\":\"$ESC\"}}]}"
  [ -n "$LABEL" ] && PROPS="$PROPS,\"Label\":{\"select\":{\"name\":\"$LABEL\"}}"
  BODY="{\"parent\":{\"database_id\":\"$NOTION_DB\"},\"properties\":{$PROPS}}"
fi

CONFIG_DIR=$(dirname "$CONFIG")
QUEUE="$CONFIG_DIR/queue.jsonl"

# Send one JSON body to Notion: notion_call METHOD PATH BODY. Sets
# NOTION_ERROR to the response/curl message (NOTION_RESP to the response
# alone) and returns:
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
notion_call() {
  local resp rc http
  resp=$(/usr/bin/curl -sS -w '\n%{http_code}' -X "$1" "https://api.notion.com/v1/$2" \
    -H "Authorization: Bearer $NOTION_TOKEN" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    -d "$3" 2>&1)
  rc=$?
  NOTION_ERROR=$resp
  [ "$rc" -ne 0 ] && return 1          # curl could not complete the request
  http=${resp##*$'\n'}                 # -w appended the status as the last line
  NOTION_RESP=${resp%$'\n'*}
  case "$http" in
    2*)      return 0 ;;               # created
    429|5*)  return 1 ;;               # rate limited / server error — retry
    *)       return 2 ;;               # 4xx — permanent rejection
  esac
}

# Return (in JOURNAL_PAGE) the ID of the journal page whose Date is $1
# (YYYY-MM-DD), creating it if there is none. The title is a live @date
# mention (the same thing typing "@today" in Notion inserts), not plain text. The last lookup is cached in
# $CONFIG_DIR/journal-page as "date<TAB>id" so the usual path is a single
# request. Same return codes as notion_call.
journal_page() {
  local cache="$CONFIG_DIR/journal-page" cached
  cached=$(cat "$cache" 2>/dev/null)
  if [ "${cached%%	*}" = "$1" ]; then
    JOURNAL_PAGE=${cached#*	}
    return 0
  fi
  notion_call POST "databases/$NOTION_JOURNAL_DB/query" \
    "{\"filter\":{\"property\":\"Date\",\"date\":{\"equals\":\"$1\"}},\"page_size\":1}" || return $?
  JOURNAL_PAGE=$(printf '%s' "$NOTION_RESP" | /usr/bin/grep -o '"id":"[^"]*"' | /usr/bin/head -1 | /usr/bin/cut -d'"' -f4)
  if [ -z "$JOURNAL_PAGE" ]; then
    notion_call POST pages \
      "{\"parent\":{\"database_id\":\"$NOTION_JOURNAL_DB\"},\"properties\":{\"Name\":{\"title\":[{\"type\":\"mention\",\"mention\":{\"type\":\"date\",\"date\":{\"start\":\"$1\"}}}]},\"Date\":{\"date\":{\"start\":\"$1\"}}}}" || return $?
    JOURNAL_PAGE=$(printf '%s' "$NOTION_RESP" | /usr/bin/grep -o '"id":"[^"]*"' | /usr/bin/head -1 | /usr/bin/cut -d'"' -f4)
    [ -z "$JOURNAL_PAGE" ] && return 2
  fi
  printf '%s\t%s\n' "$1" "$JOURNAL_PAGE" > "$cache"
}

# Send one queue line, either a Quick Notes row body or a journal entry
# ("journal<TAB>date<TAB>time<TAB>text"). Journal entries are appended to
# that day's page as a paragraph with the time in bold.
notion_send() {
  local date time text
  case "$1" in
    "journal	"*)
      if [ -z "${NOTION_JOURNAL_DB:-}" ]; then
        NOTION_ERROR="NOTION_JOURNAL_DB is not set in $CONFIG"; return 2
      fi
      IFS='	' read -r _ date time text <<< "$1"
      journal_page "$date" || return $?
      notion_call PATCH "blocks/$JOURNAL_PAGE/children" \
        "{\"children\":[{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[{\"text\":{\"content\":\"$time  \"},\"annotations\":{\"bold\":true}},{\"text\":{\"content\":\"$text\"}}]}}]}" ;;
    *) notion_call POST pages "$1" ;;
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
    notion_send "$line"; rc=$?
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
notion_send "$BODY"; RC=$?
case "$RC" in
  1)
    printf '%s\n' "$BODY" >> "$QUEUE"
    /usr/bin/osascript -e 'display notification "Saved locally + queued — will retry Notion" with title "Quick capture"'
    log_error "$NOTION_ERROR" ;;
  2)
    /usr/bin/osascript -e 'display notification "Saved locally only — Notion rejected the note" with title "Quick capture"'
    log_error "$NOTION_ERROR" ;;
esac
