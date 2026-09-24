# Pimax Game Manager - library images, library order and per-game settings for Pimax Play
param([switch]$Test)

# --- Run as admin (needed to restart the Pimax service) ---
if (-not $Test) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
        exit
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PimaxDir    = Join-Path $env:APPDATA 'Pimax'
$ManifestDir = Join-Path $PimaxDir 'manifest'
# The app's own data lives outside Pimax's folder so a Pimax update can't wipe it
$DataDir     = Join-Path $env:APPDATA 'PimaxGameManager'
$CoverDir    = Join-Path $DataDir 'covers'
$BackupDir   = Join-Path $DataDir 'backups'
$SnapshotDir = Join-Path $DataDir 'snapshots'
$LegacyBackupDir = Join-Path $PimaxDir 'cover-backups'
$ServiceName = 'PiServiceLauncher'
$DefaultClient = 'C:\Program Files\Pimax\PimaxClient\pimaxui\PimaxClient.exe'
foreach ($d in $DataDir, $CoverDir, $BackupDir, $SnapshotDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
# One-time carry-over from older versions (copies only; nothing is deleted)
try {
    if (Test-Path $LegacyBackupDir) {
        foreach ($f in Get-ChildItem $LegacyBackupDir -Recurse -File) {
            $dst = Join-Path $BackupDir $f.FullName.Substring($LegacyBackupDir.Length).TrimStart('\')
            if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null; Copy-Item -LiteralPath $f.FullName $dst }
        }
    }
    $legacyCfg = Join-Path $PimaxDir 'cover-changer-settings.json'; $newCfg = Join-Path $DataDir 'settings.json'
    if ((Test-Path $legacyCfg) -and -not (Test-Path $newCfg)) { Copy-Item $legacyCfg $newCfg }
} catch { }
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$AppVersion = '1.4.2'
$RepoApi = 'https://api.github.com/repos/SFXShannon/pimax-game-manager/releases/latest'

# ---------- Library ----------
function Get-PimaxGames {
    $games = @()
    foreach ($f in Get-ChildItem $ManifestDir -Filter *.json -ErrorAction SilentlyContinue) {
        try {
            $raw = [IO.File]::ReadAllText($f.FullName).TrimStart([char]0xFEFF)
            $j = $raw | ConvertFrom-Json
            $name = if ($j.name) { $j.name } elseif ($j.productName) { $j.productName } else { $f.BaseName }
            $src = switch ($j.source) { 'pimax_import' { 'Imported' } 'steam' { 'SteamVR' } 'oculus' { 'Oculus' } default { if ($j.source) { $j.source } else { 'Other' } } }
            $games += [pscustomobject]@{ Name = $name; Source = $src; Icon = $j.icon; File = $f.FullName }
        } catch { }
    }
    $games | Sort-Object @{ Expression = { if ($_.Source -eq 'Imported') { 0 } else { 1 } } }, Name
}

function Get-ClientPath {
    $p = Get-Process PimaxClient -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
    if ($p) { return $p.Path }
    return $DefaultClient
}

function Load-Bitmap([string]$source) {
    $bmp = New-Object Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    if ($source -match '^https?://') {
        $bytes = (New-Object Net.WebClient).DownloadData($source)
        $bmp.StreamSource = New-Object IO.MemoryStream(,$bytes)
    } else {
        $bmp.StreamSource = New-Object IO.MemoryStream(,[IO.File]::ReadAllBytes($source))
    }
    $bmp.EndInit(); $bmp.Freeze()
    return $bmp
}

# ---------- Actions ----------
function Restart-Pimax {
    $client = Get-ClientPath
    Get-Process PimaxClient -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    # The library is held by PiPlayService.exe, which survives a plain service restart.
    # Stop the service, stop PiPlayService, then start the service; Pimax Play starts a fresh PiPlayService.
    $svcOk = $true
    try {
        Stop-Service $ServiceName -Force -ErrorAction Stop
        Get-Process PiPlayService -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Start-Service $ServiceName -ErrorAction Stop
    } catch {
        $svcOk = $false
        try { Start-Service $ServiceName -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Seconds 3
    if (Test-Path $client) { Start-Process $client }
    return $svcOk
}

function Save-Cover($game, [string]$source) {
    if ($game.Source -ne 'Imported') { throw "Pimax replaces images for $($game.Source) games every time it starts, so only imported games can have a custom image." }
    $id = [IO.Path]::GetFileNameWithoutExtension($game.File)
    $ext = [IO.Path]::GetExtension(($source -split '\?')[0]).ToLower()
    if ($ext -notin '.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif') { $ext = '.jpg' }
    $dest = Join-Path $CoverDir ("{0}_{1}{2}" -f $id, (Get-Date -Format 'yyyyMMddHHmmss'), $ext)

    if ($source -match '^https?://') { (New-Object Net.WebClient).DownloadFile($source, $dest) }
    else { Copy-Item -LiteralPath $source -Destination $dest -Force }
    try { Load-Bitmap $dest | Out-Null } catch { Remove-Item $dest -Force; throw "That file isn't a readable image." }

    $backup = Join-Path $BackupDir ([IO.Path]::GetFileName($game.File) + '.orig')
    if (-not (Test-Path $backup)) { Copy-Item $game.File $backup }

    Get-Process PimaxClient -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $j = [IO.File]::ReadAllText($game.File).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ($j.PSObject.Properties.Name -contains 'icon') { $j.icon = $dest } else { $j | Add-Member -NotePropertyName icon -NotePropertyValue $dest }
    [IO.File]::WriteAllText($game.File, ($j | ConvertTo-Json -Compress -Depth 10), $Utf8NoBom)
    return $dest
}

function Restore-Cover($game) {
    $backup = Join-Path $BackupDir ([IO.Path]::GetFileName($game.File) + '.orig')
    if (-not (Test-Path $backup)) { $backup = Join-Path $LegacyBackupDir ([IO.Path]::GetFileName($game.File) + '.orig') }
    if (-not (Test-Path $backup)) { throw 'No backup for this game - it still has its original image.' }
    Get-Process PimaxClient -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Copy-Item $backup $game.File -Force
    Remove-Item $backup -Force
}

# ---------- Image finder (Steam + SteamGridDB) ----------
$SettingsFile = Join-Path $DataDir 'settings.json'
function Get-AppSetting([string]$name) {
    try { return ([IO.File]::ReadAllText($SettingsFile) | ConvertFrom-Json).$name } catch { return $null }
}
function Set-AppSetting([string]$name, $value) {
    $o = [ordered]@{}
    try { $j = [IO.File]::ReadAllText($SettingsFile) | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $o[$p.Name] = $p.Value } } catch { }
    $o[$name] = $value
    [IO.File]::WriteAllText($SettingsFile, ([pscustomobject]$o | ConvertTo-Json), $Utf8NoBom)
}
function Get-SgdbKey { $k = Get-AppSetting 'sgdbKey'; if ($k) { return [string]$k }; return '' }
function Set-SgdbKey([string]$key) { Set-AppSetting 'sgdbKey' $key }

function Resolve-SteamAppId($game) {
    $j = [IO.File]::ReadAllText($game.File).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ([string]$j.id -match '^steam\.app\.(\d+)$') { return $Matches[1] }
    $route = [string]$j.route
    if ($route -match '^steam://\w+/(\d+)') { return $Matches[1] }
    if ($route -like '*.lnk' -and (Test-Path -LiteralPath $route)) {
        try { $route = (New-Object -ComObject WScript.Shell).CreateShortcut($route).TargetPath } catch { }
    }
    if ($route -match '^(.*\\steamapps)\\common\\([^\\]+)') {
        $apps = $Matches[1]; $folder = $Matches[2]
        foreach ($acf in Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $txt = [IO.File]::ReadAllText($acf.FullName)
            if ($txt -match '"installdir"\s+"([^"]+)"' -and $Matches[1] -ieq $folder) {
                if ($txt -match '"appid"\s+"(\d+)"') { return $Matches[1] }
            }
        }
    }
    return $null
}

function New-Art([string]$label, [string]$thumb, [string]$url) { [pscustomobject]@{ Label = $label; Thumb = $thumb; Url = $url } }

function Get-SteamArt([string]$appId, [string]$name) {
    $base = "https://shared.steamstatic.com/store_item_assets/steam/apps/$appId"
    New-Art "$name - Steam banner" "$base/header.jpg" "$base/header.jpg"
    New-Art "$name - Steam capsule" "$base/capsule_616x353.jpg" "$base/capsule_616x353.jpg"
}

function Search-SteamStore([string]$term) {
    $r = Invoke-RestMethod -UseBasicParsing -Uri ("https://store.steampowered.com/api/storesearch/?term={0}&cc=us&l=english" -f [uri]::EscapeDataString($term))
    @($r.items) | Select-Object -First 5
}

function Invoke-Sgdb([string]$path) {
    Invoke-RestMethod -UseBasicParsing -Uri "https://www.steamgriddb.com/api/v2/$path" -Headers @{ Authorization = "Bearer $(Get-SgdbKey)" }
}

function Get-SgdbGrids([string]$kind, [string]$id, [string]$name, [int]$max) {
    $r = Invoke-Sgdb "grids/$kind/$id`?dimensions=460x215,920x430&types=static"
    @($r.data) | Select-Object -First $max | ForEach-Object {
        New-Art "$name - SteamGridDB $($_.width)x$($_.height)" $_.thumb $_.url
    }
}

function Find-Art($game, [string]$term, [bool]$exact) {
    $items = New-Object Collections.ArrayList
    $notes = @()
    $hasKey = [bool](Get-SgdbKey)
    $appId = if ($exact) { Resolve-SteamAppId $game } else { $null }
    if ($appId) {
        $notes += "Matched Steam app $appId."
        foreach ($a in Get-SteamArt $appId $game.Name) { [void]$items.Add($a) }
        if ($hasKey) {
            try { foreach ($a in Get-SgdbGrids 'steam' $appId $game.Name 30) { [void]$items.Add($a) } }
            catch { $notes += "SteamGridDB error: $($_.Exception.Message)" }
        }
    } else {
        try { foreach ($s in Search-SteamStore $term) { [void]$items.Add((Get-SteamArt ([string]$s.id) $s.name)[0]) } }
        catch { $notes += "Steam search failed: $($_.Exception.Message)" }
        if ($hasKey) {
            try {
                $found = @((Invoke-Sgdb ("search/autocomplete/{0}" -f [uri]::EscapeDataString($term))).data) | Select-Object -First 3
                foreach ($g in $found) { foreach ($a in Get-SgdbGrids 'game' ([string]$g.id) $g.name 10) { [void]$items.Add($a) } }
            } catch { $notes += "SteamGridDB error: $($_.Exception.Message)" }
        }
    }
    if (-not $hasKey) { $notes += 'Add a SteamGridDB key for many more choices.' }
    [pscustomobject]@{ Items = $items; Note = ($notes -join ' ') }
}

# ---------- Library order (Pimax "pin to top" list) ----------
$ClientConfig = Join-Path $env:APPDATA 'PimaxClient\config.json'

function Get-PinnedIds([string]$text) {
    if (-not $text) { if (-not (Test-Path $ClientConfig)) { return @() }; $text = [IO.File]::ReadAllText($ClientConfig) }
    $m = [regex]::Match($text, '"pinToTopGameArray"\s*:\s*\[([^\]]*)\]')
    if (-not $m.Success) { return @() }
    @([regex]::Matches($m.Groups[1].Value, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' })
}

function Get-GameId($game) {
    try { $j = [IO.File]::ReadAllText($game.File).TrimStart([char]0xFEFF) | ConvertFrom-Json; if ($j.id) { return [string]$j.id } } catch { }
    return [IO.Path]::GetFileNameWithoutExtension($game.File)
}

# Approximates Pimax's own order: Steam by app ID, then other stores, then imports in the order added
function Get-PimaxOrderKey($game, [string]$id) {
    if ($id -match '^steam\.app\.(\d+)$') { return '1-{0:D12}' -f [long]$Matches[1] }
    if ($game.Source -ne 'Imported') { return '2-' + $game.Name }
    return '3-' + (Get-Item $game.File).CreationTime.ToString('yyyyMMddHHmmss')
}

function Save-PinnedOrder([string[]]$ids) {
    if (-not (Test-Path $ClientConfig)) { throw "Pimax Play settings file not found: $ClientConfig" }
    $backup = Join-Path $BackupDir 'PimaxClient-config.json.orig'
    if (-not (Test-Path $backup)) { Copy-Item $ClientConfig $backup }
    Get-Process PimaxClient -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $text = Set-PinnedIdsInText ([IO.File]::ReadAllText($ClientConfig)) $ids
    [IO.File]::WriteAllText($ClientConfig, $text, $Utf8NoBom)
}

function Set-PinnedIdsInText([string]$text, [string[]]$ids) {
    $esc = @($ids | ForEach-Object { '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"' })
    $arr = if ($esc.Count) { "[`n`t`t" + ($esc -join ",`n`t`t") + "`n`t]" } else { '[]' }
    $new = '"pinToTopGameArray": ' + $arr
    $rx = [regex]'"pinToTopGameArray"\s*:\s*\[[^\]]*\]'
    if ($rx.IsMatch($text)) { $text = $rx.Replace($text, [Text.RegularExpressions.MatchEvaluator]{ param($m) $new }, 1) }
    else {
        $end = $text.LastIndexOf('}')
        if ($end -lt 0) { throw 'Pimax Play settings file looks damaged; nothing was changed.' }
        $head = $text.Substring(0, $end).TrimEnd()
        $sep = if ($head.EndsWith('{')) { "`n`t" } else { ",`n`t" }
        $text = $head + $sep + $new + "`n" + $text.Substring($end)
    }
    $check = Get-PinnedIds $text
    if (($check -join '|') -ne ($ids -join '|')) { throw 'Order did not verify; nothing was changed.' }
    return $text
}

# ---------- Per-game settings (Pimax AppConfig) ----------
$AppConfigDir = Join-Path $PimaxDir 'AppConfig'
$Inv = [Globalization.CultureInfo]::InvariantCulture

# Mirrors the per-game settings in Pimax Play (keys, options and ranges from its settings screen)
$SettingDefs = @(
    @{ Key = 'piplay_display_quality_level'; Label = 'Image quality'; Kind = 'choice'; Default = 3
       Options = @(@(-1, 'Auto'), @(0, 'Low'), @(1, 'Medium'), @(2, 'High'), @(3, 'Custom')) },
    @{ Key = 'runtime_pixels_per_display_pixel_rate'; Label = 'Render resolution'; Kind = 'number'; Min = 0.1; Max = 2.0; Default = 1.0
       Tip = 'Used when Image quality is Custom. Low = 0.5, Medium = 0.75, High = 1.0' },
    @{ Key = 'runtime_overlay_render_scale'; Label = 'Overlay render factor'; Kind = 'number'; Min = 0.5; Max = 1.5; Default = 1.0 },
    @{ Key = 'runtime_quadviews_rendering_level'; Label = 'Quad View'; Kind = 'choice'; Default = 1
       Options = @(@(-1, 'Off'), @(0, 'Performance'), @(1, 'Balance'), @(2, 'Quality'), @(3, 'Ultimate'), @(5, 'Custom (fine-tune in Pimax Play)')) },
    @{ Key = 'runtime_fov_level'; Label = 'FOV crop'; Kind = 'choice'; Default = 0
       Options = @(@(0, 'Level 0 - widest (Normal/Wide)'), @(1, 'Level 1 - narrower'), @(2, 'Level 2 - narrower still'), @(3, 'Level 3 - narrowest (4-level headsets)'), @(9, 'Custom (fine-tune in Pimax Play)')) },
    @{ Key = 'runtime_foveated_rendering_level'; Label = 'Center rendering'; Kind = 'choice'; Default = 1
       Options = @(@(-1, 'Off'), @(0, 'Performance'), @(1, 'Balanced'), @(2, 'Quality')) },
    @{ Key = 'runtime_gpu_upscaling_algorithm'; Label = 'GPU upscaling'; Kind = 'choice'; Default = 0
       Options = @(@(0, 'None'), @(1, 'FSR'), @(2, 'NIS')) },
    @{ Key = 'runtime_gpu_upscaling_scaling'; Label = 'Upscaling ratio'; Kind = 'number'; Min = 1.0; Max = 2.0; Default = 1.3
       Tip = 'Used with FSR/NIS. Quality 1.3, Balanced 1.6, Performance 1.9' },
    @{ Key = 'runtime_gpu_upscaling_sharpness'; Label = 'Sharpness'; Kind = 'number'; Min = 0.0; Max = 1.0; Default = 0.6 },
    @{ Key = 'runtime_dbg_asw_enable'; Label = 'Smart Smoothing'; Kind = 'choice'; Default = 0
       Options = @(@(0, 'Off'), @(1, 'On')) },
    @{ Key = 'runtime_dbg_force_framerate_divide_by'; Label = 'Lock to half refresh rate'; Kind = 'choice'; Default = 1
       Options = @(@(1, 'Off'), @(2, 'On')) },
    @{ Key = 'piplay_color_tone_preset'; Label = 'Color tone'; Kind = 'choice'; Default = 0
       Options = @(@(0, 'Standard'), @(1, 'Cooler'), @(2, 'Cool'), @(3, 'Warm'), @(4, 'Warmer')) }
)
$QualityRates = @{ 0 = 0.5; 1 = 0.75; 2 = 1.0 }

function Get-SettingsPath([string]$id) { Join-Path $AppConfigDir ("{0}.json" -f $id) }

# Returns an ordered map of every key in the file (unknown keys kept as-is)
function Read-GameSettings([string]$id) {
    $map = [ordered]@{}
    $p = Get-SettingsPath $id
    if (-not (Test-Path -LiteralPath $p)) { return $map }
    $j = [IO.File]::ReadAllText($p).TrimStart([char]0xFEFF) | ConvertFrom-Json
    foreach ($prop in $j.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
    return $map
}

function Format-SettingValue($key, $value) {
    $def = $SettingDefs | Where-Object { $_.Key -eq $key } | Select-Object -First 1
    if ($value -is [pscustomobject]) { return ($value | ConvertTo-Json -Compress -Depth 5) }
    if ($value -is [string]) { return ($value | ConvertTo-Json) }
    if ($value -is [bool]) { return $(if ($value) { 'true' } else { 'false' }) }
    if ($def -and $def.Kind -eq 'number') {
        $s = ([double]$value).ToString('R', $Inv)
        if ($s -notmatch '[.eE]') { $s += '.0' }
        return $s
    }
    if ($value -is [double] -or $value -is [single] -or $value -is [decimal]) { return ([double]$value).ToString('R', $Inv) }
    return ([long]$value).ToString($Inv)
}

# Writes in Pimax's own layout; an empty game file is removed so the game falls back to global
function Write-GameSettings([string]$id, $map) {
    $p = Get-SettingsPath $id
    if (-not (Test-Path $AppConfigDir)) { New-Item -ItemType Directory -Path $AppConfigDir | Out-Null }
    if ($map.Count -eq 0 -and $id -ne 'global') { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }; return }
    $lines = foreach ($k in ($map.Keys | Sort-Object)) { '   "{0}" : {1}' -f $k, (Format-SettingValue $k $map[$k]) }
    $text = "{`n" + ($lines -join ",`n") + "`n}`n"
    $null = $text | ConvertFrom-Json   # validate before writing
    [IO.File]::WriteAllText($p, $text, $Utf8NoBom)
}

function Backup-SettingsOnce([string[]]$ids) {
    $dir = Join-Path $BackupDir 'settings'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    foreach ($id in $ids) {
        $src = Get-SettingsPath $id; $dst = Join-Path $dir ("{0}.json.orig" -f $id); $none = Join-Path $dir ("{0}.none" -f $id)
        if ((Test-Path $dst) -or (Test-Path $none)) { continue }
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src $dst } else { New-Item -ItemType File -Path $none | Out-Null }
    }
}

# Pimax's service keeps settings in memory, so change files only while it is stopped
function Invoke-WhilePimaxStopped([scriptblock]$action) {
    $client = Get-ClientPath
    Get-Process PimaxClient -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    $svcOk = $true
    try { Stop-Service $ServiceName -Force -ErrorAction Stop } catch { $svcOk = $false }
    Get-Process PiPlayService -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $err = $null
    try { & $action } catch { $err = $_ }
    try { Start-Service $ServiceName -ErrorAction Stop } catch { $svcOk = $false }
    Start-Sleep -Seconds 3
    if (Test-Path $client) { Start-Process $client }
    if ($err) { throw $err }
    return $svcOk
}

# ---------- Backups (snapshots of images, library order and game settings) ----------
function Get-Route($game) {
    try { return [string](([IO.File]::ReadAllText($game.File).TrimStart([char]0xFEFF) | ConvertFrom-Json).route) } catch { return '' }
}

function Test-HasOrigBackup($game) {
    $n = [IO.Path]::GetFileName($game.File) + '.orig'
    return (Test-Path (Join-Path $BackupDir $n)) -or (Test-Path (Join-Path $LegacyBackupDir $n))
}

# Games whose tile image can be customised and kept: imported games (Pimax rebuilds Steam and Oculus entries itself)
function Get-CustomImages {
    foreach ($g in Get-PimaxGames) {
        $icon = [string]$g.Icon
        if (-not $icon) { continue }
        if ($g.Source -eq 'Imported') {
            [pscustomobject]@{ Id = (Get-GameId $g); Name = $g.Name; Route = (Get-Route $g); Icon = $icon }
        }
    }
}

function Get-StateFingerprint {
    $sb = New-Object Text.StringBuilder
    foreach ($i in (Get-CustomImages | Sort-Object Id)) {
        $h = if ($i.Icon -notmatch '^https?://' -and (Test-Path -LiteralPath $i.Icon)) { (Get-FileHash -LiteralPath $i.Icon -Algorithm MD5).Hash } else { $i.Icon }
        [void]$sb.Append("img|$($i.Id)|$h`n")
    }
    [void]$sb.Append('pins|' + ((Get-PinnedIds) -join ',') + "`n")
    foreach ($f in (Get-ChildItem $AppConfigDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name)) {
        [void]$sb.Append("cfg|$($f.Name)|$((Get-FileHash $f.FullName -Algorithm MD5).Hash)`n")
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
    return [BitConverter]::ToString((New-Object Security.Cryptography.MD5CryptoServiceProvider).ComputeHash($bytes)).Replace('-', '')
}

function Get-Snapshots {
    $list = foreach ($d in Get-ChildItem $SnapshotDir -Directory -ErrorAction SilentlyContinue) {
        $meta = Join-Path $d.FullName 'snapshot.json'
        if (-not (Test-Path $meta)) { continue }
        try { $j = [IO.File]::ReadAllText($meta) | ConvertFrom-Json } catch { continue }
        $j | Add-Member -NotePropertyName Path -NotePropertyValue $d.FullName -Force
        $j
    }
    @($list | Sort-Object { [datetime]$_.created } -Descending)
}

# Saves a snapshot; with -IfChanged it is skipped when nothing differs from the newest one
function New-Snapshot([string]$reason, [switch]$IfChanged) {
    $fp = Get-StateFingerprint
    if ($IfChanged) { $last = Get-Snapshots | Select-Object -First 1; if ($last -and $last.fingerprint -eq $fp) { return $null } }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $dir = Join-Path $SnapshotDir $stamp; $n = 2
    while (Test-Path $dir) { $dir = Join-Path $SnapshotDir "$stamp-$n"; $n++ }
    New-Item -ItemType Directory -Path (Join-Path $dir 'images') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'settings') -Force | Out-Null
    $images = foreach ($i in Get-CustomImages) {
        $file = $null
        if ($i.Icon -notmatch '^https?://' -and (Test-Path -LiteralPath $i.Icon)) {
            $file = 'images/' + $i.Id + [IO.Path]::GetExtension($i.Icon).ToLower()
            Copy-Item -LiteralPath $i.Icon (Join-Path $dir $file.Replace('/', '\')) -Force
        }
        [pscustomobject]@{ id = $i.Id; name = $i.Name; route = $i.Route; file = $file; url = $(if ($i.Icon -match '^https?://') { $i.Icon } else { $null }) }
    }
    foreach ($f in Get-ChildItem $AppConfigDir -Filter *.json -ErrorAction SilentlyContinue) { Copy-Item $f.FullName (Join-Path $dir 'settings') }
    $games = foreach ($g in Get-PimaxGames) { [pscustomobject]@{ id = (Get-GameId $g); name = $g.Name; route = (Get-Route $g) } }
    $meta = [pscustomobject]@{
        created = (Get-Date).ToString('o'); reason = $reason; appVersion = $AppVersion; fingerprint = $fp
        pinned = @(Get-PinnedIds); images = @($images); games = @($games)
        settings = @(Get-ChildItem (Join-Path $dir 'settings') -Filter *.json | ForEach-Object BaseName)
    }
    [IO.File]::WriteAllText((Join-Path $dir 'snapshot.json'), ($meta | ConvertTo-Json -Depth 6), $Utf8NoBom)
    # keep the newest 20 automatic snapshots; ones you make yourself are kept
    Get-Snapshots | Where-Object { $_.reason -eq 'Automatic' } | Select-Object -Skip 20 | ForEach-Object { Remove-Item -LiteralPath $_.Path -Recurse -Force }
    return $dir
}

function Save-AutoSnapshot { try { [void](New-Snapshot 'Automatic' -IfChanged) } catch { } }

# Maps a snapshot's game ID to the current one (re-imported games get new IDs, so fall back to the exe path)
function Resolve-SnapshotId($snap, [string]$oldId, $byId, $byRoute) {
    if ($oldId -eq 'global' -or $byId.ContainsKey($oldId)) { return $oldId }
    $old = $snap.games | Where-Object { $_.id -eq $oldId } | Select-Object -First 1
    $route = if ($old) { [string]$old.route } else { ($snap.images | Where-Object { $_.id -eq $oldId } | Select-Object -First 1).route }
    if ($route -and $byRoute.ContainsKey($route.ToLower())) { return $byRoute[$route.ToLower()] }
    return $null
}

function Get-CurrentIndex {
    $byId = @{}; $byRoute = @{}
    foreach ($g in Get-PimaxGames) {
        $id = Get-GameId $g; $byId[$id] = $g
        $r = Get-Route $g; if ($r) { $byRoute[$r.ToLower()] = $id }
    }
    [pscustomobject]@{ ById = $byId; ByRoute = $byRoute }
}

# What in the snapshot looks lost now (things Pimax resets, not normal edits)
function Compare-Snapshot($snap) {
    $idx = Get-CurrentIndex
    $lostImages = @(foreach ($i in $snap.images) {
        $cur = Resolve-SnapshotId $snap $i.id $idx.ById $idx.ByRoute
        if (-not $cur) { continue }
        $icon = [string]$idx.ById[$cur].Icon
        if (-not $icon -or ($i.file -and $icon -match '^https?://')) { $i.name }
    })
    $pinsNow = @(Get-PinnedIds)
    $lostPins = ($snap.pinned.Count -gt 0 -and $pinsNow.Count -eq 0)
    $lostSettings = @(foreach ($s in $snap.settings) {
        $cur = Resolve-SnapshotId $snap $s $idx.ById $idx.ByRoute
        if ($cur -and -not (Test-Path (Get-SettingsPath $cur))) { $s }
    })
    [pscustomobject]@{ Images = $lostImages; Pins = $lostPins; Settings = $lostSettings
                       Any = ($lostImages.Count -gt 0 -or $lostPins -or $lostSettings.Count -gt 0) }
}

function Restore-Snapshot($snap, [bool]$images, [bool]$order, [bool]$settings) {
    [void](New-Snapshot 'Before restore')
    $idx = Get-CurrentIndex
    $report = [ordered]@{ Images = 0; Order = 0; Settings = 0; Skipped = @() }
    $svcOk = Invoke-WhilePimaxStopped {
        if ($images) {
            foreach ($i in $snap.images) {
                $cur = Resolve-SnapshotId $snap $i.id $idx.ById $idx.ByRoute
                if (-not $cur) { $report.Skipped += $i.name; continue }
                $g = $idx.ById[$cur]
                $icon = $null
                if ($i.file) {
                    $src = Join-Path $snap.Path $i.file.Replace('/', '\')
                    if (Test-Path -LiteralPath $src) {
                        $icon = Join-Path $CoverDir ("{0}_restored_{1}{2}" -f $cur, (Get-Date -Format 'yyyyMMddHHmmss'), [IO.Path]::GetExtension($src))
                        Copy-Item -LiteralPath $src $icon -Force
                    }
                } elseif ($i.url) { $icon = $i.url }
                if (-not $icon) { $report.Skipped += $i.name; continue }
                $orig = Join-Path $BackupDir ([IO.Path]::GetFileName($g.File) + '.orig')
                if (-not (Test-HasOrigBackup $g)) { Copy-Item $g.File $orig }
                $j = [IO.File]::ReadAllText($g.File).TrimStart([char]0xFEFF) | ConvertFrom-Json
                if ($j.PSObject.Properties.Name -contains 'icon') { $j.icon = $icon } else { $j | Add-Member -NotePropertyName icon -NotePropertyValue $icon }
                [IO.File]::WriteAllText($g.File, ($j | ConvertTo-Json -Compress -Depth 10), $Utf8NoBom)
                $report.Images++
            }
        }
        if ($order -and (Test-Path $ClientConfig)) {
            $ids = @(foreach ($p in $snap.pinned) { $c = Resolve-SnapshotId $snap $p $idx.ById $idx.ByRoute; if ($c) { $c } else { $p } })
            $text = Set-PinnedIdsInText ([IO.File]::ReadAllText($ClientConfig)) $ids
            [IO.File]::WriteAllText($ClientConfig, $text, $Utf8NoBom)
            $report.Order = $ids.Count
        }
        if ($settings) {
            if (-not (Test-Path $AppConfigDir)) { New-Item -ItemType Directory -Path $AppConfigDir | Out-Null }
            foreach ($s in $snap.settings) {
                $cur = Resolve-SnapshotId $snap $s $idx.ById $idx.ByRoute
                if (-not $cur) { if ($snap.games | Where-Object { $_.id -eq $s }) { $report.Skipped += "settings for " + ($snap.games | Where-Object { $_.id -eq $s } | Select-Object -First 1).name }; continue }
                Copy-Item (Join-Path $snap.Path "settings\$s.json") (Get-SettingsPath $cur) -Force
                $report.Settings++
            }
        }
    }
    $report.ServiceOk = $svcOk
    return [pscustomobject]$report
}

# ---------- Window ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pimax Game Manager" Width="1020" Height="580" MinWidth="900" MinHeight="480"
        Background="#1B1B1B" Foreground="#EDEDED" FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2E2E2E"/><Setter Property="Foreground" Value="#EDEDED"/>
      <Setter Property="BorderBrush" Value="#444"/><Setter Property="Padding" Value="14,7"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.ColumnDefinitions><ColumnDefinition Width="280"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Grid.ColumnSpan="3">
      <Border x:Name="UpdateBar" Visibility="Collapsed" Background="#0D2A45" BorderBrush="#1E88E5"
              BorderThickness="1" CornerRadius="6" Padding="12,8" Margin="0,0,0,12">
        <DockPanel>
          <Button x:Name="UpdateClose" DockPanel.Dock="Right" Content="Later" Margin="8,0,0,0" Padding="12,4"/>
          <Button x:Name="UpdateBtn" DockPanel.Dock="Right" Content="Download" Padding="12,4" Background="#1565C0" BorderBrush="#1E88E5" FontWeight="SemiBold"/>
          <TextBlock x:Name="UpdateText" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>
      </Border>
      <Border x:Name="ResetBar" Visibility="Collapsed" Background="#3A2A10" BorderBrush="#FFB74D"
              BorderThickness="1" CornerRadius="6" Padding="12,8" Margin="0,0,0,12">
        <DockPanel>
          <Button x:Name="ResetDismiss" DockPanel.Dock="Right" Content="Dismiss" Margin="8,0,0,0" Padding="12,4"/>
          <Button x:Name="ResetRestore" DockPanel.Dock="Right" Content="Restore..." Padding="12,4" Background="#E65100" BorderBrush="#FFB74D" FontWeight="SemiBold"/>
          <TextBlock x:Name="ResetText" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>
      </Border>    </StackPanel>

    <DockPanel Grid.Row="1" Grid.Column="0">
      <TextBlock DockPanel.Dock="Top" Text="Your Pimax library" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,8"/>
      <Grid DockPanel.Dock="Bottom" Margin="0,8,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition Height="8"/><RowDefinition/></Grid.RowDefinitions>
        <Button x:Name="RefreshBtn" Grid.Column="0" Content="Refresh list"/>
        <Button x:Name="OrderBtn" Grid.Column="2" Content="Library order..." Background="#1565C0" BorderBrush="#1E88E5"/>
        <Button x:Name="SettingsBtn" Grid.Row="2" Grid.Column="0" Content="Game settings..." Background="#1565C0" BorderBrush="#1E88E5"/>
        <Button x:Name="BackupBtn" Grid.Row="2" Grid.Column="2" Content="Backup &amp; restore..."/>
      </Grid>
      <ListBox x:Name="GameList" Background="#232323" Foreground="#EDEDED" BorderBrush="#3A3A3A"/>
    </DockPanel>

    <DockPanel Grid.Row="1" Grid.Column="2">
      <TextBlock x:Name="GameTitle" DockPanel.Dock="Top" Text="Pick a game on the left" FontSize="18" FontWeight="SemiBold"/>
      <TextBlock x:Name="GameInfo" DockPanel.Dock="Top" Foreground="#9A9A9A" Margin="0,2,0,10" TextWrapping="Wrap"/>
      <StackPanel DockPanel.Dock="Bottom">
        <TextBlock Text="New image: click Find image, paste a link, or browse for a file" Foreground="#BDBDBD" Margin="0,10,0,4"/>
        <DockPanel>
          <Button x:Name="FindBtn" DockPanel.Dock="Right" Content="Find image" Margin="8,0,0,0" Background="#1565C0" BorderBrush="#1E88E5" FontWeight="SemiBold"/>
          <Button x:Name="BrowseBtn" DockPanel.Dock="Right" Content="Browse..." Margin="8,0,0,0"/>
          <Button x:Name="PreviewBtn" DockPanel.Dock="Right" Content="Preview" Margin="8,0,0,0"/>
          <TextBox x:Name="SourceBox" Background="#232323" Foreground="#EDEDED" BorderBrush="#3A3A3A" Padding="6,6" VerticalContentAlignment="Center"/>
        </DockPanel>
        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
          <Button x:Name="ApplyBtn" Content="Apply image" Background="#2E7D32" BorderBrush="#43A047" FontWeight="SemiBold"/>
          <Button x:Name="RestoreBtn" Content="Restore original" Margin="8,0,0,0"/>
          <Button x:Name="RestartBtn" Content="Restart Pimax Play" Margin="8,0,0,0"/>
          <Button x:Name="KeyBtn" Content="SteamGridDB key..." Margin="8,0,0,0"/>
        </StackPanel>
      </StackPanel>
      <Border Background="#111" CornerRadius="8" BorderBrush="#333" BorderThickness="1">
        <Grid>
          <TextBlock x:Name="NoImage" Text="No custom image" Foreground="#666" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          <Image x:Name="PreviewImg" Stretch="Uniform" Margin="6"/>
        </Grid>
      </Border>
    </DockPanel>

    <DockPanel Grid.Row="2" Grid.ColumnSpan="3" Margin="0,12,0,0">
      <TextBlock x:Name="VersionLabel" DockPanel.Dock="Right" Margin="16,0,0,0" Foreground="#8A8A8A" Cursor="Hand"
                 VerticalAlignment="Bottom" ToolTip="Click to check for updates"/>
      <TextBlock x:Name="Status" Foreground="#8BC34A" TextWrapping="Wrap"
                 Text="Wide banner images (about 460x215 or 920x430) fit Pimax tiles best."/>
    </DockPanel>
  </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'GameList','RefreshBtn','OrderBtn','SettingsBtn','GameTitle','GameInfo','SourceBox','BrowseBtn','PreviewBtn','FindBtn','KeyBtn','ApplyBtn','RestoreBtn','RestartBtn','PreviewImg','NoImage','Status','UpdateBar','UpdateText','UpdateBtn','UpdateClose','VersionLabel','BackupBtn','ResetBar','ResetText','ResetRestore','ResetDismiss') { $ui[$n] = $window.FindName($n) }
$window.Title = "Pimax Game Manager $AppVersion"

# Window icon: the exe's own icon, or PimaxGameManager.ico next to the script
$script:AppIcon = $null
try {
    Add-Type -AssemblyName System.Drawing
    $exePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $ico = $null
    if ([IO.Path]::GetFileNameWithoutExtension($exePath) -ieq 'PimaxGameManager') { $ico = [Drawing.Icon]::ExtractAssociatedIcon($exePath) }
    elseif ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'PimaxGameManager.ico'))) { $ico = New-Object Drawing.Icon (Join-Path $PSScriptRoot 'PimaxGameManager.ico') }
    if ($ico) {
        $script:AppIcon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $window.Icon = $script:AppIcon
    }
} catch { }

# ---------- Behaviour ----------
function Set-Status([string]$msg, [bool]$isError = $false) {
    $ui.Status.Foreground = if ($isError) { '#EF5350' } else { '#8BC34A' }
    $ui.Status.Text = $msg
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
}

function Show-Preview([string]$source) {
    $ui.PreviewImg.Source = $null; $ui.NoImage.Visibility = 'Visible'
    if (-not $source) { return }
    if ($source -notmatch '^https?://' -and -not (Test-Path -LiteralPath $source)) { return }
    $ui.PreviewImg.Source = Load-Bitmap $source
    $ui.NoImage.Visibility = 'Collapsed'
}

function Selected-Game { if ($ui.GameList.SelectedItem) { $ui.GameList.SelectedItem.Tag } }

function Fill-List {
    $keep = (Selected-Game).File
    $ui.GameList.Items.Clear()
    foreach ($g in Get-PimaxGames) {
        $item = New-Object Windows.Controls.ListBoxItem
        $item.Content = "{0}   ({1})" -f $g.Name, $g.Source
        $item.Tag = $g; $item.Padding = '6,5'
        [void]$ui.GameList.Items.Add($item)
        if ($g.File -eq $keep) { $ui.GameList.SelectedItem = $item }
    }
}

$ui.GameList.Add_SelectionChanged({
    $g = Selected-Game
    if (-not $g) { return }
    $ui.GameTitle.Text = $g.Name
    $canChange = ($g.Source -eq 'Imported')
    $info = "Source: $($g.Source)"
    if (-not $canChange) { $info += "   -  Pimax takes this game's image from $(if ($g.Source -eq 'Oculus') { 'Oculus' } else { 'Steam' }) every time it starts, so it can't be changed here. To use your own image, add the game with Import in Pimax Play." }
    $ui.GameInfo.Text = $info
    $ui.SourceBox.Text = ''
    foreach ($b in $ui.ApplyBtn, $ui.FindBtn, $ui.BrowseBtn, $ui.PreviewBtn, $ui.SourceBox) { $b.IsEnabled = $canChange }
    $ui.RestoreBtn.IsEnabled = $canChange
    try { Show-Preview $g.Icon; Set-Status $(if ($canChange) { 'Showing the current image.' } else { 'Images can only be changed for imported games.' }) } catch { Set-Status 'Current image could not be loaded.' $true }
})

$ui.BrowseBtn.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Images|*.jpg;*.jpeg;*.png;*.webp;*.bmp;*.gif|All files|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $ui.SourceBox.Text = $dlg.FileName
        try { Show-Preview $dlg.FileName; Set-Status 'Preview of the new image. Click "Apply image" to use it.' } catch { Set-Status "Couldn't read that image." $true }
    }
})

