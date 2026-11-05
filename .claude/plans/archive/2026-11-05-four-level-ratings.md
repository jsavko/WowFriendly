---
status: completed
---
# Four-level ratings: 😊😊 / 😊 / ☹ / ☹☹

**Date:** 2026-11-05

---

## Goal

Replace the binary smile/frown rating with a four-level scale so a player can be tagged as
**very friendly (two happy faces)**, **friendly (one happy face)**, **jerk (one sad face)** or
**big jerk (two sad faces)**. The "report" (the tooltip summary line, the `/wf who` chat
output and the `/wf list` window) must show those four buckets, in that order, instead of the
current two counts (`😊 1  ☹ 1`), and each who-said-what line must show one or two faces.

To report two faces a rating has to *carry* a strength, so the change spans the whole addon:

- **Store** (`Ratings.lua`): `r` becomes `2 | 1 | -1 | -2 | 0` (0 stays the tombstone).
  Aggregates expose a count per level.
- **Report**: tooltip summary, `/wf who`, the list window's ratings column, and all per-author
  lines render one icon per point (`😊😊`, `😊`, `☹`, `☹☹`).
- **Input**: slash commands, the right-click submenu and keybindings get the two new levels.
- **Sync / export**: the wire and export formats already carry `r` as an integer, so only
  validation changes. Existing saved ratings (`±1`) keep their meaning as the one-face levels.

Interpretation of the request (stated assumption): "update the report to 2 happy face,
1 happy face, 1 sad face, 2 sad face" means a four-step rating scale rendered with repeated
face icons, not four separate icon images and not a display-only change. The tooltip order
follows the request: `😊😊`, `😊`, `☹`, `☹☹`.

## Approaches Considered

### 1. Widen the integer rating to ±2 and repeat the existing icon per point
- **Description:** Keep `r` as one integer but allow `2, 1, -1, -2, 0`. `ns.IconFor(r)`
  returns the smile or frown texture repeated `|r|` times. One table in `Core.lua` maps each
  level to its icon string, chat label and menu label; every reader (tooltip, list, `/wf who`,
  rate confirmations, incoming-rating messages) goes through it. `Aggregate` adds a
  `counts[level]` table and keeps `happy`/`sad` as the totals of the positive and negative
  levels. Commands: `veryhappy`/`verysad` (with `++`, `+`, `-`, `--` and `happy2`/`sad2`
  aliases); menu: four buttons; bindings: two more.
- **Pros:** Smallest change to the data model and the wire format (additive range on an
  existing field). No new art. `Wins` tie-break (`a.r > b.r`) stays deterministic. Existing
  saved variables need no migration. All display code shares one formatter so the report is
  consistent everywhere.
- **Cons:** A 0.1.0 client receiving a `±2` entry rejects it as "bad rating" and never shows
  it (it still accepts `±1` entries and everything else keeps working). Double icons widen the
  list window's ratings column.

### 2. Keep `r` binary and add a separate strength field (`s = 1 | 2`)
- **Description:** Entries become `{ r = ±1, s = 1|2, t, n }`. Old clients ignore `s` and
  see every strong rating as a plain smile/frown.
- **Pros:** Full backwards compatibility with 0.1.0 clients.
- **Cons:** Two fields to validate, merge, tie-break and ship for one concept; every reader
  combines them; `Wins` needs a second tie-break; export/wire payloads grow. The 0.1.0 release
  is hours old, so compatibility with it is not worth the permanent complexity.

### 3. Four distinct icon textures (grin, smile, frown, angry)
- **Description:** Extend `scripts/make_icons.py` to draw two more faces and show a single
  glyph per level.
- **Pros:** Narrow badges in the tooltip and list; more expressive faces.
- **Cons:** The request literally asks for two faces; new art plus four texture paths is extra
  work and review; can be layered on approach 1 later by changing one table.

### 4. Display-only: show two faces when two or more friends agree, keep storage binary
- **Description:** Leave `r` as `±1` and render `😊😊` on the tooltip when the happy count
  is at least 2.
- **Pros:** No model, protocol or input changes.
- **Cons:** A single user cannot express "very friendly" or "big jerk", and the summary would
  no longer show counts. Does not match the four-bucket report the request describes.

## Chosen Approach

**Approach 1.** It is the direct reading of the request, additive on every format, needs no
migration or art, and centralises labelling in one table so the tooltip, list, chat and menu
cannot drift apart. Compatibility decision: keep `PROTOCOL_VERSION = 1` and `DB_VERSION = 1`.
The change is a wider range on an existing integer field; 0.1.0 peers drop `±2` entries
per-entry (logged as skipped) instead of refusing to sync at all, which is what a version bump
would cause via the HELLO check. README tells people to update to see strong ratings.
Bump the addon `## Version` to `0.2.0` so the release zip is distinguishable.

