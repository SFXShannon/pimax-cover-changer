# Pimax Cover Changer - set custom library images in Pimax Play
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
$CoverDir    = Join-Path $PimaxDir 'covers'
$BackupDir   = Join-Path $PimaxDir 'cover-backups'
$ServiceName = 'PiServiceLauncher'
$DefaultClient = 'C:\Program Files\Pimax\PimaxClient\pimaxui\PimaxClient.exe'
foreach ($d in $CoverDir, $BackupDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

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
    $svcOk = $true
    try { Restart-Service $ServiceName -Force -ErrorAction Stop } catch { $svcOk = $false }
    Start-Sleep -Seconds 4
    if (Test-Path $client) { Start-Process $client }
    return $svcOk
}

function Save-Cover($game, [string]$source) {
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
    if (-not (Test-Path $backup)) { throw 'No backup for this game - it still has its original image.' }
    Get-Process PimaxClient -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Copy-Item $backup $game.File -Force
    Remove-Item $backup -Force
}

# ---------- Image finder (Steam + SteamGridDB) ----------
$SettingsFile = Join-Path $PimaxDir 'cover-changer-settings.json'
function Get-SgdbKey {
    try { $k = ([IO.File]::ReadAllText($SettingsFile) | ConvertFrom-Json).sgdbKey; if ($k) { return [string]$k } } catch { }
    return ''
}
function Set-SgdbKey([string]$key) {
    [IO.File]::WriteAllText($SettingsFile, ([pscustomobject]@{ sgdbKey = $key } | ConvertTo-Json), $Utf8NoBom)
}

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

# ---------- Window ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pimax Cover Changer" Width="1020" Height="580" MinWidth="900" MinHeight="480"
        Background="#1B1B1B" Foreground="#EDEDED" FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2E2E2E"/><Setter Property="Foreground" Value="#EDEDED"/>
      <Setter Property="BorderBrush" Value="#444"/><Setter Property="Padding" Value="14,7"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.ColumnDefinitions><ColumnDefinition Width="280"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <DockPanel Grid.Column="0">
      <TextBlock DockPanel.Dock="Top" Text="Your Pimax library" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,8"/>
      <Button x:Name="RefreshBtn" DockPanel.Dock="Bottom" Content="Refresh list" Margin="0,8,0,0"/>
      <ListBox x:Name="GameList" Background="#232323" Foreground="#EDEDED" BorderBrush="#3A3A3A"/>
    </DockPanel>

    <DockPanel Grid.Column="2">
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

    <TextBlock x:Name="Status" Grid.Row="1" Grid.ColumnSpan="3" Margin="0,12,0,0" Foreground="#8BC34A" TextWrapping="Wrap"
               Text="Wide banner images (about 460x215 or 920x430) fit Pimax tiles best."/>
  </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'GameList','RefreshBtn','GameTitle','GameInfo','SourceBox','BrowseBtn','PreviewBtn','FindBtn','KeyBtn','ApplyBtn','RestoreBtn','RestartBtn','PreviewImg','NoImage','Status') { $ui[$n] = $window.FindName($n) }

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
    $info = "Source: $($g.Source)"
    if ($g.Source -ne 'Imported') { $info += "   -  Pimax may reset art for store games when it rescans your library." }
    $ui.GameInfo.Text = $info
    $ui.SourceBox.Text = ''
    try { Show-Preview $g.Icon; Set-Status 'Showing the current image.' } catch { Set-Status 'Current image could not be loaded.' $true }
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
    $first = $ui.GameList.Items[0].Tag
    $r = Find-Art $first $first.Name $true
    "Find-Art exact for $($first.Name): $($r.Items.Count) items. $($r.Note)"
    $r.Items | ForEach-Object { "    " + $_.Label + " -> " + $_.Url }
    $r = Find-Art $first 'Half-Life 2' $false
    "Find-Art search 'Half-Life 2': $($r.Items.Count) items. $($r.Note)"
    $r.Items | ForEach-Object { "    " + $_.Label }
    return
}
[void]$window.ShowDialog()
