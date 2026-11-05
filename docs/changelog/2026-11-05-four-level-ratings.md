# 2026-11-05: Four-level ratings (😊😊 / 😊 / ☹ / ☹☹)

## Summary

WowFriendly's rating is no longer a binary smile or frown. A player can now be tagged at one
of four levels: two smiles (very friendly), one smile (friendly), one frown (jerk) or two
frowns (big jerk). The report surfaces (tooltip summary line, `/wf who` chat output and the
`/wf list` window) show a count per level in that order, and every who-said-what line shows one
or two faces. The wire and export formats are unchanged apart from the wider value range, so
existing data and sync keep working. Version bumped to 0.2.0.

## Changes

### Features
- **Four rating levels** (`Ratings.lua`): `r` accepts `2, 1, -1, -2` (0 stays the tombstone).
  `Ratings.IsLevel` and `Ratings.MAX_LEVEL` define the range; `ValidateEntry` and `Set` use
  them. `Aggregate` returns `counts[level]` and keeps `happy`/`sad` as the totals of the two
  positive and two negative levels.
- **Shared formatting** (`Core.lua`): `ns.LEVELS` (display order `2, 1, -1, -2`) and
  `ns.LEVEL_INFO` (labels) in one place. `ns.IconFor` repeats the smile or frown icon once per
  point (capped at two). New `ns.LevelText` ("icons label") and `ns.SummaryText` (per-level
  counts in order, empty buckets skipped). `ns.Rate` rejects values outside the scale.
- **Report surfaces**: the tooltip summary, `/wf who`, incoming-rating chat messages and the
  list window's ratings column all go through `SummaryText` / `LevelText`.
- **Commands** (`Commands.lua`): `/wf veryhappy` (`happy2`, `++`) and `/wf verysad` (`sad2`,
  `--`); `+` and `-` as short forms of `happy` and `sad`; usage text updated.
- **Keybindings** (`Bindings.xml`, `Commands.lua`): "Two smiles" and "Two frowns at mouseover /
  target" alongside the existing two; `WowFriendly_Bind` maps actions through a table.
- **Right-click menu** (`Menu.lua`): four buttons, top to bottom 😊😊 Very friendly, 😊 Friendly,
  ☹ Jerk, ☹☹ Big jerk, built from `ns.LEVELS`.
- **List window** (`UI/List.lua`): ratings column widened to 150 px for four double-icon
  buckets, frame widened to 690, columns driven by constants, and one header font string per
  column anchored at the column offsets.

### Tests
- `tests/run.lua`: 55 new assertions (212 total) covering level validation, per-level
  aggregate counts, equal-time tie-break ordering, the new commands, aliases and bindings,
  `/wf who` output, the formatting helpers, and two-face ratings travelling over Battle.net
  with the same payload size and showing two faces in the receiver's chat. The old
  "reject bad rating value" assertion now uses `3` instead of `2`.

### Documentation
- `README.md`: rating table, tooltip example, command list and in-game checklist updated;
  note that friends on 0.1.0 keep syncing but do not see two-face ratings until they update.
- `WowFriendly.toc`: version 0.2.0, notes line mentions the four levels.
- `.luacheckrc`: new binding-name globals.

## Files

| Path | Description |
| --- | --- |
| `WowFriendly/Ratings.lua` | Level range, validation, per-level aggregate counts |
| `WowFriendly/Core.lua` | Level table, `IconFor`, `LevelText`, `SummaryText`, `Rate` guard, `Who` summary |
| `WowFriendly/Tooltip.lua` | Four-bucket summary line |
| `WowFriendly/UI/List.lua` | Wider ratings column, column constants, per-column headers |
| `WowFriendly/Comms.lua` | Incoming-rating chat label via `LevelText`; protocol comment |
| `WowFriendly/Commands.lua` | New subcommands and aliases, usage text, bindings table |
| `WowFriendly/Menu.lua` | Four-level submenu, note hint |
| `WowFriendly/Bindings.xml` | Two extra bindings |
| `WowFriendly/WowFriendly.toc` | Version 0.2.0 |
| `tests/run.lua` | New assertions |
| `README.md`, `.luacheckrc` | Docs and lint globals |

## Rationale

The request was to report two happy faces, one happy face, one sad face and two sad faces. A
report can only show strength if the rating carries it, so the integer rating was widened to
±2 and rendered by repeating the existing icon. This is additive on the saved-variables, wire
and export formats: no migration, no new art, and 0.1.0 clients degrade gracefully (they skip
`±2` entries per entry rather than refusing to sync, which a protocol version bump would have
caused). Existing `±1` ratings become the one-face levels. Labels and order live in one table
so the tooltip, list, chat and menu cannot drift apart.
