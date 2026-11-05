---
status: in-progress
---
# WowFriendly: WoW Forever player rating addon with friend sync

**Date:** 2026-11-04

---

## Goal

Build a World of Warcraft **Forever** addon (working name `WowFriendly`) that lets the user
tag other players with a happy face or a sad face, with an optional short note, and shows
that tag on the unit tooltip when mousing over the player. Ratings are shared automatically
with a trusted circle of friends who run the same addon, so the group builds a shared pool of
"player memory" (who ninja-looted, who was great to run with) without anyone having to
re-rate people.

Scope for v1:

- Rate a player as 😊 (friendly) or ☹ (jerk), clear a rating, attach a short note.
- Rate via slash command, the unit right-click menu, and keybindings (target/mouseover).
- Show the rating on unit tooltips, including which friend gave it and any note.
- Sync ratings peer-to-peer with trusted friends over addon channels (party/raid/guild/
  whisper and Battle.net game data), merging without ever overwriting a friend's rating.
- Export/import strings as an offline fallback for sharing via Discord.
- Small settings panel and a `/wf list` browser of rated players.

Out of scope for v1 (listed in Notes as follow-ups): nameplate/unit-frame badges, an external
web backend, a minimap button, localization.

### Target client facts (verified 2026-11-04)

- WoW Forever launched today. It is installed locally at
  `/mnt/c/Program Files (x86)/World of Warcraft/_forever_/` and that AddOns folder is writable
  from WSL (deploy by `rsync`, no symlinks needed).
- Forever uses the **Mainline / Midnight (12.1.x) API**, not Classic. TOC `## Interface: 16001`,
  TOC suffix `_Forever` or `_Camelot`, `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT`. Installed
  addons (AutoBiographer, Questie, Auctionator) confirm the modern tooltip, menu, comm and
  `C_AddOns` APIs all work on this client.
- Midnight addon restrictions apply: addon messaging is blocked during M+ runs, PvP matches
  and instance encounters (`C_ChatInfo.InChatMessagingLockdown()`, `ADDON_RESTRICTION_STATE_CHANGED`);
  many values are "secret" in instances/combat and must be guarded with `issecretvalue`;
  player GUIDs are obfuscated, so player identity must be keyed by `Name-Realm`, not GUID.
- Forever has a Gamepad UI mode (`GetCVar("InputDeviceInterfaceStyle") == "1"`) whose menus
  are protected; menu hooks must skip it (AutoBiographer does exactly this).
- Local tooling: `rsync`, `python3`, `node`, `gcc`, `curl` available; no Lua interpreter or
  luacheck installed (no sudo assumed).

## Approaches Considered

### 1. Local-only ratings (SavedVariables, no sharing)
- **Description:** Store ratings in `WowFriendlyDB`; tooltip + commands + menu only.
- **Pros:** Smallest surface; no comm restrictions to worry about; done in a day.
- **Cons:** No shared pool, which is half the request. Still the right foundation layer.

### 2. Manual export/import strings (WeakAuras-style)
- **Description:** `/wf export` produces a compressed, printable string; friends paste it into
  `/wf import`, which merges. Shared via Discord.
- **Pros:** Works cross-realm, cross-faction, offline, and with no trust problem (you choose
  what to paste). Immune to Midnight comm lockdowns. ~100 lines on top of approach 1.
- **Cons:** Manual and stale; nobody will do it every session.

### 3. In-game peer-to-peer sync over addon channels with a trust allowlist
- **Description:** On login/group/guild/friend-online events, exchange a `HELLO`, then a
  `SINCE <lastSync>` / `DELTA` round over `C_ChatInfo.SendAddonMessage` (party/raid/guild/
  whisper) and Battle.net game data (`C_BattleNet.SendGameData` / `BN_CHAT_MSG_ADDON`) for
  cross-realm friends. Each rating is keyed by `(target, author)` with a timestamp; merge is
  last-writer-wins per author, with tombstones for clears, so friends' ratings never clobber
  each other. Only accept data from Battle.net friends, an explicit trusted-character list, and
  optionally guild members. Live `RATE` messages propagate new ratings immediately.
- **Pros:** Automatic, zero infrastructure, fully inside the game, and the pool converges even
  when two friends are never online together (a mutual friend relays). AceComm handles
  chunking and throttling; LibSerialize + LibDeflate keep payloads small.
- **Cons:** Only syncs while both are online in Forever; must queue around Midnight's
  lockdowns; trust model needs care to prevent griefing.

### 4. External shared backend plus desktop companion app
- **Description:** A web service holds the pool; a companion app on each friend's PC reads
  and writes the `SavedVariables` file.
