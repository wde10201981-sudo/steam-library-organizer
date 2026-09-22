#requires -Version 5.1
<#
Update-Steam-Collections.ps1 -- apply an editable collection plan
Close Steam via Steam > Exit before applying or restoring.
Preview: .\Update-Steam-Collections.ps1
Apply:   .\Update-Steam-Collections.ps1 -Apply
Restore: .\Update-Steam-Collections.ps1 -RestoreBackup 'FULL BACKUP PATH'
No API key, network requests, downloads, or game/save edits.
Uses Steam's undocumented local cloudstorage format. Client/cloud acceptance
must be checked by restarting Steam. If changes revert, stop and report that;
do not delete Steam caches or disable cloud synchronization.
Implementation reference: SteamGridDB/steam-rom-manager,
src/lib/category-manager.ts (cloud storage writer).
The original file is backed up during atomic replacement. All backups remain.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$RestoreBackup,
    [string]$CollectionPath,
    [string]$PlanPath = (Join-Path $PSScriptRoot 'local/plan.json'),
    [string]$AccountId
)
$ErrorActionPreference = 'Stop'
if ($Apply -and $RestoreBackup) { throw 'Choose Apply or RestoreBackup, not both.' }
if (!$CollectionPath) {
    $steamRoot = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath
    if (!$AccountId -and !$RestoreBackup -and (Test-Path -LiteralPath $PlanPath)) {
        $AccountId = (Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json).accountId
    }
    $files = @(Get-ChildItem "$steamRoot/userdata/*/config/cloudstorage/cloud-storage-namespace-1.json" -File)
    if ($AccountId) {
        if ($AccountId -notmatch '^\d+$') { throw 'AccountId must be numeric.' }
        $files = @($files | Where-Object { $_.FullName -match "[\\/]$AccountId[\\/]config[\\/]" })
    }
    if ($files.Count -ne 1) {
        $files | ForEach-Object { Write-Host $_.FullName }
        throw 'Select your account with -AccountId, or specify -CollectionPath. No automatic multi-account selection.'
    }
    $CollectionPath = $files[0].FullName
}
$CollectionPath = [IO.Path]::GetFullPath($CollectionPath)
if (!(Test-Path -LiteralPath $CollectionPath -PathType Leaf)) {
    throw "Collection file not found: $CollectionPath"
}
function Assert-SteamClosed {
    if (@(Get-Process -Name steam,steamwebhelper -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Steam is still running. Use Steam > Exit, wait a few seconds, then run again.'
    }
}
function Read-Store([string]$Text) {
    $parsed = ConvertFrom-Json -InputObject $Text
    $seen = @{}
    foreach ($pair in $parsed) {
        if ($pair -isnot [array] -or $pair.Count -ne 2 -or
            $pair[0] -isnot [string] -or $pair[1].key -cne $pair[0]) {
            throw 'Unexpected Steam collection format. Nothing was changed.'
        }
        if ($seen.ContainsKey($pair[0])) { throw 'Duplicate storage key. Nothing was changed.' }
        $seen[$pair[0]] = $true
    }
    if (!$seen.ContainsKey('collection-bootstrap-complete')) {
        throw 'Expected Steam collection marker missing. Nothing was changed.'
    }
    return ,$parsed
}
function Write-Atomic([string]$Text, [string]$ExpectedHash) {
    Assert-SteamClosed
    $null = Read-Store $Text
    if ((Get-FileHash -LiteralPath $CollectionPath -Algorithm SHA256).Hash -ne $ExpectedHash) {
        throw 'Steam file changed during preparation. Nothing was written. Run again with Steam closed.'
    }
    $suffix = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $backup = "$CollectionPath.before-category-update-$suffix.bak"
    $temp = "$CollectionPath.$suffix.tmp"
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
        Assert-SteamClosed
        if ((Get-FileHash -LiteralPath $CollectionPath -Algorithm SHA256).Hash -ne $ExpectedHash) {
            throw 'Source changed before replacement. Nothing was written.'
        }
        # File.Replace atomically keeps the previous destination in the backup.
        [IO.File]::Replace($temp, $CollectionPath, $backup)
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
    Write-Host "Backup: $backup"
    Write-Host 'To undo: run this script with -RestoreBackup followed by that quoted backup path.'
}
if ($Apply -or $RestoreBackup) { Assert-SteamClosed }
$sourceHash = (Get-FileHash -LiteralPath $CollectionPath -Algorithm SHA256).Hash
$originalText = [IO.File]::ReadAllText($CollectionPath)
$store = Read-Store $originalText
if ($RestoreBackup) {
    $restoreText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $RestoreBackup).Path)
    $null = Read-Store $restoreText
    Write-Atomic $restoreText $sourceHash
    Write-Host 'Backup restored locally. Open Steam and check the collections.'
    return
}
$config = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
if ($config.schemaVersion -ne 1) { throw 'Unsupported plan schemaVersion.' }
$plan = [ordered]@{}
foreach ($entry in $config.collections) {
    $name = ([string]$entry.name).Trim().ToUpperInvariant()
    if (!$name -or $name -in @('FAVORITES','FAVORITE','HIDDEN') -or $plan.Contains($name)) {
        throw 'Collection names must be unique, nonempty and not Favorites/Hidden.'
    }
    $ids = @()
    foreach ($appId in $entry.appids) {
        if ([string]$appId -notmatch '^\d+$' -or [long]$appId -le 0 -or [long]$appId -gt [int]::MaxValue) {
            throw "Invalid AppID: $appId"
        }
        $ids += [int]$appId
    }
    if (!$ids.Count) { throw "Empty planned collection: $name" }
    $plan[$name] = $ids
}
if (!$plan.Count) { throw 'The plan has no collections.' }
$managed = @{}
foreach ($name in $plan.Keys) {
    foreach ($id in $plan[$name]) {
        if ($managed.ContainsKey([string]$id)) { throw "Duplicate planned AppID: $id" }
        $managed[[string]$id] = $name
    }
}
if (!$managed.Count) { throw 'The plan has no AppIDs.' }
$aliases = @{
    'SIM' = 'SIMULATION'
    'SURVIVAL' = 'SURVIVAL / CRAFTING'
    'PLATFORMER / STEALTH' = 'PLATFORMER'
}
$timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
foreach ($pair in $store) {
    $timestamp = [Math]::Max($timestamp, ([long]$pair[1].timestamp + 1))
}
$output = New-Object 'System.Collections.Generic.List[object]'
$used = @{}
$protected = @{}
function New-Record([string]$Key, $Value) {
    return [pscustomobject][ordered]@{
        key = $Key
        timestamp = $timestamp
        value = (ConvertTo-Json -InputObject $Value -Depth 50 -Compress)
        version = [string]$timestamp
        conflictResolutionMethod = 'custom'
        strMethodId = 'union-collections'
    }
}
foreach ($pair in $store) {
    $key = [string]$pair[0]
    $record = $pair[1]
    if (!$key.StartsWith('user-collections.') -or $record.is_deleted -or
        $key -in @('user-collections.favorite','user-collections.hidden')) {
        $output.Add($pair)
        $protected[$key] = ConvertTo-Json -InputObject $record -Depth 50 -Compress
        continue
    }
    $collection = ConvertFrom-Json -InputObject $record.value
    if (!$collection.id -or !$collection.name -or $key -cne "user-collections.$($collection.id)") {
        throw "Unexpected collection structure at $key. Nothing was changed."
    }
    $name = ([string]$collection.name).ToUpperInvariant()
    if ($aliases.ContainsKey($name)) { $name = $aliases[$name] }
    $oldAdded = @($collection.added)
    $oldRemoved = @($collection.removed)
    if ($plan.Contains($name) -and !$used.ContainsKey($name)) {
        # Reuse the collection ID; preserve apps absent from the plan.
        $extra = @($oldAdded | Where-Object { $null -ne $_ -and !$managed.ContainsKey([string]$_) })
        $desired = @(@($plan[$name]) + $extra | Sort-Object -Unique)
        $removed = @(@($oldRemoved) + @($oldAdded | Where-Object { $_ -notin $desired }) |
            Where-Object { $null -ne $_ -and $_ -notin $desired } | Sort-Object -Unique)
        $collection.name = $name
        $collection.added = $desired
        $collection.removed = $removed
        $collection.PSObject.Properties.Remove('filterSpec')
        $used[$name] = [string]$collection.id
    }
    else {
        # Preserve unrelated collections, but exclude these planned IDs to avoid overlap.
        $collection.added = @($oldAdded | Where-Object { $null -ne $_ -and !$managed.ContainsKey([string]$_) })
        $collection.removed = @(@($oldRemoved) + @($managed.Keys | ForEach-Object { [int]$_ }) |
            Where-Object { $null -ne $_ -and $_ -notin $collection.added } | Sort-Object -Unique)
    }
    $updated = New-Record $key $collection
    # Leave unchanged records untouched on repeated runs.
    if ($updated.value -ceq $record.value) { $output.Add($pair) }
    else { $output.Add([object[]]@($key, $updated)) }
}
foreach ($name in $plan.Keys) {
    if ($used.ContainsKey($name)) { continue }
    $id = 'uc-' + [guid]::NewGuid().ToString('N')
    $collection = [pscustomobject][ordered]@{
        id = $id; name = $name
        added = @($plan[$name] | Sort-Object -Unique)
        removed = @()
    }
    $key = "user-collections.$id"
    $output.Add([object[]]@($key,(New-Record $key $collection)))
    $used[$name] = $id
}
$serialized = ConvertTo-Json -InputObject ($output.ToArray()) -Depth 60 -Compress
$verified = Read-Store $serialized
$counts = @{}
foreach ($pair in $verified) {
    $key = [string]$pair[0]; $record = $pair[1]
    if ($protected.ContainsKey($key)) {
        if ((ConvertTo-Json -InputObject $record -Depth 50 -Compress) -cne $protected[$key]) {
            throw "Preservation check failed for $key. Nothing was changed."
        }
        continue
    }
    if ($record.is_deleted -or !$key.StartsWith('user-collections.')) { continue }
    $c = ConvertFrom-Json -InputObject $record.value
    if ($used.ContainsKey($c.name) -and $used[$c.name] -ceq $c.id -and $c.filterSpec) {
        throw 'A target collection is still dynamic. Nothing was changed.'
    }
    foreach ($id in @($c.added)) {
        if ($managed.ContainsKey([string]$id)) {
            if ($c.name -cne $managed[[string]$id] -or $id -in @($c.removed)) {
                throw "Incorrect assignment for $id. Nothing was changed."
            }
            $counts[[string]$id] = 1 + [int]$counts[[string]$id]
        }
    }
}
if ($counts.Count -ne $managed.Count -or @($counts.Values | Where-Object { $_ -ne 1 }).Count) {
    throw 'Validation failed: not exactly one category per AppID. Nothing was changed.'
}
Write-Host "Target: $CollectionPath"
foreach ($name in $plan.Keys) { Write-Host ('{0,-25} {1,3}' -f $name, $plan[$name].Count) }
Write-Host "Validated: $($managed.Count) entries, $($plan.Count) primary collections. Favorites and Hidden preserved."
Write-Host 'Favorites remain an intentional second listing. Hidden games stay hidden.'
if (!$Apply) {
    Write-Host 'PREVIEW ONLY. To update, close Steam and run this script again with -Apply.'
    return
}
Write-Atomic $serialized $sourceHash
Write-Host 'Local collection file updated. Open Steam and check the Library.'
Write-Host 'If Steam reverts the changes, report that before making further edits.'
