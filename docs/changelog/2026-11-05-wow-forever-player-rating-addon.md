# 2026-11-05: WowFriendly, a WoW Forever player rating addon with friend sync

## Summary

First complete version of **WowFriendly**, a World of Warcraft Forever addon (`## Interface: 16001`)
that lets a player tag other players with a smile or a frown plus a short note, shows the tag on
unit tooltips, and shares ratings automatically with a trusted circle of friends over addon
channels and Battle.net game data. Includes an export/import fallback, a settings panel, a rated
players browser, an offline test suite with a simulated network, and deploy/check scripts.

## Changes

### Features
- **Ratings** (`Ratings.lua`): binary rating per (target, author) with optional 100-character
  note and timestamp; clears are tombstones; last-writer-wins merge with deterministic tie-break;
  aggregate counts per player; entries-since queries on local receive time; export/import tables;
  validation and sanitization of anything received.
- **Identity** (`Identity.lua`): players keyed by `Firstname Surname` (Forever has one realm and
  gives characters surnames); realm suffixes stripped; secret-value guards; first-name matching
  for senders that arrive without a surname.
- **Commands** (`Commands.lua`): `/wf` and `/wowfriendly` with happy/sad/clear/note/who/list/
  trust/untrust/trusted/sync/export/import/status/config/debug; `Name Surname: note` syntax;
  target then mouseover fallback; `WowFriendly_Bind` for keybindings.
- **Tooltip** (`Tooltip.lua`): `TooltipDataProcessor` post-call (hook fallback) adding a summary
  line with icon counts and up to five who-said-what lines, honoring the display settings.
- **Right-click menu** (`Menu.lua`): `Menu.ModifyMenu` on eleven unit menu tags with a
  WowFriendly submenu (Smile, Frown, Set note..., Clear, Show ratings); skipped under Forever's
  protected Gamepad UI; `StaticPopup` note editor.
- **Keybindings** (`Bindings.xml`): Smile / Frown at mouseover or target.
- **Sync** (`Comms.lua`): HELLO / SINCE / DELTA / RATE protocol over AceComm (party, raid, guild,
  whisper) and ChatThrottleLib Battle.net game data (single-part, 255 bytes, note shortened to
  fit); trust allowlist (Battle.net friends, explicit trusted characters, guild members when opted
  in); lockdown-aware send queue drained on `ADDON_RESTRICTION_STATE_CHANGED`, leaving combat
  and every 30 s; hardening (delta caps, name/note sanitizing, self and impersonation drops,
  per-peer HELLO reply rate limit).
- **Export / import** (`UI/Export.lua`): printable `WF1:` strings via LibDeflate.
- **Settings** (`UI/Options.lua`): Settings API category with tooltip, sharing and debug toggles.
- **List** (`UI/List.lua`): scrollable, filterable browser of rated players with Clear buttons.
- **Icons** (`Media/smile.tga`, `Media/frown.tga`): generated 32x32 TGAs.

### Tooling and tests
- `scripts/setup-lua.sh` builds a local Lua 5.1 into `.tools/` without sudo.
- `scripts/check.sh` syntax-checks the addon and runs `tests/run.lua` (157 assertions: rating
  store, identity, command parsing, encoding, and a simulated multi-client sync covering
  Battle.net friends, first-name trust, relays, guild opt-in, lockdown queueing, export/import).
- `scripts/deploy.sh [-n]` rsyncs the addon into the local Forever install.
- `scripts/make_icons.py` regenerates the icons (optional PNG preview).
- `.luacheckrc` for anyone with luacheck.

### Documentation
- `README.md`: install, commands, sharing model, settings, development, in-game checklist.

## Files

| Path | Description |
| --- | --- |
| `WowFriendly/WowFriendly.toc` | Addon manifest, load order, SavedVariables |
| `WowFriendly/Libs/**` | Vendored LibStub, CallbackHandler-1.0, AceComm-3.0 + ChatThrottleLib v32, LibSerialize, LibDeflate |
| `WowFriendly/Core.lua` | Namespace, saved variables, event dispatch, rating actions |
| `WowFriendly/Identity.lua` | Player key derivation and matching |
| `WowFriendly/Ratings.lua` | Pure-Lua rating store and merge logic |
| `WowFriendly/Comms.lua` | Transport, trust, protocol, lockdown queue |
| `WowFriendly/Tooltip.lua` | Tooltip lines |
| `WowFriendly/Menu.lua` | Unit menu entries and note popup |
| `WowFriendly/Commands.lua` | Slash commands and keybinding handlers |
| `WowFriendly/UI/Options.lua` | Settings panel |
| `WowFriendly/UI/Export.lua` | Export / import window |
| `WowFriendly/UI/List.lua` | Rated players browser |
| `WowFriendly/Bindings.xml` | Keybindings |
| `WowFriendly/Media/*.tga` | Icons |
| `scripts/*` | Build, check, deploy, icon generation |
| `tests/run.lua` | Offline test suite |
| `README.md`, `.gitignore`, `.luacheckrc` | Repository files |

## Rationale

The user wanted a shared "player memory" among friends without infrastructure. Peer-to-peer sync
inside the game (approach 3 of the plan) on top of a complete local addon gives that with zero
hosting; per-author last-writer-wins merging keeps friends' opinions distinct rather than
averaged, and tombstones let clears propagate. Export/import reuses the same serializer to cover
what live sync cannot (offline friends, reinstalls). Identity uses `Firstname Surname` because
Forever obfuscates GUIDs and has a single realm. Library versions were taken from addons already
running on Forever to avoid API surprises, and a lockdown queue was added because neither
AceComm nor ChatThrottleLib handles Midnight's messaging restrictions.
