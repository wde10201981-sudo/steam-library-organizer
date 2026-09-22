#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^\d{17}$')][string]$SteamId,
    [string]$RulesPath = (Join-Path $PSScriptRoot 'rules.json'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'local')
)
$ErrorActionPreference = 'Stop'
$accountNumber = [long]$SteamId - [long]76561197960265728
if ($accountNumber -lt 1 -or $accountNumber -gt [uint32]::MaxValue) { throw 'Invalid individual SteamID64.' }
$rules = Get-Content -LiteralPath $RulesPath -Raw | ConvertFrom-Json
if ($rules.schemaVersion -ne 1) { throw 'Unsupported rules version.' }
$planPath = Join-Path $OutputDirectory 'plan.json'
if (Test-Path -LiteralPath $planPath) { throw 'plan.json already exists. Choose a new OutputDirectory to preserve your edits.' }
$secret = Read-Host 'Steam Web API key (input hidden; never saved)' -AsSecureString
$credential = New-Object Net.NetworkCredential('', $secret)
try {
    $parameters = @{key=$credential.Password; steamid=$SteamId; include_appinfo=1; include_played_free_games=1; format='json'}
    try {
        $response = Invoke-RestMethod 'https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/' -Method Get -Body $parameters -TimeoutSec 30
    } catch { throw 'Owned-games request failed. Check your key, ID, connection and game-details visibility.' }
} finally { $parameters=$null; $credential=$null; $secret=$null }
$games = @($response.response.games)
if (!$response.response.games) { throw 'No games returned. Check SteamID64 and game-details visibility.' }
$rows = @(); $buckets = [ordered]@{}; $index = 0
foreach ($game in $games) {
    $index++
    Write-Progress -Activity 'Fetching Steam Store genres' -Status "$index / $($games.Count): $($game.name)" -PercentComplete (100*$index/$games.Count)
    $genres = @(); $status = 'unavailable'; $appType = ''
    try {
        $data = Invoke-RestMethod "https://store.steampowered.com/api/appdetails?appids=$($game.appid)&l=english&cc=us" -TimeoutSec 20
        $entry = $data.([string]$game.appid)
        if ($entry.success) {
            $genres = @($entry.data.genres | ForEach-Object { $_.description })
            $appType = [string]$entry.data.type; $status = 'retrieved'
        }
    } catch { $status = 'request failed' }
    $category = 'REVIEW'; $reason = 'No matching rule or metadata unavailable'
    $override = $rules.overrides.PSObject.Properties[[string]$game.appid]
    if ($override) { $category = [string]$override.Value; $reason = 'AppID override' }
    elseif ($appType -eq 'software') { $category = 'TOOLS'; $reason = 'Store type: software' }
    else {
        foreach ($rule in $rules.genrePriority) {
            if ($rule.genre -in $genres) { $category = [string]$rule.collection; $reason = "Genre: $($rule.genre)"; break }
        }
    }
    $category = $category.Trim().ToUpperInvariant()
    if (!$category -or $category -in @('FAVORITES','FAVORITE','HIDDEN')) { throw 'Invalid category in rules.' }
    if (!$buckets.Contains($category)) { $buckets[$category] = @() }
    $buckets[$category] += [int]$game.appid
    $rows += [pscustomobject]@{AppID=$game.appid; Game=$game.name; Genres=($genres -join '; '); Category=$category; Reason=$reason; Metadata=$status}
    Start-Sleep -Milliseconds 1500
}
Write-Progress -Activity 'Fetching Steam Store genres' -Completed
$collections = @($buckets.Keys | ForEach-Object { [pscustomobject]@{name=$_; appids=@($buckets[$_])} })
$plan = [pscustomobject]@{schemaVersion=1; accountId=[string]$accountNumber; collections=$collections}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planPath -Encoding UTF8
$rows | Sort-Object Category,Game | Export-Csv (Join-Path $OutputDirectory 'review.csv') -NoTypeInformation -Encoding UTF8
Write-Host "Created $planPath and review.csv for $($games.Count) entries. Review/edit plan.json before applying."
Write-Host 'Store genres are broad; community tags are not fetched. REVIEW entries need your attention.'