- **Pros:** Always-on shared pool, works across games/regions, web UI possible.
- **Cons:** Addons cannot make HTTP calls, so every friend must install and run a second
  program; SavedVariables are only written on logout/reload; hosting, auth and abuse handling
  for a small friend group is heavy. Far more work than the value it adds.

### 5. Open guild-wide broadcast
- **Description:** Everyone in the guild with the addon shares everything with everyone.
- **Pros:** Biggest pool quickly.
- **Cons:** No trust boundary: anyone in the guild can poison the pool or spam. Noise drowns
  the "my friends' opinion" signal the user actually wants. Kept only as an opt-in toggle.

## Chosen Approach

**Approach 3 built on top of 1, with approach 2 as the fallback path.** Phase 1 delivers a
complete local addon (ratings, tooltip, menu, commands). Phase 2 adds peer-to-peer sync with
last-writer-wins-per-author merging and a trust allowlist (Battle.net friends plus an explicit
list; guild sharing is an opt-in toggle, which is approach 5 contained). Export/import strings
ship in the same phase because they reuse the exact same serializer and merge code and cover
the cases comms cannot (offline friends, cross-faction, lockdowns). Approach 4 is rejected: the
cost is out of proportion for a friend group and it fights the platform.

Rating model decision (the user was unsure): keep it **binary per author** (😊 / ☹) with an
optional note of up to 100 characters and a timestamp. The tooltip aggregates across authors
("☹ 2 · 😊 1") and names who said what, so a disagreement between friends is visible rather than
averaged away. A cleared rating is a tombstone so the clear propagates too.

Identity decision: players are keyed by normalized `Name-Realm` (realm without spaces) because
Forever obfuscates GUIDs. A name change or transfer loses the history; acceptable for v1.

## Tasks

### Phase 0: scaffolding
- [ ] Create `WowFriendly/WowFriendly.toc` with `## Interface: 16001`, `## SavedVariables: WowFriendlyDB`, `## IconTexture`, `## X-Website`, and the load order `Libs/libs.xml`, `Core.lua`, `Identity.lua`, `Ratings.lua`, `Comms.lua`, `Tooltip.lua`, `Menu.lua`, `Commands.lua`, `UI/Options.lua`, `UI/List.lua`, `Bindings.xml`.
- [ ] Vendor libraries into `WowFriendly/Libs/`: LibStub, CallbackHandler-1.0, AceComm-3.0 (with ChatThrottleLib v32), LibSerialize, LibDeflate, copied from the Forever-proven `_forever_/Interface/AddOns/AutoBiographer/Libs/`; write `Libs/libs.xml` that includes them in dependency order.
- [ ] Write `scripts/deploy.sh`: `rsync -a --delete WowFriendly/ "/mnt/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns/WowFriendly/"` with a dry-run flag.
- [ ] Write `scripts/check.sh`: Lua 5.1 syntax check of every `.lua` under `WowFriendly/` (excluding `Libs/`) using the `.tools/lua` interpreter from the test task (`luac -p`), falling back to a warning if it is not built.
- [ ] `git init`, add `.gitignore` (`.tools/`, `*.zip`), `README.md` (install path, commands, how sharing works), `.luacheckrc` with WoW globals for anyone who has luacheck.

