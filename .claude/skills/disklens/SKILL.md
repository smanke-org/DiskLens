---
name: disklens
description: Drive DiskLens, the disk space app on this Mac, from the shell with the `disklens` command: scan a folder or drive, list the biggest items and the Cleanup Suggestions with their safety labels, fill the Trash list, and move items to the Finder Trash. Use when the user asks what is filling their disk, wants space freed, asks whether something is safe to delete, or names DiskLens.
---

# DiskLens

`disklens` runs commands in the DiskLens app. Changes show in its window at once.
If the app is closed, the command opens it in the background. If `disklens` isn't on PATH, use
`/Applications/DiskLens.app/Contents/MacOS/DiskLens` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- Scan first. Commands about items answer for the folder chosen in the sidebar;
  `not_scanned` means run `disklens scan start <folder>`, then `disklens scan status --wait 25`
  until `phase` is `ready`. Scanning a whole home folder or drive can take minutes.
- Items are named by their full path. Every item has a `safety` label: `safe` (rebuilt or
  downloaded again), `user` (the person's own files), `caution` (app or system data) or
  `protected` (never moved). Tell the user the label and `safetyReason` before suggesting a removal.
- `trash move` only reports what it would move. Show the user that report and ask before you
  run it again with `--yes`. Items labeled `caution` also need `--caution-ok`: only add it after
  the user agreed to that item. Never try to get around a refusal for a protected item.
- Nothing is deleted outright: items go to the Finder Trash, and the space is freed when the
  user empties it. Never empty the Trash for them.
- Paths may be relative in the shell; over MCP they must be absolute.
- To try something without real data, run a Debug build with `APP_STORE=/tmp/disklens-test` in front.

## Main commands

| Command | Does |
| --- | --- |
| `disklens status --json` | Version, folder chosen, scan phase and totals, Trash list, free space |
| `disklens scan start [<folder>] [--full] --json` / `disklens scan status --wait 25 --json` | Scan, then wait for it |
| `disklens items list [<folder>] --json` / `disklens items largest [--under F] [--min-mb N] --json` | Biggest items in a folder / anywhere under it |
| `disklens items show <path> --json` | One item: size, dates, safety label and why |
| `disklens suggestions list --json` / `disklens suggestions show <id> --json` | Cleanup Suggestions and their items |
| `disklens trash add <path> --json` / `disklens trash list --json` | Put items on the Trash list / review it |
| `disklens trash move [<path>] [--caution-ok] [--yes] --json` | Move one item, or the Trash list, to the Trash |

Everything else: `disklens help`, and `disklens help <command>` for its options.