$ui.PreviewBtn.Add_Click({
    $src = $ui.SourceBox.Text.Trim('"', ' ')
    if (-not $src) { Set-Status 'Paste a link or choose a file first.' $true; return }
    Set-Status 'Loading preview...'
    try { Show-Preview $src; Set-Status 'Preview of the new image. Click "Apply image" to use it.' } catch { Set-Status "Couldn't load that image: $($_.Exception.Message)" $true }
})

function Finish-Restart([string]$doneMsg) {
    Set-Status 'Restarting Pimax Play...'
    if (Restart-Pimax) { Set-Status $doneMsg }
    else { Set-Status "$doneMsg  (Couldn't restart the Pimax service - restart your PC if the image doesn't update.)" $true }
    Fill-List
    Save-AutoSnapshot
}

$ui.ApplyBtn.Add_Click({
    $g = Selected-Game
    if (-not $g) { Set-Status 'Pick a game on the left first.' $true; return }
    $src = $ui.SourceBox.Text.Trim('"', ' ')
    if (-not $src) { Set-Status 'Paste a link or choose a file first.' $true; return }
    if ($src -notmatch '^https?://' -and -not (Test-Path -LiteralPath $src)) { Set-Status "File not found: $src" $true; return }
    try {
        Set-Status 'Saving image...'
        $dest = Save-Cover $g $src
        Show-Preview $dest
        Finish-Restart "Done - $($g.Name) now uses the new image."
    } catch { Set-Status "Couldn't apply the image: $($_.Exception.Message)" $true }
})

