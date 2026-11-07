# Kindred

A character friends list for **WoW Forever** that is separate from Battle.net. Forever has no character-based friends list, so this keeps your own account-wide list of First + Last names. It also shows presence, zone and map position for friends who run the addon too.

## Install
Install from CurseForge (choose **WoW Forever** in the app), or download the zip from
[Releases](https://github.com/zachroberts8668/kindred/releases) and extract it so you have
`World of Warcraft\_forever_\Interface\AddOns\Kindred\Kindred.toc`. Then restart the game.

For development, clone this repo and junction it in as `AddOns\Kindred`.

## Releasing
Push a tag like `v1.1.0`. The GitHub Action ([BigWigsMods/packager](https://github.com/BigWigsMods/packager))
builds the zip, sets the version from the tag, creates a GitHub release and uploads to CurseForge
(needs the `CF_API_KEY` repo secret and `## X-Curse-Project-ID` in the `.toc`).

## Use
- `/ff` (or `/kindred`, `/kin`, or the minimap button) opens the window
- **Add Friend** takes "First Last". **Add Target** adds the player you have targeted. You can also right-click any player (target, party, raid, chat name, /who) and pick **Add to Kindred**
- Search box filters names, notes and zones. **Sort** cycles Status / Name / Level / Zone
- Right-click a friend: Whisper, Invite, Who, Send Title Friend Request, Set Note, Move to Group, per-friend alerts, Remove
- Right-click a group header: rename, reorder, delete, or add a friend to it
- **Options**: hide offline, online/offline alerts, alert sound, level-up alerts, add-back prompts, map position sharing, world map dots, minimap button
- `/ff alerts`, `/ff minimap`, `/ff refresh`, `/ff debug`

## How presence works
| Friend… | What you see |
|---|---|
| is your Forever **Title Friend** | Status, level, class and zone from Battle.net (works in instances) |
| runs the addon and has you listed | Online, level, class, zone, AFK/DND, world map dot |
| runs the addon but hasn't added you | "Online - hasn't added you" (no zone) |
| doesn't run the addon | "Online - no addon". Right-click > Who to look up their zone |
| is offline | "Offline - seen 2 days ago in Ironforge" |
| ran the addon but stopped answering | "in an instance?" (addon messages are blocked in dungeons/raids) |

Every 60 seconds the addon sends each friend a hidden addon whisper, at most 3 messages a second. Friends who are offline get checked every other round. When a friend is offline, the server's "No player named X is currently playing" line tells the addon so, and that line is hidden from chat. A friend has to miss two checks in a row before they show as online without the addon. Guild, group, target/mouseover and `/who` sightings fill in the rest. Weaker sources can't overrule a fresh, stronger one, and data older than about 3 minutes falls back to "last seen".

When someone who has you on their list pings you and you don't have them, you get a prompt: **Add / Not Now / Never**.

**Privacy:** your zone, level, class and map position go only to people on *your* list. People not on your list only learn that you're online. Map position sharing can be turned off in Options.

Data is account-wide (`WTF\Account\<account>\SavedVariables\Kindred.lua`).