### Phase 1: local ratings, tooltip, menu, commands
- [ ] `Core.lua`: addon namespace `local ADDON_NAME, ns = ...`; event frame; on `ADDON_LOADED` for this addon create/upgrade `WowFriendlyDB = { version = 1, ratings = {}, friends = {}, peers = {}, settings = {...defaults} }` (read saved vars only inside `ADDON_LOADED`, per Forever guidance); `ns.Print`, `ns.Debug` (gated by setting), `ns.IsSecret(v)` wrapper around `issecretvalue`.
- [ ] `Identity.lua`: `ns.Identity.KeyForUnit(unit)` returning `"Name-Realm"` only when `UnitIsPlayer(unit)` is a non-secret true and `UnitFullName`/`GetNormalizedRealmName` are non-secret strings; `KeyFromInput(text)` accepting `Name` (defaults to own realm) or `Name-Realm`, capitalizing name and stripping spaces from realm; `SelfKey()`; `Pretty(key)` (hide realm when it is the player's own).
- [ ] `Ratings.lua` (pure Lua, no WoW API so it is unit-testable): `Set(db, target, author, value, note, t)`, `Clear(db, target, author, t)` writing a tombstone `{r=0,t=...}`, `Get(db, target)`, `Aggregate(db, target)` returning `{happy=n, sad=n, entries={...sorted newest first}}`, `Merge(db, target, author, entry)` with last-writer-wins on `t` and tie-break on value, `EntriesSince(db, t)`, `ToTable(db)` / `FromTable(db, tbl)` for export/import, plus `ValidateEntry(entry)` (r in {-1,0,1}, numeric t not more than 1 day in the future, note ≤ 100 chars with `|` stripped).
- [ ] `Commands.lua`: register `/wf` and `/wowfriendly` with subcommands `happy|smile [name]`, `sad|frown [name]`, `clear [name]`, `note [name] <text>`, `who [name]`, `list`, `trust <Name-Realm>`, `untrust <Name-Realm>`, `trusted`, `sync`, `export`, `import`, `config`, `debug`; with no name argument resolve `target` then `mouseover`, else print usage. Rating from a command stamps `author = SelfKey()`, `t = GetServerTime()` and calls `ns.Comms.Broadcast(entry)`.
- [ ] `scripts/make_icons.py`: generate `WowFriendly/Media/smile.tga` and `frown.tga` (32×32, uncompressed 32-bit TGA written by hand with no third-party modules) and commit them.
- [ ] `Tooltip.lua`: register with `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, fn)` when available, else `GameTooltip:HookScript("OnTooltipSetUnit", fn)`; inside, get the unit via `tooltip:GetUnit()`, bail on secret/non-string/NPC/self, look up `Aggregate`, and add lines: a summary line using `|T...Media\smile:14|t` texture escapes with counts, then one line per author (`Alice: "ninja looted"`), honoring settings `showOnTooltip`, `showAuthors`, `showNotes`.
- [ ] `Menu.lua`: for each tag in `TARGET, PLAYER, ENEMY_PLAYER, PARTY, RAID_PLAYER, FOCUS, FRIEND` call `Menu.ModifyMenu("MENU_UNIT_"..tag, fn)`; skip when Gamepad UI is on or `contextData` is secret; resolve the key from `contextData.unit` or `contextData.name`+`contextData.server`; add a "WowFriendly" submenu with Smile / Frown / Clear and a "Set note..." button that opens a `StaticPopup` with an edit box; probe `MENU_LFG_FRAME_SEARCH_ENTRY` and `MENU_LFG_FRAME_MEMBER_APPLY` only if those tags exist on Forever.
- [ ] `Bindings.xml`: two bindings under header "WowFriendly": `WOWFRIENDLY_SMILE` and `WOWFRIENDLY_FROWN`, each acting on mouseover then target.

### Phase 2: sharing
- [ ] `Comms.lua` transport: `C_ChatInfo.RegisterAddonMessagePrefix("WOWFRIENDLY")`; AceComm `RegisterComm` for `CHAT_MSG_ADDON` with multi-part reassembly; a `BN_CHAT_MSG_ADDON` handler for Battle.net game data (single-part only, ≤255 bytes, unordered, so DELTAs over BN are split into one-entry `RATE` messages); encode as LibSerialize → `LibDeflate:CompressDeflate` → `EncodeForWoWAddonChannel`, decode the reverse, and reject anything that fails to decode or validate.
- [ ] `Comms.lua` trust: `ns.Trust.IsTrustedSender(senderKey, channel, bnGameAccountID)` accepts Battle.net game-data senders (friends by construction), characters in `db.friends`, and guild members only when `settings.shareGuild` is on; everything else is dropped with a debug log. Accept relayed entries from any trusted sender (pool semantics) but always keep the original author.
- [ ] `Comms.lua` protocol: message types `HELLO {v, count}`, `SINCE {t}`, `DELTA {entries}`, `RATE {entry}`. Send HELLO 5s after `PLAYER_ENTERING_WORLD`, on `GROUP_ROSTER_UPDATE`, on `GUILD_ROSTER_UPDATE` (guild toggle only), and on `BN_FRIEND_INFO_CHANGED`; HELLO goes to PARTY/RAID/GUILD as applicable, WHISPER to online trusted characters, and BN game data to online Battle.net friends whose `gameAccountInfo.clientProgram == "WoW"` and `wowProjectID == WOW_PROJECT_ID`. On HELLO from a trusted peer reply `SINCE db.peers[peer].lastSync`; answer SINCE with a `DELTA` of `EntriesSince(t)` at BULK priority; on DELTA merge and set `lastSync = GetServerTime()`; on a local rating send `RATE` to all currently reachable trusted peers.
- [ ] `Comms.lua` lockdown queue: every send goes through `ns.Comms.Enqueue`; drain only when `C_ChatInfo.InChatMessagingLockdown()` is false (also probe `C_RestrictedActions`/`GetRestrictedActionStatus` when present); drain on `ADDON_RESTRICTION_STATE_CHANGED`, `PLAYER_REGEN_ENABLED`, and a 30s `C_Timer.NewTicker`; cap queue length and drop stale HELLOs.
- [ ] Export/import: `/wf export` opens a frame with a read-only, auto-selected multiline edit box containing `EncodeForPrint` of `ToTable(db)`; `/wf import` opens an edit box, decodes, validates each entry, merges via `Merge`, and prints how many entries were added/updated/skipped.
- [ ] Hardening: cap DELTA size from guild senders, strip `|` and control characters from received names/notes before they can reach a tooltip, enforce the `Name-Realm` key pattern, ignore entries about the receiving player themself, and rate-limit HELLO replies per peer to one per 60s.

### Phase 3: UI
- [ ] `UI/Options.lua`: `Settings.RegisterVerticalLayoutCategory("WowFriendly")` with `Settings.RegisterAddOnSetting` (11.0 signature) checkboxes for showOnTooltip, showAuthors, showNotes, syncBattleNet, syncTrusted, shareGuild, debug; `/wf config` opens it via `Settings.OpenToCategory`.
- [ ] `UI/List.lua`: `/wf list` window listing every rated player (icon, name, authors, newest note, date) in a scroll frame with per-row Clear buttons and a text filter; reuse `Aggregate` so the display matches the tooltip.

### Phase 4: verification
- [ ] Build a project-local Lua 5.1 interpreter without sudo: `scripts/setup-lua.sh` downloads `lua-5.1.5.tar.gz`, runs `make generic`, and installs `lua`/`luac` into `.tools/` (gitignored); this is only for offline tests and the syntax check, the addon itself needs no build.
- [ ] `tests/run.lua` with a minimal WoW stub (`GetServerTime`, `issecretvalue`): cover `Ratings` LWW merge, tombstone propagation, aggregate counts, `EntriesSince`, `ValidateEntry` rejections, and `Identity.KeyFromInput` parsing; `scripts/check.sh` runs the syntax check then the tests.
- [ ] In-game checklist (documented in README): run `scripts/deploy.sh`, `/reload`, confirm `/dump select(4, GetBuildInfo())` prints 16001 and the addon shows no errors; rate a target with `/wf sad`, confirm the tooltip line and the right-click menu entries; `/wf export` on one character and `/wf import` on another to prove the round trip; test sync with one friend (party, then Battle.net cross-realm); force a lockdown with `/console addonChatRestrictionsForced 1`, rate someone, clear the CVar, and confirm the queued RATE is delivered.

## Notes

- **Naming:** addon folder and TOC are `WowFriendly` (must match); slash command `/wf`. Rename
  before Phase 0 if a different in-game name is wanted.
- **Why not GUIDs:** Forever/Midnight obfuscates player GUIDs, and friends need a human-readable
  key anyway. `Name-Realm` it is; realm is normalized (no spaces) so keys match across clients.
- **Secret values:** creature names are secret inside instances regardless of combat. Player
  names have not been reported as secret, but every tooltip/menu path guards with
  `issecretvalue` and silently does nothing rather than erroring. Verify on live during Phase 1.
- **Comm restrictions:** blocked only during M+ runs, PvP matches and boss encounters; normal
  open-world and out-of-combat instance play is fine. The queue makes this invisible to users.
- **Battle.net game data** only reaches friends who are online in a WoW client with the addon,
  and ChatThrottleLib limits it to 255 bytes and unordered delivery, which is why BN uses
  single-entry `RATE` messages instead of chunked DELTAs. Cross-faction sharing on the same
  realm also goes through BN.
- **Library source:** copying `Libs/` from the installed AutoBiographer is the quickest path and
  those exact versions are proven on Forever; switching to upstream Ace3/LibSerialize/LibDeflate
  releases later is a drop-in change.
- **Open questions to confirm in-game:** whether `contextData.name`/`.server` are populated for
  friend-list and chat menus on Forever; whether `MENU_LFG_FRAME_*` tags exist at all on Forever;
  whether `UnitFullName` returns the realm for same-realm units on this client (fallback to
  `GetNormalizedRealmName` covers both answers).
- **Follow-ups after v1:** rating badges on nameplates and raid frames, a minimap button
  (LibDBIcon), rating from the Group Finder applicant list, localization, a "last seen with"
  timestamp per player, and an optional neutral "noted" rating that carries only a note.

### Sources consulted
- https://warcraft.wiki.gg/wiki/TOC_format (Interface 16001, `_Forever`/`_Camelot` suffix)
- https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes (comm lockdown scope, secret values)
- https://warcraft.wiki.gg/wiki/API_C_ChatInfo.SendAddonMessage (255-byte limit, prefix rules)
- https://wowforeverguides.com/addons/developers (Forever API family, missing globals, SavedVariables timing)
- https://forevermeta.me/en/guides/wow-forever-addons-interface (launch date, addon compatibility)
- https://github.com/Shtian/bff-wow/issues/2 and /issues/4 (lockdown detection APIs in practice)
- Installed Forever addons AutoBiographer and Questie (tooltip, menu, comm, library patterns)