$ui.RestoreBtn.Add_Click({
    $g = Selected-Game
    if (-not $g) { Set-Status 'Pick a game on the left first.' $true; return }
    $r = [Windows.MessageBox]::Show("Put $($g.Name) back to its original image?", 'Restore original', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    try { Restore-Cover $g; Finish-Restart "Restored the original image for $($g.Name)." }
    catch { Set-Status $_.Exception.Message $true }
})

function Show-Finder($game) {
    [xml]$fx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Find image" Width="1010" Height="660" Background="#1B1B1B" Foreground="#EDEDED"
        FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterOwner">
  <DockPanel Margin="14">
    <DockPanel DockPanel.Dock="Top">
      <Button x:Name="SearchBtn" DockPanel.Dock="Right" Content="Search by name" Margin="8,0,0,0" Padding="14,7"
              Background="#2E2E2E" Foreground="#EDEDED" BorderBrush="#444" Cursor="Hand"/>
      <TextBox x:Name="Term" Background="#232323" Foreground="#EDEDED" BorderBrush="#3A3A3A" Padding="6,6" VerticalContentAlignment="Center"/>
    </DockPanel>
    <TextBlock x:Name="Note" DockPanel.Dock="Top" Foreground="#9A9A9A" Margin="0,8,0,8" TextWrapping="Wrap"/>
    <TextBlock DockPanel.Dock="Bottom" Text="Click an image to use it." Foreground="#9A9A9A" Margin="0,8,0,0"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><WrapPanel x:Name="Results"/></ScrollViewer>
  </DockPanel>
</Window>
'@
    $fw = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $fx))
    $fw.Owner = $window
    if ($script:AppIcon) { $fw.Icon = $script:AppIcon }
    $script:finderPick = $null
    $termBox = $fw.FindName('Term'); $noteBlock = $fw.FindName('Note'); $results = $fw.FindName('Results')
    $termBox.Text = $game.Name

    $run = {
        param([bool]$exact)
        $results.Children.Clear()
        $noteBlock.Text = 'Searching...'
        $fw.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        $found = Find-Art $game $termBox.Text.Trim() $exact
        foreach ($c in $found.Items) {
            $bmp = New-Object Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = [uri]$c.Thumb; $bmp.DecodePixelWidth = 300; $bmp.EndInit()
            $img = New-Object Windows.Controls.Image
            $img.Source = $bmp; $img.Width = 300; $img.Height = 140; $img.Stretch = 'Uniform'
            $cap = New-Object Windows.Controls.TextBlock
            $cap.Text = $c.Label; $cap.Width = 300; $cap.TextTrimming = 'CharacterEllipsis'; $cap.Foreground = '#BDBDBD'; $cap.Margin = '0,4,0,0'
            $sp = New-Object Windows.Controls.StackPanel
            [void]$sp.Children.Add($img); [void]$sp.Children.Add($cap)
            $btn = New-Object Windows.Controls.Button
            $btn.Content = $sp; $btn.Tag = $c.Url; $btn.Margin = '6'; $btn.Padding = '6'
            $btn.Background = '#232323'; $btn.BorderBrush = '#3A3A3A'; $btn.Cursor = 'Hand'; $btn.ToolTip = $c.Url
            $btn.Add_Click({ $script:finderPick = $this.Tag; $fw.Close() })
            [void]$results.Children.Add($btn)
        }
        $noteBlock.Text = if ($found.Items.Count) { "$($found.Items.Count) images found. $($found.Note)" } else { "No images found - try a different name. $($found.Note)" }
    }

    $fw.FindName('SearchBtn').Add_Click({ & $run $false })
    $termBox.Add_KeyDown({ if ($_.Key -eq 'Return') { & $run $false } })
    $fw.Add_ContentRendered({ & $run $true })
    [void]$fw.ShowDialog()
}

