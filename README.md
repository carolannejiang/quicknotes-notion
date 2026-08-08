# quicknote

Press a key anywhere on macOS, type a note, and it lands in a plain-text file
*and* a Notion database with an automatic timestamp.

No menu bar app, no background daemon, no Electron. A key trigger, a shell
script, and one HTTP request.

```
F3  ──▶  Karabiner-Elements  ──▶  quicknote.sh  ──┬──▶  ~/Notes/inbox.md
                                                  └──▶  Notion API
```

## Why

Capture friction is the thing that kills note habits. Opening an app, waiting
for a window, finding the right page, and clicking into a text field is enough
overhead that you stop bothering. This is one keypress to a focused text field,
Enter to save, back to what you were doing.

## Requirements

- macOS
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/)
- A Notion account (optional — omit the config and it still writes locally)

## Install

```bash
git clone <this-repo> quicknote
cd quicknote
./install.sh
```

The installer copies the script to `~/bin`, generates the Karabiner rule with
absolute paths substituted in, and scaffolds `~/.config/quicknote/env` at mode
`600`.

### Notion setup

1. **Create an integration** at
   [notion.so/profile/integrations](https://www.notion.so/profile/integrations).
   Type: Internal. The only capability it needs is **Insert content**. Copy the
   Internal Integration Secret (starts with `ntn_`).

2. **Create a database** with these properties — names are case-sensitive and
   must match exactly:

   | Property   | Type         | Notes                                    |
   |------------|--------------|------------------------------------------|
   | *(title)*  | Title        | Left empty; Notion requires one          |
   | `Note`     | Text         | Where the note text goes                 |
   | `Captured` | Created time | Auto-stamped; the script sends no date   |
   | `Processed`| Checkbox     | Optional, for triage                     |
   | `Label`    | Select       | Gets a `Todo` tag when a note starts with `todo` |

3. **Connect the integration to the database.** Open it → `⋯` → Connections →
   Connect to → select your integration. **This step is the most common point
   of failure** — skipping it produces a "could not find database" error even
   when the ID is correct.

4. **Fill in the config:**

   ```bash
   $EDITOR ~/.config/quicknote/env
   ```

5. **Enable the rule** in Karabiner-Elements → Complex Modifications → Add rule.

### Default bindings

| Key | Script | Behaviour |
|-----|--------|-----------|
| `F3` | `quicknote.sh` | Single-line dialog. Enter saves. |
| Right `⌘` tap | `quicknote.sh` | Still a normal modifier when held. |

Both rules are independent — enable only what you want. F3 is Mission
Control by default; that remains reachable via `Ctrl+↑` or a three-finger swipe.

### Todo prefix

Start a note with `todo` (case-insensitive, optional colon) to tag the Notion
row with the `Todo` label. The prefix is stripped from the note text; the
local file line is marked `TODO:` instead.

```
todo buy milk    →  Note: "buy milk", Label: Todo
Todo: call Sam   →  Note: "call Sam", Label: Todo
```

Requires a `Label` select property on the database (the `Todo` option is
created automatically on first use) — without it, Notion rejects the request
and the note is saved locally only.

## Design decisions

**Local write happens before the network call.** A dead connection, an expired
token, or a Notion outage can never lose a note. Failures produce a macOS
notification and an entry in `error.log`; the note is already safe on disk.

**The API version is pinned to `2022-06-28`.** Versions from `2025-09-03`
onward restructured how a page's parent is specified, moving from a plain
`database_id` to data sources. Pinning keeps the request body stable. Upgrading
means rewriting the `parent` object.

**Timestamps come from Notion, not the script.** `Captured` is a `created_time`
property, so there is no clock-skew or format mismatch between the two sinks,
and no timezone handling in bash. Trade-off: created time is read-only, so
notes can't be backdated. Add an editable `Date` property if you need that.

**Notes go in a text property, not the title.** Titles don't render line breaks
and read poorly in a table view. The title stays empty. Notion mandates exactly
one title property and won't let you hide it in a table view, so expect a thin
"Untitled" gutter column — drag it narrow.

**Single-line dialog by design.** Enter saves rather than inserting a newline.
That's what makes capture fast.

**Absolute paths everywhere.** Karabiner runs shell commands with a minimal
`PATH` and does not expand `~`, which is why `install.sh` substitutes them
rather than shipping a ready-made JSON.

**JSON escaping is done inline, not with `jq`.** Keeps the dependency list at
zero. A single-line dialog can't produce newlines or control characters, so
backslash and double-quote are the only cases that matter.

## Configuration

The script honours two environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `QUICKNOTE_CONFIG` | `~/.config/quicknote/env` | Path to the config file |
| `QUICKNOTE_FILE` | `~/Notes/inbox.md` | Local capture file |

`~/Notes` is only backed up if your home folder is. To sync, point
`QUICKNOTE_FILE` at iCloud Drive:
`$HOME/Library/Mobile Documents/com~apple~CloudDocs/inbox.md`

## Reading notes back

```bash
tail -20 ~/Notes/inbox.md
grep -i "keyword" ~/Notes/inbox.md
open ~/Notes
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| "Saved locally only" notification | Check `~/.config/quicknote/error.log`. Usually the missing Connections step. |
| Nothing happens on keypress | Open Karabiner's EventViewer, press the key, confirm the reported `key_code` matches the rule. |
| Rule missing from Karabiner | Malformed JSON: `python3 -m json.tool ~/.config/karabiner/assets/complex_modifications/quicknote.json` |
| Script hangs, no prompt returns | The dialog opened behind another window. `Ctrl+C` to escape. |
| No dialog on first run | macOS automation permission prompt is pending; allow it, then run again. |
| Notion shows date but no time | Edit the `Captured` property and set a Time format. |

## Security

`~/.config/quicknote/env` holds a token with write access to your workspace.
It is created mode `600` and `.gitignore` excludes `env`. Don't commit it, and
don't paste it into a chat or issue. If it leaks, revoke the integration at
notion.so/profile/integrations and create a new one.

## License

MIT
