# Steam Library Organizer

Batch-organize Steam games into one primary collection per game, with a preview,
automatic backups and a restore command. Windows PowerShell 5.1 or PowerShell 7
on Windows; no extra modules required.

**Early version:** the original account-specific updater worked on one user's
Steam installation. The generalized scripts have offline tests; compatibility
with every Steam version and cloud-sync state is not guaranteed. Steam's local
collection format and Store metadata endpoint are undocumented.

## Quick start

1. Download this repository using **Code → Download ZIP**, then extract it.
2. Open PowerShell in the extracted folder. Review the scripts before running.
3. Get your own [Steam Web API key](https://steamcommunity.com/dev/apikey).
   Keep it private. Find your 17-digit SteamID64 on your Steam account details page.
4. Generate a plan (enter your own ID when prompted):

```powershell
$steamId = Read-Host 'Your 17-digit SteamID64'
.\New-Steam-Plan.ps1 -SteamId $steamId
```

The API key is requested privately and is not written to disk. Genre lookups
can take several minutes. Only Steam endpoints are contacted. Your key and ID
are sent to Steam's owned-games endpoint; public AppIDs go to its Store endpoint.
If script execution is blocked on your own PC, review the files and use a
process-only execution policy rather than changing the machine-wide policy:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
Get-ChildItem . -Filter *.ps1 | Unblock-File
```

Organization-managed restrictions may still apply; follow your administrator's
policy. Administrator privileges are normally unnecessary.

5. Read `local/review.csv` for names, genres and suggestions. **Edit
   `local/plan.json` to change the assignments**; editing the CSV does not change
   the plan. Each AppID must occur exactly once. Put unresolved games in an
   appropriate category or remove them from the plan to leave them unmanaged.
6. Preview, without changing Steam:

```powershell
.\Update-Steam-Collections.ps1
```

7. Fully exit Steam using **Steam → Exit**, then apply and reopen Steam:

```powershell
.\Update-Steam-Collections.ps1 -Apply
```

Verify your collections after restarting Steam. If they revert, report the
behavior; do not delete Steam caches or repeatedly reapply hoping to force sync.

## How categories are chosen

`rules.json` lists genres in priority order. The first matching genre wins.
Steam Store genres are broad: they do not reliably distinguish FPS, horror,
platformers or survival games. This version does **not** fetch community tags.
The default is a conservative starting point, not an authoritative taxonomy.
Unavailable metadata and unmatched genres go to `REVIEW`.

Reorder `genrePriority` to change precedence, or add AppID overrides:

```json
"overrides": {
  "570": "MOBA",
  "730": "FPS"
}
```

Overrides can use any nonempty collection name except Favorites or Hidden.
To regenerate without overwriting your edits:

```powershell
.\New-Steam-Plan.ps1 -SteamId $steamId -OutputDirectory .\local\second-plan
.\Update-Steam-Collections.ps1 -PlanPath .\local\second-plan\plan.json
```

Owned-games results can omit family-shared games, non-Steam shortcuts and some
free games/tools. You can add known positive AppIDs to the JSON plan yourself.
Plan generation does not read or modify collection files.

## What applying does

- Uses the account associated with the plan. It never guesses between multiple accounts.
- Reuses collections with matching names, converting target dynamic collections to static ones.
- Creates missing collections. AppIDs absent from the plan remain in existing target lists.
- Removes planned games from other ordinary collections and adds exclusions to
  other dynamic collections, so they have one primary category. This also affects
  personal collections such as “Backlog” if they contain managed games.
- Keeps Favorites and Hidden unchanged. Favorites therefore remain an intentional overlap.
- Preserves unrelated settings and deleted records. Does not install/uninstall
  games, touch saves or change Steam account settings.
- Rejects malformed files, duplicate AppIDs and changes detected during preparation.
- Backs up the previous file while atomically replacing it.

Dynamic collections can include games that are not explicitly listed in their
`added` arrays. Converting one to static removes that automatic membership;
review omitted family-shared/non-Steam entries afterward. Games absent from the
plan may remain uncategorized. Existing empty collections are not deleted.

## Restore

The apply command prints a timestamped `.bak` path next to Steam's collection
file. With Steam fully closed, use your own account folder number and backup path:

```powershell
.\Update-Steam-Collections.ps1 -AccountId YOUR_ACCOUNT_FOLDER -RestoreBackup 'C:\full\path\to\backup.bak'
```

Restoration backs up the current file too. Account folder numbers are **not**
17-digit SteamID64 values. If needed, use `-CollectionPath` to explicitly select
`Steam\userdata\ACCOUNT\config\cloudstorage\cloud-storage-namespace-1.json`.
The script supports namespace 1 only; it fails rather than searching other stores.

## Privacy

Do not commit API keys, account exports, plans, reviews, Steam configuration or
backups. `local/`, common Steam storage filenames, logs and backup files are
ignored by Git. Alternate output directories outside `local/` are not automatically
ignored. The repository contains no personal account IDs, private library lists
or credentials. Never post raw configuration in a public issue.

## Tests and implementation notes

```powershell
.\tests\Run-Tests.ps1
```

Tests use synthetic data in a temporary folder; they do not edit your Steam
installation. CI runs on Windows with both PowerShell 5.1 and 7. Tests cover
preview, assignments, preservation, exclusions, repeated runs, malformed plans,
backup restore, and plan generation with mocked Steam responses. They cannot
verify real Steam Cloud acceptance.

The collection writer follows the local JSON structure observed in Steam and
the approach used by [Steam ROM Manager's category manager](https://github.com/SteamGridDB/steam-rom-manager/blob/master/src/lib/category-manager.ts).
Owned-game retrieval uses Valve's [IPlayerService API](https://partner.steamgames.com/doc/webapi/IPlayerService).
This project is not affiliated with Valve.

MIT licensed. Contributions and reproducible bug reports are welcome.