$ui.FindBtn.Add_Click({
    $g = Selected-Game
    if (-not $g) { Set-Status 'Pick a game on the left first.' $true; return }
    Show-Finder $g | Out-Null
    if ($script:finderPick) {
        $ui.SourceBox.Text = $script:finderPick
        Set-Status 'Loading preview...'
        try { Show-Preview $script:finderPick; Set-Status 'Preview of the new image. Click "Apply image" to use it.' }
        catch { Set-Status "Couldn't load that image: $($_.Exception.Message)" $true }
    }
})

$ui.KeyBtn.Add_Click({
    Add-Type -AssemblyName Microsoft.VisualBasic
    $current = Get-SgdbKey
    $k = [Microsoft.VisualBasic.Interaction]::InputBox("Paste your SteamGridDB API key.`n`nGet one free: sign in at steamgriddb.com, then Preferences > API.", 'SteamGridDB key', $current).Trim()
    if (-not $k -or $k -eq $current) { return }
    Set-SgdbKey $k
    Set-Status 'Checking key...'
    try { Invoke-Sgdb 'search/autocomplete/portal' | Out-Null; Set-Status 'SteamGridDB key saved and working.' }
    catch { Set-Status "Key saved, but SteamGridDB rejected it: $($_.Exception.Message)" $true }
})

function Get-ScrollViewer($el) {
    if ($el -is [Windows.Controls.ScrollViewer]) { return $el }
    for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($el); $i++) {
        $r = Get-ScrollViewer ([Windows.Media.VisualTreeHelper]::GetChild($el, $i))
        if ($r) { return $r }
    }
    return $null
}

function Show-Order {
    [xml]$ox = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Library order" Width="780" Height="700" MinWidth="700" MinHeight="480" Background="#1B1B1B" Foreground="#EDEDED"
        FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterOwner">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2E2E2E"/><Setter Property="Foreground" Value="#EDEDED"/>
      <Setter Property="BorderBrush" Value="#444"/><Setter Property="Padding" Value="12,6"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Window.Resources>
  <DockPanel Margin="14">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#BDBDBD" Margin="0,0,0,10"
      Text="Tick a game to pin it, and drag games to reorder. Pinned games show first in Pimax Play, in this order. Unticked games follow in Pimax's own order. Tip: Pin all, then drag, to control the whole library."/>
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="PinAll" Content="Pin all"/>
      <Button x:Name="UnpinAll" Content="Unpin all" Margin="6,0,0,0"/>
      <Button x:Name="SortAZ" Content="Sort A-Z" Margin="6,0,0,0"/>
      <Button x:Name="Up" Content="Move up" Margin="18,0,0,0"/>
      <Button x:Name="Down" Content="Move down" Margin="6,0,0,0"/>
      <Button x:Name="Top" Content="Move to top" Margin="6,0,0,0"/>
      <Button x:Name="Bottom" Content="Move to bottom" Margin="6,0,0,0"/>
    </StackPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <Button x:Name="Cancel" DockPanel.Dock="Right" Content="Cancel" Margin="8,0,0,0"/>
      <Button x:Name="Save" DockPanel.Dock="Right" Content="Save and restart Pimax Play" Background="#2E7D32" BorderBrush="#43A047" FontWeight="SemiBold"/>
      <TextBlock x:Name="Count" VerticalAlignment="Center" Foreground="#9A9A9A"/>
    </DockPanel>
    <ListBox x:Name="Order" Background="#232323" Foreground="#EDEDED" BorderBrush="#3A3A3A" AllowDrop="True"/>
  </DockPanel>
</Window>
'@
    $script:ow = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $ox))
    if ($window.IsLoaded) { $script:ow.Owner = $window }
    if ($script:AppIcon) { $script:ow.Icon = $script:AppIcon }
    $script:lb = $script:ow.FindName('Order'); $script:count = $script:ow.FindName('Count')

    $games = @(Get-PimaxGames | ForEach-Object { $_ | Add-Member -NotePropertyName Id -NotePropertyValue (Get-GameId $_) -PassThru })
    $pinned = @(Get-PinnedIds)
    $byId = @{}; foreach ($g in $games) { $byId[$g.Id] = $g }
    $script:unknownPins = @($pinned | Where-Object { -not $byId.ContainsKey($_) })
    $ordered = @($pinned | Where-Object { $byId.ContainsKey($_) } | ForEach-Object { $byId[$_] })
    $ordered += @($games | Where-Object { $pinned -notcontains $_.Id } | Sort-Object { Get-PimaxOrderKey $_ $_.Id })

    $script:updateCount = {
        $n = @($script:lb.Items | Where-Object { $_.Tag.Check.IsChecked }).Count
        $script:count.Text = "$n of $($script:lb.Items.Count) pinned"
    }
    foreach ($g in $ordered) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.IsChecked = ($pinned -contains $g.Id); $cb.VerticalAlignment = 'Center'; $cb.Margin = '0,0,10,0'
        $cb.Add_Click({ & $script:updateCount })
        $name = New-Object Windows.Controls.TextBlock
        $name.Text = $g.Name; $name.VerticalAlignment = 'Center'
        $src = New-Object Windows.Controls.TextBlock
        $src.Text = "   $($g.Source)"; $src.Foreground = '#8A8A8A'; $src.VerticalAlignment = 'Center'
        $grip = New-Object Windows.Controls.TextBlock
        $grip.Text = [string][char]0x2261; $grip.Foreground = '#777'; $grip.FontSize = 16; $grip.Margin = '0,0,10,0'; $grip.VerticalAlignment = 'Center'
        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        foreach ($c in $grip, $cb, $name, $src) { [void]$row.Children.Add($c) }
        $item = New-Object Windows.Controls.ListBoxItem
        $item.Content = $row; $item.Padding = '6,6'; $item.Cursor = 'SizeAll'
        $item.Tag = [pscustomobject]@{ Game = $g; Check = $cb }
        [void]$script:lb.Items.Add($item)
    }
    & $script:updateCount

    $script:findItem = {
        param($el)
        while ($el -and -not ($el -is [Windows.Controls.ListBoxItem])) {
            if ($el -is [Windows.Controls.CheckBox]) { return $null }
            $el = if ($el -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
        }
        return $el
    }
    $script:orderDrag = $null
    $script:lb.Add_PreviewMouseLeftButtonDown({ $script:orderDrag = & $script:findItem $_.OriginalSource; $script:orderStart = $_.GetPosition($script:lb) })
    $script:lb.Add_PreviewMouseMove({
        if ($_.LeftButton -ne 'Pressed' -or -not $script:orderDrag) { return }
        $p = $_.GetPosition($script:lb)
        if ([Math]::Abs($p.Y - $script:orderStart.Y) -lt 5 -and [Math]::Abs($p.X - $script:orderStart.X) -lt 5) { return }
        $it = $script:orderDrag; $script:orderDrag = $null
        [void][Windows.DragDrop]::DoDragDrop($script:lb, $it, [Windows.DragDropEffects]::Move)
    })
    $script:lb.Add_Drop({
        $srcItem = $_.Data.GetData([Windows.Controls.ListBoxItem])
        if (-not $srcItem) { return }
        $target = & $script:findItem $_.OriginalSource
        $to = if ($target) { $script:lb.Items.IndexOf($target) } else { $script:lb.Items.Count - 1 }
        if ($target -eq $srcItem) { return }
        $script:lb.Items.Remove($srcItem)
        if ($to -gt $script:lb.Items.Count) { $to = $script:lb.Items.Count }
        $script:lb.Items.Insert($to, $srcItem)
        $script:lb.SelectedItem = $srcItem
    })
    # Scroll the list while dragging near its top or bottom edge (faster the closer to the edge)
    $script:orderSv = $null; $script:orderLastScroll = 0
    $script:lb.Add_DragOver({
        $_.Effects = [Windows.DragDropEffects]::Move
        if (-not $script:orderSv) { $script:orderSv = Get-ScrollViewer $this }
        $sv = $script:orderSv; if (-not $sv) { return }
        $y = $_.GetPosition($this).Y; $zone = 50; $h = $this.ActualHeight
        $dir = 0; $dist = 0
        if ($y -lt $zone) { $dir = -1; $dist = $zone - $y } elseif ($y -gt $h - $zone) { $dir = 1; $dist = $y - ($h - $zone) }
        if ($dir -eq 0) { return }
        $interval = 40 + (1 - [Math]::Min(1, $dist / $zone)) * 160
        $now = [Environment]::TickCount
        if ($now - $script:orderLastScroll -lt $interval) { return }
        $script:orderLastScroll = $now
        if ($dir -lt 0) { $sv.LineUp() } else { $sv.LineDown() }
    })

    $script:move = {
        param([int]$delta)
        $it = $script:lb.SelectedItem; if (-not $it) { return }
        $i = $script:lb.Items.IndexOf($it); $j = $i + $delta
        if ($j -lt 0 -or $j -ge $script:lb.Items.Count) { return }
        $script:lb.Items.Remove($it); $script:lb.Items.Insert($j, $it); $script:lb.SelectedItem = $it; $script:lb.ScrollIntoView($it)
    }
    $script:ow.FindName('Up').Add_Click({ & $script:move -1 })
    $script:ow.FindName('Down').Add_Click({ & $script:move 1 })
    $script:moveTo = {
        param([bool]$toTop)
        $it = $script:lb.SelectedItem; if (-not $it) { return }
        $script:lb.Items.Remove($it)
        if ($toTop) { $script:lb.Items.Insert(0, $it) } else { [void]$script:lb.Items.Add($it) }
        $script:lb.SelectedItem = $it; $script:lb.ScrollIntoView($it)
    }
    $script:ow.FindName('Top').Add_Click({ & $script:moveTo $true })
    $script:ow.FindName('Bottom').Add_Click({ & $script:moveTo $false })
    $script:ow.FindName('PinAll').Add_Click({ foreach ($it in $script:lb.Items) { $it.Tag.Check.IsChecked = $true }; & $script:updateCount })
    $script:ow.FindName('UnpinAll').Add_Click({ foreach ($it in $script:lb.Items) { $it.Tag.Check.IsChecked = $false }; & $script:updateCount })
    $script:ow.FindName('SortAZ').Add_Click({
        $sorted = @($script:lb.Items | Sort-Object { $_.Tag.Game.Name })
        $script:lb.Items.Clear(); foreach ($it in $sorted) { [void]$script:lb.Items.Add($it) }
    })
    $script:ow.FindName('Cancel').Add_Click({ $script:ow.Close() })
    $script:ow.FindName('Save').Add_Click({
        $ids = @($script:lb.Items | Where-Object { $_.Tag.Check.IsChecked } | ForEach-Object { $_.Tag.Game.Id }) + $script:unknownPins
        $client = Get-ClientPath
        try {
            Save-PinnedOrder $ids
            Save-AutoSnapshot
            Start-Sleep -Seconds 1
            if (Test-Path $client) { Start-Process $client }
            $script:orderResult = "Library order saved ($($ids.Count) pinned). Pimax Play restarted."
            $script:ow.Close()
        } catch {
            [Windows.MessageBox]::Show("Couldn't save the order: $($_.Exception.Message)", 'Library order', 'OK', 'Error') | Out-Null
            if (Test-Path $client) { Start-Process $client }
        }
    })
    $script:orderResult = $null
    if ($Test) { return @($script:lb.Items | ForEach-Object { '{0} {1} ({2})' -f $(if ($_.Tag.Check.IsChecked) { '[x]' } else { '[ ]' }), $_.Tag.Game.Name, $_.Tag.Game.Id }) }
    if ($script:Capture) { $script:orderWin = $script:ow; return }
    [void]$script:ow.ShowDialog()
}

