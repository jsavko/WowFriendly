# WowFriendly

A World of Warcraft **Forever** addon for remembering who was great to play with and who
ninja-looted the sword. Tag any player with a smile or a frown, add a short note, and see it
on their tooltip next time you meet. Ratings are shared automatically with a trusted circle of
friends who run the addon, so the group builds a shared memory without anyone re-rating people.

## Install

1. Download `WowFriendly-<version>.zip` from the
   [latest release](https://github.com/jsavko/WowFriendly/releases/latest).
2. Extract it into your Forever AddOns directory so you end up with:

   ```
   World of Warcraft/_forever_/Interface/AddOns/WowFriendly/WowFriendly.toc
   ```

3. Start the game (or `/reload`) and check that **WowFriendly** is enabled in the AddOns list.

Everyone in your circle needs the addon installed for ratings to sync. Battle.net friends are
trusted automatically; anyone else is added with `/wf trust Name Surname` on both sides.

Working from a checkout instead: `WowFriendly/` is the addon folder. `scripts/deploy.sh` syncs it
into the AddOns directory with `rsync` (`-n` for a dry run), and `scripts/package.sh` builds the
release zip into `dist/`. The TOC targets interface `16001` (Forever / Midnight 12.1 API).

## Rating players

| Action | How |
| --- | --- |
| Smile / frown at a player | Right-click their portrait or name and pick **WowFriendly > Smile / Frown** |
| Same, from the keyboard | Bind **Smile at mouseover / target** and **Frown at mouseover / target** under Key Bindings > WowFriendly |
| From chat | `/wf happy [name]`, `/wf sad [name]` (no name means your target, then mouseover) |
| Add a note | `/wf note Name Surname: text`, or **WowFriendly > Set note...** in the menu |
| Rate with a note in one go | `/wf sad Arthas Menethil: ninja looted the sword` |
| Clear your rating | `/wf clear [name]` or **Clear my rating** in the menu |
| See what friends said | Mouse over the player, or `/wf who [name]` |
| Browse everyone rated | `/wf list` |

Names on Forever are `Firstname Surname` (there is a single realm). Typing just the first name
works too. Each friend's rating is kept separately: if two friends disagree, the tooltip shows
both (`😊 1  ☹ 1`) and who said what, instead of averaging them away.

## Sharing

Ratings sync peer-to-peer inside the game. There is no server. Your data only leaves your
client to people you trust, and you only accept data from them:

- **Battle.net friends** who are online in WoW Forever and run WowFriendly (works across factions).
- **Trusted characters** you add with `/wf trust Name Surname` (`/wf untrust`, `/wf trusted`).
- **Guild members**, only if you turn on *Share with guild members* in settings. Off by default.

How it works: on login, on group changes and when friends come online, the addon says hello
over addon channels (party, raid, guild, whisper) and Battle.net game data. Trusted peers then
exchange only what changed since they last synced. Merging is last-writer-wins *per author*, so
nobody's rating ever overwrites a friend's. A clear travels as a tombstone. Ratings relay through
mutual friends, so the pool converges even for friends who are never online together. Ratings
about *you* are never sent to you, and messages claiming to be authored by you are dropped.

Midnight blocks addon messaging during Mythic+ runs, PvP matches and boss encounters. Anything
you rate then is queued and sent once the restriction lifts.

### Offline fallback: export and import

`/wf export` shows a text string (Ctrl+C to copy). A friend pastes it into `/wf import`. This
works across anything the live sync cannot reach (offline friends, Discord, a reinstall).

## Settings

`/wf config` (or Options > AddOns > WowFriendly): tooltip lines, who-said-what, notes,
Battle.net sharing, trusted-character sharing, guild sharing, debug output.

## All commands

```
/wf happy [name[: note]]   /wf sad [name[: note]]   /wf clear [name]
/wf note [name:] <text>    /wf who [name]           /wf list
/wf trust <Name Surname>   /wf untrust <name>       /wf trusted
/wf sync                   /wf export               /wf import
/wf status                 /wf config               /wf debug
```

`/wowfriendly` is an alias for `/wf`.

## Development

- `scripts/setup-lua.sh` builds a local Lua 5.1 into `.tools/` (no sudo) for the checks below.
- `scripts/check.sh` syntax-checks every addon file and runs `tests/run.lua`, which exercises the
  rating store, identity parsing, command parsing, encoding, and a simulated multi-client sync
  (Battle.net, trust list, guild opt-in, relays, lockdown queue, export/import).
- `scripts/make_icons.py` regenerates `Media/smile.tga` and `frown.tga`.
- `scripts/deploy.sh [-n]` copies the addon into the local Forever install.
- Libraries in `WowFriendly/Libs/` are the versions shipped by addons already running on Forever
  (LibStub, CallbackHandler-1.0, AceComm-3.0 r14 with ChatThrottleLib v32, LibSerialize v4,
  LibDeflate 1.0.2).

### In-game checklist (after `scripts/deploy.sh` and `/reload`)

1. `/dump select(4, GetBuildInfo())` prints `16001` and no addon errors appear.
2. `/wf debug` prints your key as `Firstname Surname` and shows what `UnitFullName("player")`
   returns on this client.
3. Target a player, `/wf sad`, mouse over them: the tooltip shows the frown line. Right-click
   them: the **WowFriendly** submenu appears with Smile / Frown / Set note / Clear.
4. `/wf list` opens the browser; **Clear** removes your rating and the tooltip updates.
5. `/wf export` on one character, `/wf import` on another: the ratings round-trip.
6. With a friend running the addon: group up, `/wf sync`, `/wf status` shows them as a peer and
   `/wf who` on a player they rated shows their entry. Repeat as Battle.net friends on different
   factions. If party whispers do not connect, `/wf trust` each other and sync again.
7. `/console addonChatRestrictionsForced 1`, rate someone (`/wf status` shows it queued), then
   `/console addonChatRestrictionsForced 0`: the queued rating is delivered.

Things not yet verified on a live client are listed in the plan notes under
`.claude/plans/`: whether whisper targets need the surname, the exact `contextData` fields of
friend-list and chat menus, and the `StaticPopup` edit-box field name on this client (both
spellings are handled).

## Not in this version

Nameplate and raid-frame badges, a minimap button, rating from the Group Finder applicant list,
localization, a neutral "noted" rating that carries only a note.