Labels (one table, easy to re-word): `+2` "very friendly", `+1` "friendly", `-1` "jerk",
`-2` "big jerk". Menu buttons show the icon(s) followed by that label.

## Tasks

### Store
- [x] `Ratings.lua`: update the header comment; add `Ratings.MAX_LEVEL = 2` and `Ratings.IsLevel(r)` (true for `2, 1, -1, -2`); `ValidateEntry` accepts `r` when `IsLevel(r)` or `r == 0`; `Ratings.Set` asserts `IsLevel(value)`.
- [x] `Ratings.Aggregate`: add `counts = { [2]=0, [1]=0, [-1]=0, [-2]=0 }` filled per entry; keep `happy` = `counts[2] + counts[1]` and `sad` = `counts[-1] + counts[-2]`; entries and `newest` unchanged.

### Shared formatting (Core.lua)
- [x] Add `ns.LEVELS` (ordered list `{ 2, 1, -1, -2 }`) and `ns.LEVEL_INFO[level] = { label = ... }` with the labels from the chosen approach.
- [x] Change `ns.IconFor(value)` to return `string.rep(icon, math.abs(value))` (smile for positive, frown for negative, `""` for 0 or nil).
- [x] Add `ns.LevelText(value)` returning `IconFor(value) .. " " .. label` and `ns.SummaryText(agg, sep)` that walks `ns.LEVELS` in order and joins `IconFor(level) .. " " .. count` for non-zero buckets with `sep`.
- [x] `ns.Rate`: reject values that are not `0` or a level with a printed message; replace the `value == 1 and ... or ...` label with `ns.LevelText(value)`; update the `SetNote` hint to mention the new commands.
- [x] `ns.Who`: print `key .. ": " .. ns.SummaryText(agg, "  ")`; per-author lines already use `IconFor`.

### Report surfaces
- [x] `Tooltip.lua`: build the summary line with `ns.SummaryText(agg, "   ")` (order `😊😊`, `😊`, `☹`, `☹☹`); author lines unchanged (they use `IconFor`).
- [x] `UI/List.lua`: ratings column uses `ns.SummaryText(agg, " ")`; widen `row.icons` from 62 to 130, shift `row.name` LEFT from 70 to 138 and `row.info` LEFT from 236 to 304, widen the frame from 600 to 670, and re-space the header string so the column titles still line up; `content` fallback width from 540 to 610. *(Done with column constants: ratings column 150 wide, name at 158, info at 324, frame 690; headers are now one font string per column anchored at the column offsets instead of a spaced string. See Notes.)*
- [x] `Comms.lua` `OnRate`: replace the `e.r == 1 and ... or ...` label with `ns.LevelText(e.r)`; update the protocol comment to say `r` is `-2..2`.

### Input
- [x] `Commands.lua`: add handlers `veryhappy` (aliases `happy2`, `++`) rating `+2` and `verysad` (aliases `sad2`, `--`) rating `-2`; add `+` and `-` as aliases for `happy` and `sad`; update `USAGE` lines and the `resolveKey` usage hint.
- [x] `Commands.lua` `WowFriendly_Bind`: handle `"smile2"` (`+2`) and `"frown2"` (`-2`); add `BINDING_NAME_WOWFRIENDLY_SMILE2 = "Two smiles at mouseover / target"` and `BINDING_NAME_WOWFRIENDLY_FROWN2 = "Two frowns at mouseover / target"`.
- [x] `Bindings.xml`: add `WOWFRIENDLY_SMILE2` and `WOWFRIENDLY_FROWN2` bindings calling `WowFriendly_Bind("smile2")` / `WowFriendly_Bind("frown2")`.
- [x] `Menu.lua` `BuildMenu`: replace the Smile/Frown buttons with four buttons, top to bottom `+2, +1, -1, -2`, each labelled `ns.LevelText(level)` and calling `ns.Rate(key, level)`; update the `PromptNote` hint text. *(Menu labels capitalise the first letter of the chat label.)*
- [x] `.luacheckrc`: add the two new `BINDING_NAME_*` globals.