$ui.OrderBtn.Add_Click({
    try { Show-Order } catch { Set-Status "Library order failed: $($_.Exception.Message)" $true; return }
    if ($script:orderResult) { Set-Status $script:orderResult }
})

# ---------- Game settings window ----------
function New-DarkWindow([string]$title, [int]$w, [int]$h, [string]$body) {
    $title = [Security.SecurityElement]::Escape($title)
    [xml]$x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$title" Width="$w" Height="$h" MinWidth="560" MinHeight="420" Background="#1B1B1B" Foreground="#EDEDED"
        FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterOwner">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2E2E2E"/><Setter Property="Foreground" Value="#EDEDED"/>
      <Setter Property="BorderBrush" Value="#444"/><Setter Property="Padding" Value="12,6"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#EDEDED"/></Style>
  </Window.Resources>
  $body
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $x))
    if ($window.IsLoaded) { $win.Owner = $window }
    if ($script:AppIcon) { $win.Icon = $script:AppIcon }
    return $win
}

# Checklist of games; returns the ticked game IDs (or $null if cancelled)
function Select-Games([string]$title, [string]$prompt, [string[]]$exclude) {
    $script:pw = New-DarkWindow $title 480 600 @'
  <DockPanel Margin="14">
    <TextBlock x:Name="Prompt" DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#BDBDBD" Margin="0,0,0,8"/>
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="All" Content="Select all"/><Button x:Name="None" Content="Select none" Margin="6,0,0,0"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="Ok" Content="OK" Background="#2E7D32" BorderBrush="#43A047" FontWeight="SemiBold"/>
      <Button x:Name="Cancel" Content="Cancel" Margin="8,0,0,0"/>
    </StackPanel>
    <ListBox x:Name="List" Background="#232323" Foreground="#EDEDED" BorderBrush="#3A3A3A"/>
  </DockPanel>
'@
    $script:pw.FindName('Prompt').Text = $prompt
    $script:list = $script:pw.FindName('List')
    foreach ($g in ($script:gsGames | Where-Object { $exclude -notcontains $_.Id } | Sort-Object Name)) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = "{0}   ({1})" -f $g.Name, $g.Source; $cb.Tag = $g.Id; $cb.Margin = '2,4'
        [void]$script:list.Items.Add($cb)
    }
    $script:pickResult = $null
    $script:pw.FindName('All').Add_Click({ foreach ($c in $script:list.Items) { $c.IsChecked = $true } })
    $script:pw.FindName('None').Add_Click({ foreach ($c in $script:list.Items) { $c.IsChecked = $false } })
    $script:pw.FindName('Cancel').Add_Click({ $script:pw.Close() })
    $script:pw.FindName('Ok').Add_Click({ $script:pickResult = @($script:list.Items | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag }); $script:pw.Close() })
    [void]$script:pw.ShowDialog()
    return $script:pickResult
}

