$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('steam-organizer-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
function Assert($condition, [string]$message) { if (!$condition) { throw $message } }
function Record([string]$key, $value) {
    return ,@($key, [pscustomobject]@{key=$key; timestamp=1; version='1'; value=($value | ConvertTo-Json -Depth 15 -Compress)})
}
try {
    $file = Join-Path $work 'cloud-storage-namespace-1.json'
    $planPath = Join-Path $work 'plan.json'
    $fixture = @(
        (Record 'collection-bootstrap-complete' $true),
        (Record 'unrelated-setting' @{enabled=$true}),
        (Record 'user-collections.favorite' @{id='favorite'; name='Favorites'; added=@(101); removed=@()}),
        (Record 'user-collections.hidden' @{id='hidden'; name='Hidden'; added=@(202); removed=@()}),
        (Record 'user-collections.uc-one' @{id='uc-one'; name='RPG'; added=@(101,202); removed=@(); filterSpec=@{active=$true}}),
        (Record 'user-collections.uc-other' @{id='uc-other'; name='Other'; added=@(101,999); removed=@(); filterSpec=@{active=$true}})
    )
    $original = ConvertTo-Json -InputObject $fixture -Depth 30 -Compress
    [IO.File]::WriteAllText($file,$original)
    $config = @{schemaVersion=1; collections=@(@{name='RPG';appids=@(101)},@{name='STRATEGY';appids=@(202)})}
    $config | ConvertTo-Json -Depth 10 | Set-Content $planPath
    $updater = Join-Path $root 'Update-Steam-Collections.ps1'
    & $updater -CollectionPath $file -PlanPath $planPath
    Assert ([IO.File]::ReadAllText($file) -ceq $original) 'Preview modified source'
    & $updater -CollectionPath $file -PlanPath $planPath -Apply
    $updated = Get-Content $file -Raw | ConvertFrom-Json
    $lookup = @{}; foreach ($pair in $updated) { $lookup[$pair[0]]=$pair[1] }
    foreach ($key in @('unrelated-setting','user-collections.favorite','user-collections.hidden')) {
        $old = @($fixture | Where-Object { $_[0] -eq $key })[0][1]
        Assert (($lookup[$key] | ConvertTo-Json -Compress) -ceq ($old | ConvertTo-Json -Compress)) "Changed protected $key"
    }
    $rpg = $lookup['user-collections.uc-one'].value | ConvertFrom-Json
    Assert (!$rpg.filterSpec -and $rpg.added.Count -eq 1 -and $rpg.added[0] -eq 101) 'RPG conversion failed'
    $other = $lookup['user-collections.uc-other'].value | ConvertFrom-Json
    Assert ($other.added.Count -eq 1 -and $other.added[0] -eq 999 -and 101 -in $other.removed -and 202 -in $other.removed) 'Other collection exclusion failed'
    $once = Get-Content $file -Raw
    & $updater -CollectionPath $file -PlanPath $planPath -Apply
    Assert ((Get-Content $file -Raw) -ceq $once) 'Repeat run changed data'
    $backup = Get-ChildItem "$file*.bak" | Where-Object { [IO.File]::ReadAllText($_.FullName) -ceq $original } | Select-Object -First 1
    & $updater -CollectionPath $file -RestoreBackup $backup.FullName
    Assert ([IO.File]::ReadAllText($file) -ceq $original) 'Restore failed'
    $config.collections[1].appids=@(101)
    $config | ConvertTo-Json -Depth 10 | Set-Content $planPath
    $failed=$false
    try { & $updater -CollectionPath $file -PlanPath $planPath -Apply } catch { $failed=$true }
    Assert $failed 'Duplicate AppID was accepted'
    Assert ([IO.File]::ReadAllText($file) -ceq $original) 'Invalid plan modified source'
    # Mock remote calls and secret input: no account or network is used.
    function Read-Host { param($Prompt,[switch]$AsSecureString) return (ConvertTo-SecureString 'test-only' -AsPlainText -Force) }
    function Start-Sleep { param($Milliseconds) }
    function Invoke-RestMethod {
        param($Uri,$Method,$Body,$TimeoutSec)
        if ($Uri -like '*GetOwnedGames*') {
            return @{response=@{games=@(@{appid=101;name='Synthetic RPG'},@{appid=202;name='Synthetic Missing'},@{appid=303;name='Synthetic Override'})}}
        }
        if ($Uri -like '*appids=101&*') { return @{'101'=@{success=$true;data=@{type='game';genres=@(@{description='Action'},@{description='RPG'})}}} }
        return @{'202'=@{success=$false};'303'=@{success=$false}}
    }
    $rulePath = Join-Path $work 'rules.json'
    @{schemaVersion=1;overrides=@{'303'='CUSTOM'};genrePriority=@(@{genre='RPG';collection='RPG'},@{genre='Action';collection='ACTION'})} | ConvertTo-Json -Depth 10 | Set-Content $rulePath
    $generatedDir = Join-Path $work 'generated'
    & (Join-Path $root 'New-Steam-Plan.ps1') -SteamId ([string]([long]76561197960265728+12345)) -RulesPath $rulePath -OutputDirectory $generatedDir
    $generated = Get-Content (Join-Path $generatedDir 'plan.json') -Raw | ConvertFrom-Json
    Assert ($generated.accountId -eq '12345') 'Account mapping failed'
    Assert (($generated.collections | Where-Object name -eq 'RPG').appids[0] -eq 101) 'Genre priority failed'
    Assert (($generated.collections | Where-Object name -eq 'REVIEW').appids[0] -eq 202) 'Missing metadata fallback failed'
    Assert (($generated.collections | Where-Object name -eq 'CUSTOM').appids[0] -eq 303) 'Override failed'
    Assert (!(Get-Content (Join-Path $generatedDir 'plan.json') -Raw).Contains('test-only')) 'Secret persisted'
    Write-Host 'PASS: preview, conversion, exclusions, protected records, repeat run, restore, duplicate rejection.'
} finally { Remove-Item -LiteralPath $work -Recurse -Force }