### Tests (`tests/run.lua`)
- [x] Ratings section: `Set` with `2` and `-2` stores the value; `ValidateEntry` accepts `±2` and rejects `3`, `-3`, `1.5`; `Aggregate` with one author per level reports `counts[2]`, `counts[1]`, `counts[-1]`, `counts[-2]` all `1` and `happy == 2`, `sad == 2`; `Wins` with equal time prefers `2` over `1`. *(The old "reject bad rating value" assertion used `r = 2`; it now uses `r = 3`.)*
- [x] Commands section: `/wf veryhappy Arthas Menethil: carried us` stores `r == 2` with the note; `/wf -- Arthas Menethil` stores `-2`; `/wf + ` and `/wf -` on a target store `±1`; `WowFriendly_Bind("smile2")` on a mouseover stores `2`; `/wf who` output contains the double icon for a `±2` entry.
- [x] Core helpers: `ns.IconFor(2)` is the smile texture twice, `ns.IconFor(-2)` the frown twice, `ns.IconFor(0) == ""`; `ns.SummaryText` omits zero buckets and keeps the `2, 1, -1, -2` order.
- [x] Sync section: a `+2` rating with a 100-character note round-trips over Battle.net (fits 255 bytes) and arrives at the peer with `r == 2`; a `-2` live `RATE` reaches the peer and its chat message contains the double frown. *(Also asserts the single-entry wire size for `±2` is within 2 bytes of `±1`.)*
- [x] Run `scripts/check.sh` (syntax check plus tests) and confirm it passes with the new assertions. *(212 passed, 0 failed.)*

### Docs and release
- [x] `README.md`: rewrite the "Rating players" table for four levels (menu entries, bindings, commands including `++`/`--`), change the tooltip example from `😊 1  ☹ 1` to the four-bucket form, update the "All commands" block, add a line that friends on 0.1.0 do not see two-face ratings until they update, and update in-game checklist step 3 to try a two-face rating.
- [x] `WowFriendly.toc`: bump `## Version` to `0.2.0` and mention the four levels in `## Notes`.

## Notes

- **Compatibility:** `PROTOCOL_VERSION` stays `1` on purpose (see Chosen Approach). A 0.1.0
  client logs `±2` entries as skipped ("bad rating") and keeps syncing everything else. Bumping
  it would make old and new clients ignore each other's HELLOs entirely. Revisit if the
  protocol changes shape later.
- **Existing data:** saved `r = 1` / `r = -1` entries are now the one-face levels; nothing is
  rewritten. `DB_VERSION` stays `1`.
- **Tie-break:** `Ratings.Wins` already prefers the higher `r` at equal timestamps, so
  `2 > 1 > 0 > -1 > -2` is deterministic across peers with no code change.
- **Battle.net size:** LibSerialize encodes `2` and `-2` as single-byte small integers, so the
  255-byte single-entry limit is unaffected; the sync test above proves it.
- **Wording:** the four labels live in one table in `Core.lua`; change them there if "big
  jerk" is too playful. Menu order and tooltip order both follow the request
  (`😊😊`, `😊`, `☹`, `☹☹`).
- **Not in scope:** distinct icon art for the strong levels (approach 3), a net score for
  sorting the list, and a generic `/wf rate <name> <n>` command. All are small follow-ups on
  top of the level table.
- **Open question for the user (does not block execution):** whether the one-face commands
  should stay `happy`/`sad` (as planned) or whether `happy`/`sad` should mean the strong
  levels with new names for the mild ones.

### Execution notes (2026-11-05)

- **List window columns:** the ratings column needs room for four buckets with double icons
  (`😊😊 2 😊 1 ☹ 1 ☹☹ 2` is roughly 140 px), so it is 150 wide rather than the planned 130;
  name/info columns sit at 158/324 and the frame is 690 wide. The header is now one font string
  per column anchored at the same offsets as the row columns, replacing the hand-spaced string.
- **Menu labels** capitalise the chat label ("😊😊 Very friendly") via a small helper in
  `Menu.lua`; chat confirmations keep the lowercase form ("Rated X as 😊😊 very friendly").
- **`WowFriendly_Bind`** now maps action names through a table (`smile2`, `smile`, `frown`,
  `frown2`, `clear`) instead of an if-chain.
- **`ns.IconFor`** caps at `MAX_LEVEL` icons so a malformed value can never flood a tooltip.
- **Command parsing quirk (pre-existing):** `/wf happy2: note` is read as the unknown command
  `happy2:`; the colon needs a space before it when no name is given (`/wf happy2 : note`).
  The test was corrected to the documented form.
- **Tests:** 212 assertions pass (`scripts/check.sh`). The live-client checklist in the README
  (tooltip, menu, bindings) has not been run by the agent.