function Show-GameSettings([string]$startId) {
    $script:sw = New-DarkWindow 'Game settings' 1180 720 @'
  <Grid Margin="14">
    <Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <DockPanel Grid.Column="0">
      <TextBlock DockPanel.Dock="Top" Text="Games" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,8"/>
      <Button x:Name="Leftovers" DockPanel.Dock="Bottom" Content="Remove leftover settings..." Margin="0,8,0,0"/>
      <ListBox x:Name="Targets" Background="#232323" Foreground="#EDEDED" BorderBrush="#3A3A3A"/>
    </DockPanel>
    <DockPanel Grid.Column="2">
      <TextBlock x:Name="Title" DockPanel.Dock="Top" FontSize="18" FontWeight="SemiBold"/>
      <TextBlock x:Name="Info" DockPanel.Dock="Top" Foreground="#9A9A9A" TextWrapping="Wrap" Margin="0,2,0,10"/>
      <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
        <Button x:Name="Save" DockPanel.Dock="Right" Content="Save all changes" Background="#2E7D32" BorderBrush="#43A047" FontWeight="SemiBold"/>
        <Button x:Name="DiscardAll" DockPanel.Dock="Right" Content="Discard all" Margin="0,0,8,0"/>
        <StackPanel Orientation="Horizontal">
          <Button x:Name="Revert" Content="Undo this game"/>
          <Button x:Name="Reset" Content="Reset to global" Margin="8,0,0,0"/>
          <Button x:Name="CopyAll" Content="Copy all settings to..." Margin="8,0,0,0" Background="#1565C0" BorderBrush="#1E88E5"/>
        </StackPanel>
      </DockPanel>
      <ScrollViewer VerticalScrollBarVisibility="Auto"><Grid x:Name="Rows"/></ScrollViewer>
    </DockPanel>
    <TextBlock x:Name="Status" Grid.Row="1" Grid.ColumnSpan="3" Margin="0,10,0,0" Foreground="#8BC34A" TextWrapping="Wrap"
      Text="Tick 'Custom' to give a game its own value. Changes are kept as you move between games; click Save all changes when you're done."/>
  </Grid>
'@
    $script:targets = $script:sw.FindName('Targets'); $rowsGrid = $script:sw.FindName('Rows')
    $script:gsTitle = $script:sw.FindName('Title'); $script:gsInfo = $script:sw.FindName('Info'); $script:gsStatus = $script:sw.FindName('Status')
    $script:gsSaveBtn = $script:sw.FindName('Save'); $script:gsResetBtn = $script:sw.FindName('Reset')
    $script:gsPending = [ordered]@{}
    $script:gsSay = { param([string]$m, [bool]$bad = $false) $script:gsStatus.Foreground = $(if ($bad) { '#EF5350' } else { '#8BC34A' }); $script:gsStatus.Text = $m }

    $script:gsGames = @(Get-PimaxGames | ForEach-Object { $_ | Add-Member -NotePropertyName Id -NotePropertyValue (Get-GameId $_) -PassThru -Force } | Sort-Object Name)
    $gItem = New-Object Windows.Controls.ListBoxItem
    $gItem.Tag = 'global'; $gItem.FontWeight = 'SemiBold'; $gItem.Padding = '6,5'
    [void]$script:targets.Items.Add($gItem)
    foreach ($g in $script:gsGames) {
        $it = New-Object Windows.Controls.ListBoxItem
        $it.Tag = $g.Id; $it.Padding = '6,5'
        [void]$script:targets.Items.Add($it)
    }

    # Build one row per setting
    foreach ($w in 90, 190, 230, '*', 100) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $(if ($w -eq '*') { New-Object Windows.GridLength(1, 'Star') } else { New-Object Windows.GridLength($w) }); if ($w -eq '*') { $cd.MinWidth = 200 }; $rowsGrid.ColumnDefinitions.Add($cd) }
    $script:gsRows = @()
    $r = 0
    foreach ($def in $SettingDefs) {
        $rowsGrid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
        $row = [pscustomobject]@{ Def = $def; Check = $null; Control = $null; Hint = $null; Apply = $null }
        $cb = New-Object Windows.Controls.CheckBox; $cb.Content = 'Custom'; $cb.VerticalAlignment = 'Center'; $cb.Tag = $row
        $lbl = New-Object Windows.Controls.TextBlock; $lbl.Text = $def.Label; $lbl.VerticalAlignment = 'Center'; $lbl.Margin = '0,0,10,0'
        if ($def.Tip) { $lbl.ToolTip = $def.Tip }
        if ($def.Kind -eq 'choice') {
            $ctl = New-Object Windows.Controls.ComboBox
            foreach ($o in $def.Options) { $ci = New-Object Windows.Controls.ComboBoxItem; $ci.Content = $o[1]; $ci.Tag = [int]$o[0]; [void]$ctl.Items.Add($ci) }
            $ctl.Add_SelectionChanged({ & $script:gsChanged $this.Tag })
        } else {
            $ctl = New-Object Windows.Controls.TextBox; $ctl.Padding = '4,3'
            $ctl.ToolTip = "{0} to {1}" -f $def.Min.ToString($Inv), $def.Max.ToString($Inv)
            $ctl.Add_TextChanged({ & $script:gsChanged $this.Tag })
        }
        $ctl.Tag = $row; $ctl.Margin = '0,5'; $ctl.VerticalAlignment = 'Center'
        $hint = New-Object Windows.Controls.TextBlock; $hint.Foreground = '#8A8A8A'; $hint.VerticalAlignment = 'Center'; $hint.Margin = '12,0,8,0'; $hint.TextTrimming = 'CharacterEllipsis'
        $ab = New-Object Windows.Controls.Button; $ab.Content = 'Apply to...'; $ab.Padding = '8,3'; $ab.Margin = '0,5'; $ab.Tag = $row
        $ab.ToolTip = "Use this $($def.Label) on other games"
        $ab.Add_Click({ & $script:gsApplyRow $this.Tag })
        $cb.Add_Click({ $this.Tag.Control.IsEnabled = [bool]$this.IsChecked; & $script:gsChanged $this.Tag })
        $row.Check = $cb; $row.Control = $ctl; $row.Hint = $hint; $row.Apply = $ab
        $col = 0
        foreach ($el in $cb, $lbl, $ctl, $hint, $ab) { [Windows.Controls.Grid]::SetRow($el, $r); [Windows.Controls.Grid]::SetColumn($el, $col); [void]$rowsGrid.Children.Add($el); $col++ }
        $script:gsRows += $row
        $r++
    }

    $script:fmtNum = { param($v) ([double]$v).ToString('0.##', $Inv) }
    $script:display = {
        param($def, $v)
        if ($def.Kind -eq 'number') { return (& $script:fmtNum $v) }
        $o = $def.Options | Where-Object { $_[0] -eq [int]$v } | Select-Object -First 1
        if ($o) { return $o[1] } else { return "value $v" }
    }
    $script:setControl = {
        param($row, $v)
        if ($row.Def.Kind -eq 'number') { $row.Control.Text = (& $script:fmtNum $v); return }
        $item = $row.Control.Items | Where-Object { $_.Tag -eq [int]$v } | Select-Object -First 1
        if (-not $item) { $item = New-Object Windows.Controls.ComboBoxItem; $item.Content = "Value $v"; $item.Tag = [int]$v; [void]$row.Control.Items.Add($item) }
        $row.Control.SelectedItem = $item
    }
    $script:getValue = {
        param($row)
        if ($row.Def.Kind -eq 'number') {
            $d = 0.0
            if (-not [double]::TryParse($row.Control.Text.Trim(), [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { throw "$($row.Def.Label): '$($row.Control.Text)' is not a number." }
            if ($d -lt $row.Def.Min -or $d -gt $row.Def.Max) { throw "$($row.Def.Label) must be between $($row.Def.Min.ToString($Inv)) and $($row.Def.Max.ToString($Inv))." }
            return [double]$d
        }
        if (-not $row.Control.SelectedItem) { throw "$($row.Def.Label): pick an option." }
        return [int]$row.Control.SelectedItem.Tag
    }
    # Settings for a target as they will be saved: queued edits if any, otherwise the file on disk
    $script:gsSettingsOf = {
        param([string]$id)
        if ($script:gsPending.Contains($id)) { $src = $script:gsPending[$id] } else { $src = Read-GameSettings $id }
        $m = [ordered]@{}; foreach ($k in $src.Keys) { $m[$k] = $src[$k] }
        return $m
    }
    $script:gsNameOf = { param([string]$id) if ($id -eq 'global') { 'Global settings' } else { ($script:gsGames | Where-Object { $_.Id -eq $id } | Select-Object -First 1).Name } }

    $script:refreshMarks = {
        foreach ($it in $script:targets.Items) {
            $id = [string]$it.Tag
            $unsaved = $script:gsPending.Contains($id) -or ($script:gsDirty -and $id -eq $script:gsTarget)
            if ($id -eq 'global') { $base = 'Global (default for all games)'; $custom = $false }
            else {
                $base = & $script:gsNameOf $id
                if ($script:gsPending.Contains($id)) { $custom = $script:gsPending[$id].Count -gt 0 } else { $custom = Test-Path -LiteralPath (Get-SettingsPath $id) }
            }
            $it.Content = $base + $(if ($custom) { '   *' } else { '' }) + $(if ($unsaved) { '   (unsaved)' } else { '' })
            $it.Foreground = $(if ($unsaved) { '#FFB74D' } else { '#EDEDED' })
            $it.ToolTip = $(if ($id -eq 'global') { 'Default settings for every game' } elseif ($custom) { 'Has its own settings' } else { 'Uses global settings' })
        }
        $n = $script:gsPending.Count
        if ($script:gsDirty -and -not $script:gsPending.Contains($script:gsTarget)) { $n++ }
        $script:gsSaveBtn.Content = $(if ($n) { "Save all changes ($n)" } else { 'Save all changes' })
    }

    $script:gsChanged = {
        param($row)
        if ($script:gsLoading) { return }
        $wasDirty = $script:gsDirty
        $script:gsDirty = $true
        # Picking Low/Medium/High also sets the matching render resolution, as Pimax Play does
        if ($row.Def.Key -eq 'piplay_display_quality_level' -and $row.Control.SelectedItem) {
            $lvl = [int]$row.Control.SelectedItem.Tag
            if ($QualityRates.ContainsKey($lvl)) {
                $rate = $script:gsRows | Where-Object { $_.Def.Key -eq 'runtime_pixels_per_display_pixel_rate' }
                $script:gsLoading = $true
                if ($script:gsTarget -ne 'global') { $rate.Check.IsChecked = $row.Check.IsChecked; $rate.Control.IsEnabled = [bool]$row.Check.IsChecked }
                & $script:setControl $rate $QualityRates[$lvl]
                $script:gsLoading = $false
            }
        }
        if (-not $wasDirty) { & $script:refreshMarks }
    }

    $script:loadTarget = {
        param([string]$id)
        $script:gsLoading = $true
        $script:gsTarget = $id
        $script:gsCurrent = & $script:gsSettingsOf $id
        $glob = & $script:gsSettingsOf 'global'
        $isGlobal = ($id -eq 'global')
        $script:gsTitle.Text = & $script:gsNameOf $id
        $pendingNote = if ($script:gsPending.Contains($id)) { ' Showing your unsaved changes.' } else { '' }
        $script:gsInfo.Text = $(if ($isGlobal) { 'Used by every game that has no custom value for a setting.' }
                       elseif ($script:gsCurrent.Count) { "Has its own settings ($id). Unticked settings use the global value shown on the right." }
                       else { "Uses the global settings for everything. Tick 'Custom' on a setting to give this game its own value." }) + $pendingNote
        foreach ($row in $script:gsRows) {
            $k = $row.Def.Key
            $has = $script:gsCurrent.Contains($k)
            $gv = if ($glob.Contains($k)) { $glob[$k] } else { $row.Def.Default }
            $v = if ($has) { $script:gsCurrent[$k] } elseif ($isGlobal) { $row.Def.Default } else { $gv }
            & $script:setControl $row $v
            $row.Check.Visibility = $(if ($isGlobal) { 'Hidden' } else { 'Visible' })
            $row.Check.IsChecked = ($has -or $isGlobal)
            $row.Control.IsEnabled = ($has -or $isGlobal)
            $row.Hint.Text = if ($isGlobal) { $(if ($has) { '' } else { '(Pimax default)' }) } else { 'Global: ' + (& $script:display $row.Def $gv) }
        }
        $script:gsResetBtn.Content = $(if ($isGlobal) { 'Reset to Pimax defaults' } else { 'Reset to global' })
        $script:gsResetBtn.ToolTip = $(if ($isGlobal) { 'Clear the global settings so Pimax uses its built-in defaults' } else { 'Remove all of this game''s custom settings so it follows the global settings' })
        $script:gsDirty = $false
        $script:gsLoading = $false
        & $script:refreshMarks
    }

    $script:collect = {
        $map = [ordered]@{}
        foreach ($k in $script:gsCurrent.Keys) { $map[$k] = $script:gsCurrent[$k] }
        foreach ($row in $script:gsRows) {
            if ($row.Check.IsChecked -or $script:gsTarget -eq 'global') { $map[$row.Def.Key] = & $script:getValue $row }
            elseif ($map.Contains($row.Def.Key)) { $map.Remove($row.Def.Key) }
        }
        return $map
    }

    # Keep the current game's edits in the queue (throws if a value is invalid)
    $script:gsStash = {
        if (-not $script:gsDirty) { return }
        $map = & $script:collect
        $script:gsPending[$script:gsTarget] = $map
        $script:gsCurrent = $map
        $script:gsDirty = $false
    }

    $script:gsSaveAll = {
        & $script:gsStash
        if ($script:gsPending.Count -eq 0) { & $script:gsSay 'Nothing to save.'; return $true }
        $ids = @($script:gsPending.Keys)
        $n = $ids.Count
        & $script:gsSay "Saving $n game(s) - restarting Pimax..."
        $script:sw.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        Backup-SettingsOnce $ids
        $ok = Invoke-WhilePimaxStopped { foreach ($id in $ids) { Write-GameSettings $id $script:gsPending[$id] } }
        Save-AutoSnapshot
        $script:gsPending = [ordered]@{}
        & $script:loadTarget $script:gsTarget
        & $script:gsSay ("Saved changes to $n game(s)." + $(if (-not $ok) { ' (Could not restart the Pimax service; restart your PC if it does not apply.)' } else { '' })) (-not $ok)
        return $true
    }

    $script:gsApplyRow = {
        param($row)
        $label = $row.Def.Label
        try {
            $custom = $row.Check.IsChecked -or $script:gsTarget -eq 'global'
            $val = if ($custom) { & $script:getValue $row } else { $null }
        } catch { & $script:gsSay $_.Exception.Message $true; return }
        $what = if ($custom) { "$label = " + (& $script:display $row.Def $val) } else { "$label back to the global value" }
        $ids = Select-Games "Apply $label" "Set $what on these games (saved when you click Save all changes):" @($script:gsTarget)
        if (-not $ids -or $ids.Count -eq 0) { return }
        $key = $row.Def.Key
        foreach ($t in $ids) {
            $m = & $script:gsSettingsOf $t
            if ($custom) { $m[$key] = $val } elseif ($m.Contains($key)) { $m.Remove($key) }
            if ($custom -and $key -eq 'piplay_display_quality_level' -and $QualityRates.ContainsKey([int]$val)) { $m['runtime_pixels_per_display_pixel_rate'] = $QualityRates[[int]$val] }
            $script:gsPending[$t] = $m
        }
        & $script:refreshMarks
        & $script:gsSay "Queued $what for $($ids.Count) game(s). Click Save all changes to apply."
    }

    $script:targets.Add_SelectionChanged({
        $it = $script:targets.SelectedItem
        if ($script:gsSwitching -or -not $it -or $it.Tag -eq $script:gsTarget) { return }
        try { & $script:gsStash }
        catch {
            [Windows.MessageBox]::Show("Fix this before switching games:`n`n$($_.Exception.Message)", 'Game settings', 'OK', 'Warning') | Out-Null
            $script:gsSwitching = $true
            $script:targets.SelectedItem = ($script:targets.Items | Where-Object { $_.Tag -eq $script:gsTarget } | Select-Object -First 1)
            $script:gsSwitching = $false
            return
        }
        & $script:loadTarget ([string]$it.Tag)
        & $script:gsSay "Showing $($script:gsTitle.Text)."
    })

    $script:sw.FindName('Revert').Add_Click({
        if ($script:gsPending.Contains($script:gsTarget)) { $script:gsPending.Remove($script:gsTarget) }
        & $script:loadTarget $script:gsTarget
        & $script:gsSay "Undid unsaved changes to $($script:gsTitle.Text)."
    })

    $script:gsResetBtn.Add_Click({
        $script:gsPending[$script:gsTarget] = [ordered]@{}
        & $script:loadTarget $script:gsTarget
        $what = if ($script:gsTarget -eq 'global') { 'Global reset to Pimax defaults' } else { "$($script:gsTitle.Text) reset to the global settings" }
        & $script:gsSay "$what. Click Save all changes to apply, or Undo this game to cancel."
    })

    $script:sw.FindName('DiscardAll').Add_Click({
        if (-not $script:gsPending.Count -and -not $script:gsDirty) { & $script:gsSay 'No unsaved changes.'; return }
        $a = [Windows.MessageBox]::Show('Discard all unsaved changes?', 'Game settings', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        $script:gsPending = [ordered]@{}
        & $script:loadTarget $script:gsTarget
        & $script:gsSay 'All unsaved changes discarded.'
    })

    $script:gsSaveBtn.Add_Click({
        try { [void](& $script:gsSaveAll) } catch { & $script:gsSay "Couldn't save: $($_.Exception.Message)" $true }
    })

    $script:sw.FindName('CopyAll').Add_Click({
        try { $map = & $script:collect } catch { & $script:gsSay $_.Exception.Message $true; return }
        $src = $script:gsTitle.Text
        $ids = Select-Games 'Copy all settings' "Copy every setting shown for $src to these games. Their per-game settings will be replaced when you click Save all changes." @($script:gsTarget)
        if (-not $ids -or $ids.Count -eq 0) { return }
        foreach ($t in $ids) { $copy = [ordered]@{}; foreach ($k in $map.Keys) { $copy[$k] = $map[$k] }; $script:gsPending[$t] = $copy }
        & $script:refreshMarks
        & $script:gsSay "Queued a copy of $src's settings for $($ids.Count) game(s). Click Save all changes to apply."
    })

    $script:sw.FindName('Leftovers').Add_Click({
        if ($script:gsPending.Count -or $script:gsDirty) { & $script:gsSay 'Save or discard your changes first, then remove leftovers.' $true; return }
        $known = @('global') + @($script:gsGames | ForEach-Object { $_.Id })
        $orphans = @(Get-ChildItem $AppConfigDir -Filter *.json -ErrorAction SilentlyContinue | Where-Object { $known -notcontains $_.BaseName })
        if ($orphans.Count -eq 0) { & $script:gsSay 'No leftover settings files - every file belongs to a game in your library.'; return }
        $names = ($orphans | ForEach-Object { '  ' + $_.Name }) -join "`n"
        $a = [Windows.MessageBox]::Show("These settings files belong to games no longer in your Pimax library (for example a game that was removed and imported again):`n`n$names`n`nMove them to the backup folder?", 'Remove leftover settings', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        $dest = Join-Path $BackupDir 'settings\leftover'
        try {
            & $script:gsSay 'Removing leftover settings - restarting Pimax...'
            $ok = Invoke-WhilePimaxStopped {
                if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                foreach ($f in $orphans) { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $dest $f.Name) -Force }
            }
            Save-AutoSnapshot
            & $script:gsSay "Moved $($orphans.Count) leftover file(s) to $dest."
        } catch { & $script:gsSay "Couldn't remove leftovers: $($_.Exception.Message)" $true }
    })

    $script:sw.Add_Closing({
        try { & $script:gsStash } catch { }
        if ($script:gsPending.Count -eq 0 -and -not $script:gsDirty) { return }
        $a = [Windows.MessageBox]::Show("Save your changes to $($script:gsPending.Count) game(s) before closing?", 'Game settings', 'YesNoCancel', 'Question')
        if ($a -eq 'Cancel') { $_.Cancel = $true; return }
        if ($a -eq 'Yes') {
            try { [void](& $script:gsSaveAll) } catch { & $script:gsSay "Couldn't save: $($_.Exception.Message)" $true; $_.Cancel = $true }
        }
    })

    $start = $script:targets.Items | Where-Object { $_.Tag -eq $startId } | Select-Object -First 1
    if (-not $start) { $start = $script:targets.Items[0] }
    $script:gsTarget = $null; $script:gsDirty = $false; $script:gsSwitching = $false
    $script:targets.SelectedItem = $start
    if ($script:Capture -or $Test) { return $script:sw }
    [void]$script:sw.ShowDialog()
}

$ui.SettingsBtn.Add_Click({
    $g = Selected-Game
    $id = if ($g) { Get-GameId $g } else { 'global' }
    try { Show-GameSettings $id } catch { Set-Status "Game settings failed: $($_.Exception.Message)" $true }
})

# ---------- Backup & restore window ----------
function Format-SnapshotLine($s) {
    $when = ([datetime]$s.created).ToString('MMM d, yyyy  h:mm tt')
    $parts = @("$(@($s.images).Count) image(s)", "$(@($s.pinned).Count) pinned", "$(@($s.settings).Count) settings file(s)")
    "{0}   -   {1}   -   {2}" -f $when, $s.reason, ($parts -join ', ')
}

function Show-Backups($preselect, $lost) {
    $script:bw = New-DarkWindow 'Backup & restore' 760 600 @'
  <DockPanel Margin="14">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#BDBDBD" Margin="0,0,0,10"
      Text="A backup of your library images, library order and game settings is saved automatically every time you change them here, and when you open the app. If a Pimax update resets them, pick a backup and restore it."/>
    <TextBlock x:Name="BStatus" DockPanel.Dock="Bottom" Margin="0,10,0,0" Foreground="#8BC34A" TextWrapping="Wrap"/>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <Button x:Name="BClose" DockPanel.Dock="Right" Content="Close" Margin="8,0,0,0"/>
      <Button x:Name="BRestore" DockPanel.Dock="Right" Content="Restore selected" Background="#E65100" BorderBrush="#FFB74D" FontWeight="SemiBold"/>
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BNow" Content="Back up now" Background="#2E7D32" BorderBrush="#43A047"/>
        <Button x:Name="BOpen" Content="Open backup folder" Margin="8,0,0,0"/>
      </StackPanel>
    </DockPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
      <TextBlock Text="Restore:" VerticalAlignment="Center" Margin="0,0,12,0"/>
      <CheckBox x:Name="BImages" Content="Library images" IsChecked="True" Margin="0,0,16,0"/>
      <CheckBox x:Name="BOrder" Content="Library order" IsChecked="True" Margin="0,0,16,0"/>
      <CheckBox x:Name="BSettings" Content="Game settings" IsChecked="True"/>
    </StackPanel>
    <ListBox x:Name="BList" Background="#232323" Foreground="#EDEDED" BorderBrush="#3A3A3A"/>
  </DockPanel>
'@
    $script:bList = $script:bw.FindName('BList'); $script:bStatus = $script:bw.FindName('BStatus')
    $script:bSay = { param([string]$m, [bool]$bad = $false) $script:bStatus.Foreground = $(if ($bad) { '#EF5350' } else { '#8BC34A' }); $script:bStatus.Text = $m }
    $script:bFill = {
        param($selectPath)
        $script:bList.Items.Clear()
        foreach ($s in Get-Snapshots) {
            $it = New-Object Windows.Controls.ListBoxItem
            $it.Content = Format-SnapshotLine $s; $it.Tag = $s; $it.Padding = '6,5'
            [void]$script:bList.Items.Add($it)
            if ($selectPath -and $s.Path -eq $selectPath) { $script:bList.SelectedItem = $it }
        }
        if (-not $script:bList.SelectedItem -and $script:bList.Items.Count) { $script:bList.SelectedIndex = 0 }
        if (-not $script:bList.Items.Count) { & $script:bSay 'No backups yet. Click Back up now to make one.' }
    }
    & $script:bFill $(if ($preselect) { $preselect.Path } else { $null })
    if ($lost) {
        $script:bw.FindName('BImages').IsChecked = ($lost.Images.Count -gt 0)
        $script:bw.FindName('BOrder').IsChecked = [bool]$lost.Pins
        $script:bw.FindName('BSettings').IsChecked = ($lost.Settings.Count -gt 0)
        & $script:bSay 'The backup from before the reset is selected, with just the missing items ticked.'
    }

    $script:bw.FindName('BClose').Add_Click({ $script:bw.Close() })
    $script:bw.FindName('BOpen').Add_Click({ Start-Process explorer.exe $SnapshotDir })
    $script:bw.FindName('BNow').Add_Click({
        try { $d = New-Snapshot 'Manual'; & $script:bFill $d; & $script:bSay 'Backup saved.' }
        catch { & $script:bSay "Couldn't back up: $($_.Exception.Message)" $true }
    })
    $script:bw.FindName('BRestore').Add_Click({
        $it = $script:bList.SelectedItem
        if (-not $it) { & $script:bSay 'Pick a backup first.' $true; return }
        $img = [bool]$script:bw.FindName('BImages').IsChecked; $ord = [bool]$script:bw.FindName('BOrder').IsChecked; $set = [bool]$script:bw.FindName('BSettings').IsChecked
        if (-not ($img -or $ord -or $set)) { & $script:bSay 'Tick at least one thing to restore.' $true; return }
        $what = @($(if ($img) { 'library images' }), $(if ($ord) { 'library order' }), $(if ($set) { 'game settings' })) | Where-Object { $_ }
        $a = [Windows.MessageBox]::Show("Restore $($what -join ', ') from the backup of $(([datetime]$it.Tag.created).ToString('MMM d, h:mm tt'))?`n`nYour current state is backed up first, so you can undo this.", 'Restore backup', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        & $script:bSay 'Restoring - restarting Pimax...'
        $script:bw.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        try {
            $r = Restore-Snapshot $it.Tag $img $ord $set
            $msg = "Restored: $($r.Images) image(s), $($r.Order) pinned game(s) in order, $($r.Settings) settings file(s)."
            if ($r.Skipped.Count) { $msg += " Skipped (not in your library now): $($r.Skipped -join ', ')." }
            if (-not $r.ServiceOk) { $msg += ' Could not restart the Pimax service; restart your PC if it does not apply.' }
            & $script:bFill $it.Tag.Path
            & $script:bSay $msg (-not $r.ServiceOk)
            $ui.ResetBar.Visibility = 'Collapsed'
            Fill-List
        } catch { & $script:bSay "Couldn't restore: $($_.Exception.Message)" $true }
    })
    if ($script:Capture -or $Test) { return $script:bw }
    [void]$script:bw.ShowDialog()
}

$ui.BackupBtn.Add_Click({ try { Show-Backups $null $null } catch { Set-Status "Backup & restore failed: $($_.Exception.Message)" $true } })

# On start: if Pimax seems to have reset things since the last backup, offer to restore; otherwise take a backup
function Start-BackupCheck {
    try {
        $last = Get-Snapshots | Where-Object { $_.reason -ne 'Before restore' } | Select-Object -First 1
        if ($last) {
            $cmp = Compare-Snapshot $last
            if ($cmp.Any -and (Get-AppSetting 'dismissedSnapshot') -ne $last.created) {
                $bits = @()
                if ($cmp.Images.Count) { $bits += "$($cmp.Images.Count) library image(s)" }
                if ($cmp.Pins) { $bits += 'your library order' }
                if ($cmp.Settings.Count) { $bits += "$($cmp.Settings.Count) game settings file(s)" }
                $script:ResetSnap = $last; $script:ResetLost = $cmp
                $ui.ResetText.Text = "Pimax seems to have reset some of your changes ($($bits -join ', ')). Restore them from your backup of $(([datetime]$last.created).ToString('MMM d, h:mm tt'))?"
                $ui.ResetBar.Visibility = 'Visible'
                return
            }
        }
        Save-AutoSnapshot
    } catch { }
}
$ui.ResetRestore.Add_Click({ try { Show-Backups $script:ResetSnap $script:ResetLost } catch { Set-Status "Backup & restore failed: $($_.Exception.Message)" $true } })
$ui.ResetDismiss.Add_Click({ if ($script:ResetSnap) { Set-AppSetting 'dismissedSnapshot' $script:ResetSnap.created }; $ui.ResetBar.Visibility = 'Collapsed' })
$window.Add_Loaded({ $window.Dispatcher.BeginInvoke([action]{ Start-BackupCheck }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null })

# ---------- Update check ----------
function Get-UpdateInfo($release) {
    $tag = [string]$release.tag_name
    try { $latest = [version]($tag.TrimStart('v', 'V')) } catch { return $null }
    if ($latest -le [version]$AppVersion) { return $null }
    [pscustomobject]@{ Version = $latest.ToString(); Url = [string]$release.html_url }
}

function Set-VersionLabel([string]$state) {
    $l = $ui.VersionLabel
    $l.TextDecorations = $null
    switch ($state) {
        'checking'  { $l.Text = "v$AppVersion  -  Checking for updates..."; $l.Foreground = '#8A8A8A' }
        'current'   { $l.Text = "v$AppVersion  -  Up to date " + [char]0x2713; $l.Foreground = '#8BC34A' }
        'available' { $l.Text = "v$AppVersion  -  Update available"; $l.Foreground = '#42A5F5'; $l.TextDecorations = [Windows.TextDecorations]::Underline }
        default     { $l.Text = "v$AppVersion  -  Couldn't check for updates"; $l.Foreground = '#8A8A8A' }
    }
    $script:VersionState = $state
}

function Show-UpdateNotice($release) {
    $info = Get-UpdateInfo $release
    if (-not $info) { Set-VersionLabel 'current'; return }
    $script:UpdateUrl = $info.Url
    $ui.UpdateText.Text = "Version $($info.Version) of Pimax Game Manager is available (you have $AppVersion)."
    $ui.UpdateBar.Visibility = 'Visible'
    Set-VersionLabel 'available'
}

# Download in the background; a timer on the UI thread picks up the result
function Start-UpdateCheck {
    if ($script:VersionState -eq 'checking') { return }
    Set-VersionLabel 'checking'
    try {
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('User-Agent', 'pimax-game-manager')
        $wc.Encoding = [Text.Encoding]::UTF8
        $script:UpdateTask = $wc.DownloadStringTaskAsync([uri]$RepoApi)
        $script:UpdateStarted = Get-Date
        $script:UpdatePoll = New-Object Windows.Threading.DispatcherTimer
        $script:UpdatePoll.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:UpdatePoll.Add_Tick({
            if (-not $script:UpdateTask.IsCompleted) {
                if (((Get-Date) - $script:UpdateStarted).TotalSeconds -gt 30) { $script:UpdatePoll.Stop(); Set-VersionLabel 'failed' }
                return
            }
            $script:UpdatePoll.Stop()
            if ($script:UpdateTask.Status -ne 'RanToCompletion') { Set-VersionLabel 'failed'; return }
            try { Show-UpdateNotice ($script:UpdateTask.Result | ConvertFrom-Json) } catch { Set-VersionLabel 'failed' }
        })
        $script:UpdatePoll.Start()
    } catch { Set-VersionLabel 'failed' }
}

$ui.UpdateBtn.Add_Click({ if ($script:UpdateUrl) { Start-Process $script:UpdateUrl } })
$ui.UpdateClose.Add_Click({ $ui.UpdateBar.Visibility = 'Collapsed' })
$ui.VersionLabel.Add_MouseLeftButtonUp({
    if ($script:VersionState -eq 'available' -and $script:UpdateUrl) { Start-Process $script:UpdateUrl }
    else { Start-UpdateCheck }
})
$window.Add_Loaded({ Start-UpdateCheck })

$ui.RestartBtn.Add_Click({ Finish-Restart 'Pimax Play restarted.' })
$ui.RefreshBtn.Add_Click({ Fill-List; Set-Status 'Library list refreshed.' })

Fill-List
if ($ui.GameList.Items.Count -eq 0) { Set-Status "No games found in $ManifestDir - is Pimax Play installed?" $true }

if ($Test) {
    "TEST OK: window built, $($ui.GameList.Items.Count) games listed"
    foreach ($item in $ui.GameList.Items) {
        $g = $item.Tag
        "  {0,-45} Steam app: {1}" -f $item.Content, (Resolve-SteamAppId $g)
    }
    "--- Update check (app version $AppVersion):"
    try {
        $rel = Invoke-RestMethod -UseBasicParsing -Uri $RepoApi -Headers @{ 'User-Agent' = 'pimax-game-manager' }
        "  latest on GitHub: $($rel.tag_name)"
        "  newer than this app: " + [bool](Get-UpdateInfo $rel)
        $fake = [pscustomobject]@{ tag_name = 'v9.9.9'; html_url = 'https://example.test/r' }
        Show-UpdateNotice $fake
        "  simulated v9.9.9 -> bar visible: $($ui.UpdateBar.Visibility); text: $($ui.UpdateText.Text)"
        "  simulated v1.0.0 -> notice: " + [bool](Get-UpdateInfo ([pscustomobject]@{ tag_name = 'v1.0.0' }))
    } catch { "  check failed: $($_.Exception.Message)" }
    "--- Game settings (on a temporary copy of AppConfig; Pimax is not touched):"
    $realCfg = $AppConfigDir
    $AppConfigDir = Join-Path $env:TEMP ('pgm-test-' + [guid]::NewGuid().ToString('N'))
    Copy-Item $realCfg $AppConfigDir -Recurse
    $BackupDir = Join-Path $AppConfigDir '_backups'; New-Item -ItemType Directory $BackupDir | Out-Null
    $SnapshotDir = Join-Path $AppConfigDir '_snapshots'; New-Item -ItemType Directory $SnapshotDir | Out-Null
    $script:restarts = 0
    function Invoke-WhilePimaxStopped([scriptblock]$action) { $script:restarts++; & $action; return $true }
    foreach ($f in Get-ChildItem $AppConfigDir -Filter *.json) {
        $before = [IO.File]::ReadAllText($f.FullName) -replace "`r`n", "`n"
        Write-GameSettings $f.BaseName (Read-GameSettings $f.BaseName)
        $after = [IO.File]::ReadAllText($f.FullName)
        "  round-trip $($f.Name): " + $(if ($before.TrimEnd() -eq $after.TrimEnd()) { 'identical' } else { "DIFFERENT`n$before`n---`n$after" })
    }
    $sw = Show-GameSettings 'local.08db6433'
    $click = { param($b) $b.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    $rowOf = { param($k) $script:gsRows | Where-Object { $_.Def.Key -eq $k } }
    $pick = { param($row, $val) $row.Control.SelectedItem = ($row.Control.Items | Where-Object { $_.Tag -eq $val }) }
    $goTo = { param($id) $script:targets.SelectedItem = ($script:targets.Items | Where-Object { $_.Tag -eq $id }) }
    $fileOf = { param($id) $p = Get-SettingsPath $id; if (Test-Path $p) { ((Get-Content $p -Raw).Trim() -replace '\s+', ' ') } else { '(no file)' } }
    "  opened: $($script:gsTitle.Text)"
    # 1. Crysis: quality High (auto render 1.0) + center rendering Quality
    & $pick (& $rowOf 'piplay_display_quality_level') 2
    $c = & $rowOf 'runtime_foveated_rendering_level'; $c.Check.IsChecked = $true; $c.Control.IsEnabled = $true; & $pick $c 2
    # 2. switch to Pistol Whip, turn on Smart Smoothing custom
    & $goTo 'steam.app.1079800'
    "  switched to: $($script:gsTitle.Text); save button: $($script:gsSaveBtn.Content)"
    $a = & $rowOf 'runtime_dbg_asw_enable'; $a.Check.IsChecked = $true; $a.Control.IsEnabled = $true; & $pick $a 1
    # 3. apply Pistol Whip's Smart Smoothing to Beat Saber, copy all to The Forest
    function Select-Games { return @('steam.app.620980') }
    & $click $a.Apply
    function Select-Games { return @('steam.app.242760') }
    & $click $sw.FindName('CopyAll')
    "  queued: $($script:gsSaveBtn.Content); restarts so far: $script:restarts; files unchanged so far: " + ((& $fileOf 'steam.app.620980') -eq '(no file)')
    # 4. back to Crysis: edits kept?
    & $goTo 'local.08db6433'
    "  back on Crysis - quality: $((& $rowOf 'piplay_display_quality_level').Control.SelectedItem.Content), render: $((& $rowOf 'runtime_pixels_per_display_pixel_rate').Control.Text), center: $((& $rowOf 'runtime_foveated_rendering_level').Control.SelectedItem.Content)"
    "  list marks: " + (($script:targets.Items | Where-Object { $_.Content -match 'unsaved' } | ForEach-Object { $_.Content.Trim() }) -join ' | ')
    # 5. save all at once
    & $click $script:gsSaveBtn
    "  status: " + $script:gsStatus.Text + "   restarts: $script:restarts"
    "  CrysisVR:    " + (& $fileOf 'local.08db6433')
    "  Pistol Whip: " + (& $fileOf 'steam.app.1079800')
    "  Beat Saber:  " + (& $fileOf 'steam.app.620980')
    "  The Forest:  " + (& $fileOf 'steam.app.242760')
    "  save button after: $($script:gsSaveBtn.Content); unsaved marks left: " + @($script:targets.Items | Where-Object { $_.Content -match 'unsaved' }).Count
    # 6. undo + invalid value handling
    $rr = & $rowOf 'runtime_pixels_per_display_pixel_rate'; $rr.Control.Text = '5'
    & $click $script:gsSaveBtn
    "  invalid value: " + $script:gsStatus.Text
    & $click $sw.FindName('Revert')
    "  after undo, render: $($rr.Control.Text); dirty: $script:gsDirty"
    # 7. reset a game to global
    & $click $script:gsResetBtn
    "  reset button: $($script:gsResetBtn.Content); custom rows ticked now: " + @($script:gsRows | Where-Object { $_.Check.IsChecked }).Count + "; status: $($script:gsStatus.Text)"
    & $click $script:gsSaveBtn
    "  after save, CrysisVR file: " + (& $fileOf 'local.08db6433') + "; restarts: $script:restarts"
    & $goTo 'global'
    "  on Global the button reads: $($script:gsResetBtn.Content)"
    "  backups: " + ((Get-ChildItem (Join-Path $BackupDir 'settings') -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')
    "  real AppConfig untouched: " + (-not (Test-Path (Join-Path $realCfg 'steam.app.620980.json')))
    Remove-Item $AppConfigDir -Recurse -Force
    "--- Backup & restore (on temporary copies; Pimax is not touched):"
    $keepManifest = $ManifestDir; $keepClient = $ClientConfig
    $bt = Join-Path $env:TEMP ('pgm-bk-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $bt | Out-Null
    Copy-Item $ManifestDir (Join-Path $bt 'manifest') -Recurse; $ManifestDir = Join-Path $bt 'manifest'
    Copy-Item $realCfg (Join-Path $bt 'AppConfig') -Recurse; $AppConfigDir = Join-Path $bt 'AppConfig'
    Copy-Item $ClientConfig (Join-Path $bt 'config.json'); $ClientConfig = Join-Path $bt 'config.json'
    if (Test-Path $LegacyBackupDir) { Copy-Item $LegacyBackupDir (Join-Path $bt 'legacy') -Recurse }; $LegacyBackupDir = Join-Path $bt 'legacy'
    $CoverDir = Join-Path $bt 'covers'; $BackupDir = Join-Path $bt 'backups'; $SnapshotDir = Join-Path $bt 'snapshots'
    foreach ($d in $CoverDir, $BackupDir, $SnapshotDir) { New-Item -ItemType Directory $d -Force | Out-Null }
    # give the copy a pinned order to protect
    [IO.File]::WriteAllText($ClientConfig, (Set-PinnedIdsInText ([IO.File]::ReadAllText($ClientConfig)) @('local.66be7fbb', 'local.384c724b', 'steam.app.1079800')), $Utf8NoBom)
    $d1 = New-Snapshot 'Manual'
    $snap = Get-Snapshots | Select-Object -First 1
    "  backup made: " + (Format-SnapshotLine $snap)
    "  custom images in backup: " + (($snap.images | ForEach-Object { $_.name }) -join ', ')
    "  second automatic backup with no changes skipped: " + ($null -eq (New-Snapshot 'Automatic' -IfChanged))
    # simulate a Pimax update wiping things
    $cm = Join-Path $ManifestDir 'local.08db6433.json'; $j = Get-Content $cm -Raw | ConvertFrom-Json; $j.icon = ''; [IO.File]::WriteAllText($cm, ($j | ConvertTo-Json -Compress), $Utf8NoBom)
    [IO.File]::WriteAllText($ClientConfig, (Set-PinnedIdsInText ([IO.File]::ReadAllText($ClientConfig)) @()), $Utf8NoBom)
    Remove-Item (Join-Path $AppConfigDir 'steam.app.1079800.json')
    $old = Join-Path $ManifestDir 'local.384c724b.json'; $j = Get-Content $old -Raw | ConvertFrom-Json; $j.id = 'local.deadbeef'; $j.icon = ''
    [IO.File]::WriteAllText((Join-Path $ManifestDir 'local.deadbeef.json'), ($j | ConvertTo-Json -Compress), $Utf8NoBom); Remove-Item $old
    "  simulated wipe: Crysis image cleared, order emptied, Pistol Whip settings deleted, Flight Sim re-imported as local.deadbeef"
    $cmp = Compare-Snapshot $snap
    "  detected lost -> images: $($cmp.Images -join ', '); order: $($cmp.Pins); settings: $($cmp.Settings -join ', ')"
    $script:restarts = 0
    $r = Restore-Snapshot $snap $true $true $true
    "  restore report: images $($r.Images), pinned $($r.Order), settings $($r.Settings), skipped: $($r.Skipped -join ', '); Pimax restarts: $script:restarts"
    $ci = (Get-Content $cm -Raw | ConvertFrom-Json).icon
    "  Crysis icon now: $([IO.Path]::GetFileName($ci)) (file exists: $(Test-Path $ci))"
    $fi = (Get-Content (Join-Path $ManifestDir 'local.deadbeef.json') -Raw | ConvertFrom-Json).icon
    "  Flight Sim (new id) icon now: $([IO.Path]::GetFileName($fi)) (file exists: $(Test-Path $fi))"
    "  pinned now: " + ((Get-PinnedIds) -join ', ')
    "  Pistol Whip settings back: " + (Test-Path (Join-Path $AppConfigDir 'steam.app.1079800.json'))
    "  after restore, anything still lost: " + (Compare-Snapshot $snap).Any
    "  backups now: " + ((Get-Snapshots | ForEach-Object reason) -join ', ')
    $bwin = Show-Backups $null $null
    "  Backup window lists: $($script:bList.Items.Count) backup(s)"
    $ManifestDir = $keepManifest; $ClientConfig = $keepClient
    Remove-Item $bt -Recurse -Force
    "--- Library order window (not shown):"
    Show-Order | ForEach-Object { "  $_" }
    "--- Pin list write test (in memory only):"
    $cfg = [IO.File]::ReadAllText($ClientConfig)
    $ids = @(Get-PimaxGames | ForEach-Object { Get-GameId $_ } | Sort-Object)
    $out = Set-PinnedIdsInText $cfg $ids
    $strip = { param($t) [regex]::Replace($t, '"pinToTopGameArray"\s*:\s*\[[^\]]*\]', 'X') }
    "  rest of settings unchanged: " + ((& $strip $cfg) -eq (& $strip $out))
    "  pinned after write: " + (Get-PinnedIds $out).Count + " of " + $ids.Count
    $noKey = [regex]::Replace($cfg, ',\s*"pinToTopGameArray"\s*:\s*\[[^\]]*\]', '')
    $out2 = Set-PinnedIdsInText $noKey @('a','b')
    "  insert when missing: " + ((Get-PinnedIds $out2) -join ',') + "  tail: " + ($out2.Substring($out2.Length - 60) -replace "`n", '\n' -replace "`t", '\t')
    return
}
[void]$window.ShowDialog()
