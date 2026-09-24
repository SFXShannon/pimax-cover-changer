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

# ---------- Window ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pimax Cover Changer" Width="900" Height="560" MinWidth="760" MinHeight="480"
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
        <TextBlock Text="New image: paste a link (e.g. from SteamGridDB) or browse for a file" Foreground="#BDBDBD" Margin="0,10,0,4"/>
        <DockPanel>
          <Button x:Name="BrowseBtn" DockPanel.Dock="Right" Content="Browse..." Margin="8,0,0,0"/>
          <Button x:Name="PreviewBtn" DockPanel.Dock="Right" Content="Preview" Margin="8,0,0,0"/>
          <TextBox x:Name="SourceBox" Background="#232323" Foreground="#EDEDED" BorderBrush="#3A3A3A" Padding="6,6" VerticalContentAlignment="Center"/>
        </DockPanel>
        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
          <Button x:Name="ApplyBtn" Content="Apply image" Background="#2E7D32" BorderBrush="#43A047" FontWeight="SemiBold"/>
          <Button x:Name="RestoreBtn" Content="Restore original" Margin="8,0,0,0"/>
          <Button x:Name="RestartBtn" Content="Restart Pimax Play" Margin="8,0,0,0"/>
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
foreach ($n in 'GameList','RefreshBtn','GameTitle','GameInfo','SourceBox','BrowseBtn','PreviewBtn','ApplyBtn','RestoreBtn','RestartBtn','PreviewImg','NoImage','Status') { $ui[$n] = $window.FindName($n) }

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

$ui.RestartBtn.Add_Click({ Finish-Restart 'Pimax Play restarted.' })
$ui.RefreshBtn.Add_Click({ Fill-List; Set-Status 'Library list refreshed.' })

Fill-List
if ($ui.GameList.Items.Count -eq 0) { Set-Status "No games found in $ManifestDir - is Pimax Play installed?" $true }

if ($Test) {
    "TEST OK: window built, $($ui.GameList.Items.Count) games listed"
    $ui.GameList.Items | ForEach-Object { "  " + $_.Content }
    return
}
[void]$window.ShowDialog()
