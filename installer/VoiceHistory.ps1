param(
    [switch]$Test
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DvhNative
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr hObject);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }
}
"@

Add-Type @"
using System;
public static class DvhText
{
    public static string Diff(string before, string after)
    {
        if (after == null) return null;
        if (before == null) return string.Empty;
        if (before.Length > 8000) before = before.Substring(before.Length - 8000);
        if (after.Length > 8000) after = after.Substring(after.Length - 8000);
        int max = Math.Min(before.Length, after.Length);
        int prefix = 0;
        while (prefix < max && before[prefix] == after[prefix]) prefix++;
        int suffix = 0;
        while (suffix < (max - prefix) &&
               before[before.Length - 1 - suffix] == after[after.Length - 1 - suffix]) suffix++;
        int length = after.Length - prefix - suffix;
        if (length <= 0) return string.Empty;
        return after.Substring(prefix, length).Trim();
    }
}
"@

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DvhInject
{
    [DllImport("kernel32", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32", SetLastError=true)] public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, uint size, uint alloc, uint prot);
    [DllImport("kernel32", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, uint size, out UIntPtr written);
    [DllImport("kernel32", SetLastError=true)] public static extern IntPtr CreateRemoteThread(IntPtr h, IntPtr attr, uint stack, IntPtr start, IntPtr param, uint flags, IntPtr tid);
    [DllImport("kernel32", SetLastError=true)] public static extern IntPtr GetProcAddress(IntPtr h, string name);
    [DllImport("kernel32", SetLastError=true)] public static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
}
"@

$dataDir = Join-Path $env:APPDATA 'DoubaoVoiceHistory'
$historyFile = Join-Path $dataDir 'history.json'
$logFile = Join-Path $dataDir 'app.log'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'DoubaoVoiceHistory.lnk'
$scriptPath = $PSCommandPath
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

function Write-Log([string]$message)
{
    Add-Content -LiteralPath $logFile -Value ('{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $message) -Encoding UTF8
}

function Get-ElementText($element)
{
    if ($null -eq $element) { return $null }
    try
    {
        $valuePattern = $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        return [string]$valuePattern.Current.Value
    }
    catch { }
    try
    {
        $textPattern = $element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        $text = $null
        try
        {
            $selection = $textPattern.GetSelection()
            if ($selection.Count -gt 0)
            {
                $range = $selection[0].Clone()
                $range.MoveEndpointByUnit(
                    [System.Windows.Automation.TextPatternRangeEndpoint]::Start,
                    [System.Windows.Automation.TextUnit]::Character,
                    -8000)
                $text = [string]$range.GetText(-1)
            }
        }
        catch { }
        if ([string]::IsNullOrEmpty($text))
        {
            $text = [string]$textPattern.DocumentRange.GetText(8000)
        }
        return $text
    }
    catch { }
    return $null
}

function Get-InsertedText([string]$before, [string]$after)
{
    if ($null -eq $before -or $null -eq $after) { return '' }
    return [DvhText]::Diff($before, $after)
}

function Test-VoiceText([string]$text)
{
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    $value = $text.Trim()
    if ($value.Length -lt 1 -or $value.Length -gt 500) { return $false }
    if ($value -match '^(https?://|www\.|file://|[A-Za-z]:\\)') { return $false }
    if ($value -match '127\.0\.0\.1|localhost|://') { return $false }
    if ($value -notmatch '[\p{L}]') { return $false }
    return $true
}

function Test-TextElement($element)
{
    if ($null -eq $element) { return $false }
    try
    {
        $type = $element.Current.ControlType
        if ($type -eq [System.Windows.Automation.ControlType]::Edit -or
            $type -eq [System.Windows.Automation.ControlType]::Document)
        {
            return $true
        }
        return [bool]$element.Current.IsTextPatternAvailable
    }
    catch { return $false }
}

function Find-TextAncestor($element)
{
    $candidate = $element
    for ($i = 0; $i -lt 8 -and $null -ne $candidate; $i++)
    {
        if (Test-TextElement $candidate) { return $candidate }
        try
        {
            $candidate = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($candidate)
        }
        catch { return $null }
    }
    return $null
}

function Get-UiaTextSnapshot
{
    $foreground = [DvhNative]::GetForegroundWindow()
    if ($foreground -eq [IntPtr]::Zero) { return @() }
    try
    {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($foreground)
        if ($null -eq $root) { return @() }
        $condition = New-Object System.Windows.Automation.OrCondition(
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit)),
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Document)))
        $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        $snapshot = @()
        foreach ($element in $elements)
        {
            if ($snapshot.Count -ge 24) { break }
            $text = Get-ElementText $element
            if ($null -ne $text) {
                $snapshot += [pscustomobject]@{ Element = $element; Text = $text }
            }
        }
        return $snapshot
    }
    catch { return @() }
}

function Get-ForegroundWindowClass
{
    try
    {
        $foreground = [DvhNative]::GetForegroundWindow()
        if ($foreground -eq [IntPtr]::Zero) { return '' }
        $builder = New-Object System.Text.StringBuilder 256
        [DvhNative]::GetClassName($foreground, $builder, 256) | Out-Null
        return $builder.ToString()
    }
    catch { return '' }
}

function Copy-FocusedTextViaClipboard
{
    $oldClipboard = ''
    try { $oldClipboard = [System.Windows.Forms.Clipboard]::GetText() } catch { }
    try
    {
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        Start-Sleep -Milliseconds 60
        [System.Windows.Forms.SendKeys]::SendWait('^c')
        Start-Sleep -Milliseconds 140
        $text = [System.Windows.Forms.Clipboard]::GetText()
    }
    catch { $text = $null }
    try { [System.Windows.Forms.SendKeys]::SendWait('{END}') } catch { }
    try { if ($null -ne $oldClipboard) { [System.Windows.Forms.Clipboard]::SetText($oldClipboard) } } catch { }
    return $text
}

$script:injectedPids = @{}

function Inject-VoiceHook([int]$targetPid)
{
    if ($targetPid -le 0) { return }
    if ($script:injectedPids.ContainsKey($targetPid)) { return }
    $hook = Join-Path (Split-Path $PSCommandPath -Parent) 'voicehook.dll'
    if (-not (Test-Path -LiteralPath $hook)) {
        Write-Log 'inject skipped: voicehook.dll missing'
        return
    }
    $handle = [DvhInject]::OpenProcess(0x1F0FFF, $false, $targetPid)
    if ($handle -eq [IntPtr]::Zero) {
        Write-Log ("inject open failed pid={0} err={1}" -f $targetPid, [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        return
    }
    try {
        $bytes = [Text.Encoding]::Unicode.GetBytes($hook + "`0")
        $remote = [DvhInject]::VirtualAllocEx($handle, [IntPtr]::Zero, [uint32]$bytes.Length, 0x1000, 0x04)
        if ($remote -eq [IntPtr]::Zero) { throw 'VirtualAllocEx failed' }
        $written = [UIntPtr]::Zero
        if (-not [DvhInject]::WriteProcessMemory($handle, $remote, $bytes, [uint32]$bytes.Length, [ref]$written)) { throw 'WriteProcessMemory failed' }
        $load = [DvhInject]::GetProcAddress([DvhInject]::GetModuleHandle('kernel32.dll'), 'LoadLibraryW')
        $thread = [DvhInject]::CreateRemoteThread($handle, [IntPtr]::Zero, 0, $load, $remote, 0, [IntPtr]::Zero)
        if ($thread -eq [IntPtr]::Zero) { throw 'CreateRemoteThread failed' }
        [DvhInject]::WaitForSingleObject($thread, 300) | Out-Null
        [DvhInject]::CloseHandle($thread) | Out-Null
        $script:injectedPids[$targetPid] = $true
        Write-Log ("inject ok pid={0}" -f $targetPid)
    }
    catch {
        Write-Log ("inject failed pid={0}: {1}" -f $targetPid, $_.Exception.Message)
    }
    finally {
        [DvhInject]::CloseHandle($handle) | Out-Null
    }
}

function Read-VoiceTap
{
    $tapPath = Join-Path $dataDir 'voice-tap.log'
    if (-not (Test-Path -LiteralPath $tapPath)) { return }
    try
    {
        $fs = [System.IO.File]::Open($tapPath, 'Open', 'Read', 'ReadWrite')
        if ($fs.Length -lt $script:tapOffset) { $script:tapOffset = 0 }
        $fs.Seek($script:tapOffset, 'Begin') | Out-Null
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $content = $reader.ReadToEnd()
        $reader.Dispose()
        $fs.Dispose()
        $lastNewline = $content.LastIndexOf("`n")
        if ($lastNewline -lt 0) { return }
        $complete = $content.Substring(0, $lastNewline + 1)
        $script:tapOffset += [System.Text.Encoding]::UTF8.GetByteCount($complete)
        foreach ($line in ($complete -split "`r?`n"))
        {
            if ($line -match '^PeekVoiceCommit\|(.+)$')
            {
                $text = $matches[1].Trim()
                if (Test-VoiceText $text)
                {
                    $tapNow = Get-Date
                    if ($text -eq $script:lastTapText -and ($tapNow - $script:lastTapAt).TotalSeconds -lt 3)
                    {
                        Write-Log 'voice tap duplicate suppressed'
                        continue
                    }
                    $script:lastTapText = $text
                    $script:lastTapAt = $tapNow
                    $script:tapText = $text
                    Add-HistoryEntry $text | Out-Null
                    Show-Overlay $text
                    if ($historyWindow.IsVisible) { Refresh-HistoryView }
                    Write-Log ("voice tap captured len={0}" -f $text.Length)
                }
            }
        }
    }
    catch { }
}

function Merge-HistoryItems($items)
{
    $mergeWindowMinutes = 10
    $parsedItems = @($items | ForEach-Object {
        $text = ([string]$_.text).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return }
        $parsedTime = [datetime]::MinValue
        if (-not [datetime]::TryParseExact(
            ([string]$_.time).Trim(),
            'yyyy-MM-dd HH:mm:ss',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$parsedTime)) { return }
        $itemCount = 1
        if ($null -ne $_.count) {
            $parsedCount = 0
            if ([int]::TryParse([string]$_.count, [ref]$parsedCount) -and $parsedCount -gt 0) {
                $itemCount = $parsedCount
            }
        }
        [pscustomobject]@{
            time = $parsedTime.ToString('yyyy-MM-dd HH:mm:ss')
            text = $text
            count = $itemCount
            _parsed = $parsedTime
        }
    })

    $merged = New-Object System.Collections.ArrayList
    foreach ($item in @($parsedItems | Sort-Object _parsed))
    {
        $existing = $null
        for ($i = $merged.Count - 1; $i -ge 0; $i--)
        {
            $candidate = $merged[$i]
            if ($candidate.text -eq $item.text -and
                [math]::Abs(($item._parsed - $candidate._parsed).TotalMinutes) -le $mergeWindowMinutes)
            {
                $existing = $candidate
                break
            }
        }
        if ($null -ne $existing)
        {
            $existing.time = $item.time
            $existing._parsed = $item._parsed
            $existing.count += $item.count
        }
        else
        {
            [void]$merged.Add($item)
        }
    }

    return @($merged |
        Sort-Object _parsed -Descending |
        ForEach-Object {
            [pscustomobject]@{ time = $_.time; text = $_.text; count = [int]$_.count }
        })
}

function Load-History
{
    $script:history = @()
    if (-not (Test-Path -LiteralPath $historyFile)) { return }
    try
    {
        $raw = Get-Content -LiteralPath $historyFile -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $loaded = @($raw | ConvertFrom-Json)
        if ($loaded.Count -eq 1 -and $loaded[0] -is [array]) {
            $loaded = @($loaded[0])
        }
        $normalized = @($loaded |
            Where-Object { $null -ne $_ -and $_.text -and $_.time } |
            ForEach-Object {
                [pscustomobject]@{
                    time = [string]$_.time
                    text = [string]$_.text
                    count = $(if ($null -eq $_.count) { 1 } else { $_.count })
                }
            })
        $script:history = @(Merge-HistoryItems $normalized | Select-Object -First 500)
        if ($normalized.Count -ne $script:history.Count) {
            Write-Log ("history migrated: {0} -> {1}" -f $normalized.Count, $script:history.Count)
        }
        Save-History
    }
    catch { Write-Log "history load failed: $($_.Exception.Message)" }
}

function Save-History
{
    try
    {
        $json = ConvertTo-Json -InputObject @($script:history) -Depth 4
        Set-Content -LiteralPath $historyFile -Value $json -Encoding UTF8
    }
    catch { Write-Log "history save failed: $($_.Exception.Message)" }
}

function Add-HistoryEntry([string]$text)
{
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $cleanText = $text.Trim()
    $now = Get-Date
    $match = $null
    $matchTime = [datetime]::MinValue
    foreach ($entry in $script:history)
    {
        if (([string]$entry.text).Trim() -ne $cleanText) { continue }
        $entryTime = [datetime]::MinValue
        if (-not [datetime]::TryParseExact(
            ([string]$entry.time).Trim(),
            'yyyy-MM-dd HH:mm:ss',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$entryTime)) { continue }
        if (($now - $entryTime).TotalMinutes -le 10)
        {
            $match = $entry
            $matchTime = $entryTime
            break
        }
    }

    if ($null -ne $match)
    {
        $entryCount = 1
        $parsedCount = 0
        if ([int]::TryParse([string]$match.count, [ref]$parsedCount) -and $parsedCount -gt 0) {
            $entryCount = $parsedCount
        }
        if (($now - $matchTime).TotalSeconds -gt 2) { $entryCount++ }
        $match.count = $entryCount
        $match.time = $now.ToString('yyyy-MM-dd HH:mm:ss')
        $script:history = @($match) + @($script:history | Where-Object { -not [object]::ReferenceEquals($_, $match) })
        Save-History
        return $match
    }

    $entry = [pscustomobject]@{ time = $now.ToString('yyyy-MM-dd HH:mm:ss'); text = $cleanText; count = 1 }
    $script:history = @($entry) + @($script:history)
    if ($script:history.Count -gt 500) { $script:history = $script:history[0..499] }
    Save-History
    return $entry
}

function Set-ClipboardText([string]$text)
{
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    [System.Windows.Forms.Clipboard]::SetText($text)
}

function Format-HistoryTime([string]$value)
{
    try
    {
        $dt = [datetime]::ParseExact($value, 'yyyy-MM-dd HH:mm:ss', $null)
        if ($dt.Date -eq (Get-Date).Date) { return '今日 ' + $dt.ToString('HH:mm') }
        if ($dt.Date -eq (Get-Date).AddDays(-1).Date) { return '昨日 ' + $dt.ToString('HH:mm') }
        return $dt.ToString('MM.dd HH:mm')
    }
    catch { return $value }
}

function Get-BlurredBitmap($source, [int]$factor = 10)
{
    $w = [Math]::Max(8, [int]($source.Width / $factor))
    $h = [Math]::Max(8, [int]($source.Height / $factor))
    $small = New-Object System.Drawing.Bitmap $w, $h
    $g1 = [System.Drawing.Graphics]::FromImage($small)
    $g1.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
    $g1.DrawImage($source, 0, 0, $w, $h)
    $g1.Dispose()
    $large = New-Object System.Drawing.Bitmap $source.Width, $source.Height
    $g2 = [System.Drawing.Graphics]::FromImage($large)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($small, 0, 0, $source.Width, $source.Height)
    $g2.Dispose()
    $small.Dispose()
    return $large
}

function Set-GlassBackdrop($window, $target, $screenPoint, $dpi)
{
    try
    {
        $px = [int]$screenPoint.X
        $py = [int]$screenPoint.Y
        $w = [Math]::Max(1, [int]($window.ActualWidth * $dpi.M11))
        $h = [Math]::Max(1, [int]($window.ActualHeight * $dpi.M22))
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        $graphics.CopyFromScreen($px, $py, 0, 0, $bmp.Size)
        $graphics.Dispose()
        $blur = Get-BlurredBitmap $bmp 10
        $bmp.Dispose()
        $hBitmap = $blur.GetHbitmap()
        $bitmapSource = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
            $hBitmap,
            [IntPtr]::Zero,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        [DvhNative]::DeleteObject($hBitmap) | Out-Null
        $blur.Dispose()
        $brush = New-Object System.Windows.Media.ImageBrush($bitmapSource)
        $brush.Stretch = [System.Windows.Media.Stretch]::Fill
        $target.Background = $brush
    }
    catch { Write-Log "backdrop failed: $($_.Exception.Message)" }
}

function New-MicIcon
{
    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $ink = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 20, 20, 24))
    $gold = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 201, 168, 106), 2)
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(250, 247, 243, 234))
    $graphics.FillEllipse($ink, 0, 0, 31, 31)
    $graphics.DrawEllipse($gold, 1, 1, 29, 29)
    $graphics.FillRectangle($white, 12, 8, 7, 10)
    $graphics.FillEllipse($white, 12, 14, 7, 7)
    $graphics.DrawArc($gold, 9, 10, 13, 13, 0, 180)
    $graphics.DrawLine($gold, 15, 23, 15, 26)
    $graphics.Dispose()
    $ink.Dispose(); $gold.Dispose(); $white.Dispose()
    $handle = $bitmap.GetHicon()
    $script:iconBitmap = $bitmap
    $script:iconHandle = $handle
    return [System.Drawing.Icon]::FromHandle($handle)
}

Load-History

$script:lastFocusElement = $null
$script:focusHandler = [System.Windows.Automation.AutomationFocusChangedEventHandler]{
    param($sender, $eventArgs)
    try
    {
        if ($null -eq $sender) { return }
        if (Test-TextElement $sender) { $script:lastFocusElement = $sender }
    }
    catch { }
}
[System.Windows.Automation.Automation]::AddAutomationFocusChangedEventHandler($script:focusHandler)

$overlayXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DoubaoVoiceHistoryOverlay"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False"
        SizeToContent="WidthAndHeight" MinWidth="420" MaxWidth="580"
        FontFamily="Noto Serif SC">
  <Window.Resources>
    <Style x:Key="TextButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#D9D2C5"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="7,4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="Transparent" CornerRadius="3" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#D9BC82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter Property="Opacity" Value="0.6"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="OutlineButton" TargetType="Button" BasedOn="{StaticResource TextButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#0FFFFFFF" BorderBrush="#38FFFFFF" BorderThickness="1"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1FFFFFFF"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#66D9BC82"/>
                <Setter Property="Foreground" Value="#D9BC82"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GoldButton" TargetType="Button" BasedOn="{StaticResource TextButton}">
      <Setter Property="Foreground" Value="#1B1712"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#C9A86A" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#DCC08A"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#B8975C"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Card" Background="#E61A1A1E" BorderBrush="#38FFFFFF" BorderThickness="1" CornerRadius="16">
    <Border.RenderTransform>
      <TransformGroup>
        <ScaleTransform x:Name="CardScale" ScaleX="1" ScaleY="1"/>
        <TranslateTransform x:Name="CardTransform" Y="8"/>
      </TransformGroup>
    </Border.RenderTransform>
    <Grid>
      <Border Background="#9914161A" CornerRadius="15"/>
      <Border CornerRadius="15" IsHitTestVisible="False">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#1FFFFFFF" Offset="0"/>
            <GradientStop Color="#00FFFFFF" Offset="0.38"/>
          </LinearGradientBrush>
        </Border.Background>
      </Border>
      <Grid Margin="22,18,22,16">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0" LastChildFill="False" Margin="0,0,0,10">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
            <Rectangle Width="2" Height="14" Fill="#C9A86A" Margin="0,0,10,0" VerticalAlignment="Center"/>
            <TextBlock Text="本 次 识 别" FontSize="12" Foreground="#C6BEB0" VerticalAlignment="Center"/>
            <TextBlock x:Name="TimeText" FontFamily="Georgia" FontSize="10.5" Foreground="#8F887C"
                       Margin="12,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <Button x:Name="CloseButton" DockPanel.Dock="Right" Content="✕"
                  Style="{StaticResource TextButton}" Padding="6,2" FontSize="11" Foreground="#9A9286"/>
        </DockPanel>
        <TextBlock x:Name="TranscriptText" Grid.Row="1" FontSize="15.5" Foreground="#F7F3EA"
                   LineHeight="27" TextWrapping="Wrap" MaxHeight="135" Cursor="Hand"/>
        <Border Grid.Row="2" Height="1" Background="#2AFFFFFF" Margin="0,14,0,12"/>
        <Grid Grid.Row="3">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="StatusText" Grid.Column="0" FontSize="11.5" Foreground="#D9BC82"
                     VerticalAlignment="Center"/>
          <StackPanel Grid.Column="1" Orientation="Horizontal">
            <Button x:Name="HistoryButton" Content="历史" Style="{StaticResource OutlineButton}" Margin="0,0,10,0"/>
            <Button x:Name="CopyButton" Content="复制" Style="{StaticResource GoldButton}" Width="88"/>
          </StackPanel>
        </Grid>
        <Rectangle x:Name="ProgressLine" Grid.Row="4" Height="1" Fill="#C9A86A" Margin="0,12,0,0"
                   HorizontalAlignment="Stretch" RenderTransformOrigin="0,0.5">
          <Rectangle.RenderTransform>
            <ScaleTransform x:Name="ProgressScale" ScaleX="1"/>
          </Rectangle.RenderTransform>
        </Rectangle>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$historyXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="语音历史" Width="700" Height="600" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        FontFamily="Noto Serif SC">
  <Window.Resources>
    <Style x:Key="LinkButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#D9D2C5"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="6,3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="Transparent" CornerRadius="3" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#D9BC82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter Property="Opacity" Value="0.6"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FlatCheck" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C6BEB0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="box" Width="13" Height="13" BorderBrush="#66FFFFFF" BorderThickness="1"
                      Background="Transparent" Margin="0,0,8,0">
                <Path x:Name="check" Data="M2,7 L5.5,10.5 L11,3.5" Stroke="#C9A86A"
                      StrokeThickness="1.5" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="check" Property="Visibility" Value="Visible"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#C9A86A"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="box" Property="BorderBrush" Value="#C9A86A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <DataTemplate x:Key="HistoryTemplate">
      <Border x:Name="ItemRoot" Background="Transparent" Padding="0,13"
              BorderBrush="#1FFFFFFF" BorderThickness="0,0,0,1">
        <Grid>
          <Border x:Name="AccentRule" Width="2" Background="#C9A86A"
                  HorizontalAlignment="Left" Margin="-18,0,0,0" Visibility="Collapsed"/>
          <Grid Margin="10,0,0,0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <DockPanel Grid.Row="0" LastChildFill="False" Margin="0,0,0,5">
              <StackPanel Orientation="Horizontal" DockPanel.Dock="Left" VerticalAlignment="Center">
                <TextBlock Text="{Binding Time}" FontFamily="Georgia" FontSize="10.5"
                           Foreground="#B3AB9D" VerticalAlignment="Center"/>
                <Border x:Name="RepeatBadge" Background="#1FC9A86A" BorderBrush="#55C9A86A"
                        BorderThickness="1" CornerRadius="8" Padding="7,1,7,2" Margin="9,0,0,0">
                  <TextBlock Text="{Binding Repeat}" FontFamily="Georgia" FontSize="10"
                             Foreground="#E7CF9C" VerticalAlignment="Center"/>
                </Border>
              </StackPanel>
              <Button x:Name="ItemCopy" Content="复制" DockPanel.Dock="Right" Visibility="Collapsed"
                      Style="{StaticResource LinkButton}" Foreground="#D9BC82" Padding="6,2" FontSize="11"/>
            </DockPanel>
            <TextBlock Grid.Row="1" Text="{Binding Text}" FontSize="14" Foreground="#F3EFE6"
                       LineHeight="23" TextWrapping="Wrap" MaxHeight="72" TextTrimming="CharacterEllipsis"/>
          </Grid>
        </Grid>
      </Border>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Repeat}" Value="">
          <Setter TargetName="RepeatBadge" Property="Visibility" Value="Collapsed"/>
        </DataTrigger>
        <Trigger SourceName="ItemRoot" Property="IsMouseOver" Value="True">
          <Setter TargetName="ItemRoot" Property="Background" Value="#12FFFFFF"/>
          <Setter TargetName="AccentRule" Property="Visibility" Value="Visible"/>
          <Setter TargetName="ItemCopy" Property="Visibility" Value="Visible"/>
        </Trigger>
      </DataTemplate.Triggers>
    </DataTemplate>
  </Window.Resources>

  <Border x:Name="GlassRoot" Background="#E61A1A1E" BorderBrush="#38FFFFFF" BorderThickness="1" CornerRadius="16">
    <Grid>
      <Border Background="#C0141418" CornerRadius="15"/>
      <Border CornerRadius="15" IsHitTestVisible="False">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#1FFFFFFF" Offset="0"/>
            <GradientStop Color="#00FFFFFF" Offset="0.32"/>
          </LinearGradientBrush>
        </Border.Background>
      </Border>
      <Grid Margin="30,22,30,20">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <StackPanel x:Name="TitlePanel" Orientation="Horizontal" Background="Transparent">
            <Rectangle Width="2" Height="22" Fill="#C9A86A" Margin="0,5,11,0" VerticalAlignment="Top"/>
            <StackPanel>
              <TextBlock Text="语 音 历 史" FontSize="23" Foreground="#F7F3EA"/>
              <TextBlock x:Name="CountText" FontSize="11" Foreground="#A8A196" Margin="1,5,0,0"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
            <Button x:Name="CheckUpdateButton" Content="检查更新" Style="{StaticResource LinkButton}" Margin="0,0,10,0"/>
            <Button x:Name="OpenDirButton" Content="打开目录" Style="{StaticResource LinkButton}" Margin="0,0,10,0"/>
            <Button x:Name="MinButton" Content="—" Style="{StaticResource LinkButton}" FontSize="13" Margin="0,0,2,0"/>
            <Button x:Name="CloseHistoryButton" Content="✕" Style="{StaticResource LinkButton}" FontSize="11"/>
          </StackPanel>
        </Grid>

        <Border Grid.Row="1" Height="1" Background="#2AFFFFFF" Margin="0,16,0,0"/>

        <Grid Grid.Row="2" Margin="0,18,0,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="⌕" FontSize="16" Foreground="#A8A196" Margin="0,0,10,0" VerticalAlignment="Center"/>
          <Grid Grid.Column="1">
            <TextBox x:Name="SearchBox" Background="Transparent" BorderThickness="0"
                     Foreground="#F7F3EA" CaretBrush="#C9A86A" FontSize="13"
                     VerticalContentAlignment="Center" Padding="0,4,0,6"/>
            <TextBlock x:Name="SearchHint" Text="搜索识别内容…" Foreground="#B3AB9D" FontSize="13"
                       VerticalAlignment="Center" Margin="1,0,0,6" IsHitTestVisible="False"/>
          </Grid>
          <Button x:Name="SearchClearButton" Grid.Column="2" Content="×" Style="{StaticResource LinkButton}"
                  Visibility="Collapsed" FontSize="14" Foreground="#8F887C"/>
          <Border Grid.ColumnSpan="3" Height="1" Background="#44FFFFFF" VerticalAlignment="Bottom"/>
        </Grid>

        <Grid Grid.Row="3">
          <ListBox x:Name="HistoryList" Background="Transparent" BorderThickness="0"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                   ItemTemplate="{StaticResource HistoryTemplate}">
            <ListBox.ItemContainerStyle>
              <Style TargetType="ListBoxItem">
                <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="BorderThickness" Value="0"/>
                <Setter Property="Padding" Value="0"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem"><ContentPresenter/></ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>
            </ListBox.ItemContainerStyle>
          </ListBox>
          <StackPanel x:Name="EmptyPanel" VerticalAlignment="Center" HorizontalAlignment="Center"
                      Visibility="Collapsed">
            <Border Width="52" Height="52" CornerRadius="26" BorderBrush="#44FFFFFF" BorderThickness="1"
                    HorizontalAlignment="Center">
              <TextBlock Text="—" FontSize="18" Foreground="#C9A86A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="EmptyTitle" Text="尚 无 记 录" FontSize="15" Foreground="#F7F3EA"
                       HorizontalAlignment="Center" Margin="0,14,0,5"/>
            <TextBlock x:Name="EmptySubtitle" Text="按语音快捷键说一段，识别结果会自动出现在这里"
                       Foreground="#B3AB9D" FontSize="12" HorizontalAlignment="Center"/>
          </StackPanel>
        </Grid>

        <Grid Grid.Row="4" Margin="0,16,0,0">
          <Border Height="1" Background="#2AFFFFFF" VerticalAlignment="Top"/>
          <DockPanel Margin="0,14,0,0" LastChildFill="False">
            <CheckBox x:Name="AutoStartCheck" Content="开机启动" Style="{StaticResource FlatCheck}" VerticalAlignment="Center"/>
            <CheckBox x:Name="AutoUpdateCheck" Content="自动更新" Style="{StaticResource FlatCheck}" VerticalAlignment="Center" Margin="18,0,0,0"/>
            <TextBlock Text="↑↓ 选择 · Enter 复制 · Delete 删除 · Esc 关闭" Foreground="#8F887C"
                       FontSize="10.5" VerticalAlignment="Center" Margin="18,0,0,0"/>
            <TextBlock x:Name="HistoryStatus" DockPanel.Dock="Right" Foreground="#D9BC82" FontSize="11.5"
                       VerticalAlignment="Center" Margin="0,0,14,0"/>
            <Button x:Name="ClearButton" Content="清空" DockPanel.Dock="Right" Style="{StaticResource LinkButton}"
                    Foreground="#D9BC82" Margin="0,0,4,0"/>
            <Button x:Name="DeleteButton" Content="删除选中" DockPanel.Dock="Right" Style="{StaticResource LinkButton}"
                    IsEnabled="False" Margin="0,0,8,0"/>
          </DockPanel>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$overlay = [System.Windows.Markup.XamlReader]::Parse($overlayXaml)
$historyWindow = [System.Windows.Markup.XamlReader]::Parse($historyXaml)

$card = $overlay.FindName('Card')
$transcriptText = $overlay.FindName('TranscriptText')
$statusText = $overlay.FindName('StatusText')
$timeText = $overlay.FindName('TimeText')
$closeButton = $overlay.FindName('CloseButton')
$copyButton = $overlay.FindName('CopyButton')
$historyButton = $overlay.FindName('HistoryButton')
$cardScale = $overlay.FindName('CardScale')
$cardTransform = $overlay.FindName('CardTransform')
$progressScale = $overlay.FindName('ProgressScale')

$glassRoot = $historyWindow.FindName('GlassRoot')
$titlePanel = $historyWindow.FindName('TitlePanel')
$historyList = $historyWindow.FindName('HistoryList')
$searchBox = $historyWindow.FindName('SearchBox')
$searchHint = $historyWindow.FindName('SearchHint')
$searchClearButton = $historyWindow.FindName('SearchClearButton')
$countText = $historyWindow.FindName('CountText')
$emptyPanel = $historyWindow.FindName('EmptyPanel')
$emptyTitle = $historyWindow.FindName('EmptyTitle')
$emptySubtitle = $historyWindow.FindName('EmptySubtitle')
$clearButton = $historyWindow.FindName('ClearButton')
$deleteButton = $historyWindow.FindName('DeleteButton')
$openDirButton = $historyWindow.FindName('OpenDirButton')
$checkUpdateButton = $historyWindow.FindName('CheckUpdateButton')
$minButton = $historyWindow.FindName('MinButton')
$closeHistoryButton = $historyWindow.FindName('CloseHistoryButton')
$autoStartCheck = $historyWindow.FindName('AutoStartCheck')
$autoUpdateCheck = $historyWindow.FindName('AutoUpdateCheck')
$historyStatus = $historyWindow.FindName('HistoryStatus')

$script:currentText = ''
$script:historyView = @()

function Position-Overlay
{
    $voiceHwnd = [DvhNative]::FindWindow('OimeVoiceWaveWindow', $null)
    if ($voiceHwnd -ne [IntPtr]::Zero)
    {
        $rect = New-Object DvhNative+RECT
        [DvhNative]::GetWindowRect($voiceHwnd, [ref]$rect) | Out-Null
        $source = [System.Windows.PresentationSource]::FromVisual($overlay)
        $toDip = $source.CompositionTarget.TransformFromDevice
        $topLeft = $toDip.Transform([System.Windows.Point]::new([double]$rect.Left, [double]$rect.Top))
        $bottomRight = $toDip.Transform([System.Windows.Point]::new([double]$rect.Right, [double]$rect.Bottom))
        $left = (($topLeft.X + $bottomRight.X) / 2) - ($overlay.ActualWidth / 2)
        $top = $topLeft.Y - $overlay.ActualHeight - 10
    }
    else
    {
        $work = [System.Windows.SystemParameters]::WorkArea
        $left = $work.Left + ($work.Width - $overlay.ActualWidth) / 2
        $top = $work.Bottom - $overlay.ActualHeight - 80
    }
    $work = [System.Windows.SystemParameters]::WorkArea
    if ($left -lt $work.Left) { $left = $work.Left + 8 }
    if ($top -lt $work.Top) { $top = $work.Top + 8 }
    if ($left + $overlay.ActualWidth -gt $work.Right) { $left = $work.Right - $overlay.ActualWidth - 8 }
    if ($top + $overlay.ActualHeight -gt $work.Bottom) { $top = $work.Bottom - $overlay.ActualHeight - 8 }
    $overlay.Left = $left
    $overlay.Top = $top
}

function Flash-Status([string]$text)
{
    $statusText.Text = $text
    $statusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $statusText.Opacity = 0
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From = 0; $fade.To = 1
    $fade.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(140))
    $statusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
}

function Show-Overlay
{
    param([string]$text, [switch]$Pending)
    if ($Pending)
    {
        $script:currentText = ''
        $transcriptText.Text = '正在识别…'
        $transcriptText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#B3AB9D')
        Flash-Status '正在等待识别结果'
        $copyButton.IsEnabled = $false
    }
    else
    {
        if ([string]::IsNullOrWhiteSpace($text)) { $text = '（本次没有捕获到文本）' }
        $script:currentText = $text
        $transcriptText.Text = $text
        $transcriptText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F7F3EA')
        $statusText.Text = ''
        $copyButton.IsEnabled = $true
        $copyButton.Content = '复制'
    }
    $timeText.Text = (Get-Date).ToString('HH:mm')

    if ($overlay.IsVisible)
    {
        $progressScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
        $progressScale.ScaleX = 1
        $progress = New-Object System.Windows.Media.Animation.DoubleAnimation
        $progress.From = 1; $progress.To = 0
        $progress.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(22))
        $progressScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $progress)
        $script:hideTimer.Stop()
        $script:hideTimer.Start()
        return
    }

    $overlay.Opacity = 0
    $overlay.Show()
    $overlay.UpdateLayout()
    Position-Overlay
    $screenPoint = $overlay.PointToScreen([System.Windows.Point]::new(0, 0))
    $dpi = [System.Windows.PresentationSource]::FromVisual($overlay).CompositionTarget.TransformToDevice
    $overlay.Hide()
    Start-Sleep -Milliseconds 25
    Set-GlassBackdrop $overlay $card $screenPoint $dpi

    $overlay.BeginAnimation([System.Windows.Window]::OpacityProperty, $null)
    $cardScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $cardScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $cardTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    $progressScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $overlay.Opacity = 0
    $cardScale.ScaleX = 0.985; $cardScale.ScaleY = 0.985
    $cardTransform.Y = 8
    $progressScale.ScaleX = 1
    $overlay.Show()

    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From = 0; $fade.To = 1
    $fade.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(210))
    $fade.EasingFunction = $ease
    $scale = New-Object System.Windows.Media.Animation.DoubleAnimation
    $scale.From = 0.985; $scale.To = 1
    $scale.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(260))
    $scale.EasingFunction = $ease
    $move = New-Object System.Windows.Media.Animation.DoubleAnimation
    $move.From = 8; $move.To = 0
    $move.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(260))
    $move.EasingFunction = $ease
    $overlay.BeginAnimation([System.Windows.Window]::OpacityProperty, $fade)
    $cardScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $scale)
    $cardScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $scale)
    $cardTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $move)

    $progress = New-Object System.Windows.Media.Animation.DoubleAnimation
    $progress.From = 1; $progress.To = 0
    $progress.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(22))
    $progressScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $progress)

    $script:hideTimer.Stop()
    $script:hideTimer.Start()
    Write-Log ("overlay show pending={0} len={1}" -f $Pending.IsPresent, $text.Length)
}

function Hide-Overlay
{
    $script:hideTimer.Stop()
    if (-not $overlay.IsVisible) { return }
    $progressScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From = 1; $fade.To = 0
    $fade.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(150))
    $fade.EasingFunction = $ease
    $move = New-Object System.Windows.Media.Animation.DoubleAnimation
    $move.From = 0; $move.To = 5
    $move.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(170))
    $move.EasingFunction = $ease
    $fade.Add_Completed({
        $overlay.Hide()
        $overlay.BeginAnimation([System.Windows.Window]::OpacityProperty, $null)
        $overlay.Opacity = 1
    })
    $overlay.BeginAnimation([System.Windows.Window]::OpacityProperty, $fade)
    $cardTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $move)
}

function Refresh-HistoryView
{
    $query = $searchBox.Text.Trim()
    $items = @($script:history | Sort-Object time -Descending)
    if (-not [string]::IsNullOrWhiteSpace($query))
    {
        $items = @($items | Where-Object { $_.text -like "*$query*" })
    }
    $script:historyView = $items
    $totalOccurrences = 0
    foreach ($entry in $script:history) {
        $parsedTotal = 0
        if ([int]::TryParse([string]$entry.count, [ref]$parsedTotal) -and $parsedTotal -gt 0) {
            $totalOccurrences += $parsedTotal
        } else {
            $totalOccurrences++
        }
    }
    $historyList.ItemsSource = @($items | ForEach-Object {
        $itemCount = 1
        $parsedCount = 0
        if ([int]::TryParse([string]$_.count, [ref]$parsedCount) -and $parsedCount -gt 0) {
            $itemCount = $parsedCount
        }
        [pscustomobject]@{
            Time = (Format-HistoryTime $_.time)
            Repeat = $(if ($itemCount -gt 1) { "×$itemCount" } else { '' })
            Text = $_.text
            Raw = $_.text
            TimeRaw = $_.time
        }
    })
    $countText.Text = '{0} 条记录 · 共 {1} 次识别 · 本地保存' -f $script:history.Count, $totalOccurrences
    $searchHint.Visibility = if ([string]::IsNullOrEmpty($searchBox.Text)) { 'Visible' } else { 'Collapsed' }
    $searchClearButton.Visibility = if ([string]::IsNullOrEmpty($searchBox.Text)) { 'Collapsed' } else { 'Visible' }
    $emptyPanel.Visibility = if ($items.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $historyList.Visibility = if ($items.Count -eq 0) { 'Collapsed' } else { 'Visible' }
    if ($items.Count -eq 0)
    {
        $emptyTitle.Text = if ($script:history.Count -eq 0) { '尚 无 记 录' } else { '没有找到匹配的记录' }
        $emptySubtitle.Text = if ($script:history.Count -eq 0) { '按语音快捷键说一段，识别结果会自动出现在这里' } else { '换一个关键词再试试' }
    }
    $deleteButton.IsEnabled = $false
}

function Show-History
{
    if ($overlay.IsVisible) { $overlay.Hide() }
    Refresh-HistoryView
    if (-not $historyWindow.IsVisible)
    {
        $historyWindow.Opacity = 0
        $historyWindow.Show()
        $historyWindow.UpdateLayout()
        $screenPoint = $historyWindow.PointToScreen([System.Windows.Point]::new(0, 0))
        $dpi = [System.Windows.PresentationSource]::FromVisual($historyWindow).CompositionTarget.TransformToDevice
        $historyWindow.Hide()
        Start-Sleep -Milliseconds 25
        Set-GlassBackdrop $historyWindow $glassRoot $screenPoint $dpi
        $historyWindow.Opacity = 0
        $historyWindow.Show()
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fade.From = 0; $fade.To = 1
        $fade.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(200))
        $historyWindow.BeginAnimation([System.Windows.Window]::OpacityProperty, $fade)
    }
    else
    {
        $historyWindow.Activate()
    }
    $searchBox.Focus() | Out-Null
}

function Copy-SelectedHistory
{
    $index = $historyList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:historyView.Count) { return }
    $item = $script:historyView[$index]
    Set-ClipboardText $item.Raw
    $historyStatus.Text = '已复制到剪贴板'
}

function Remove-SelectedHistory
{
    $index = $historyList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:historyView.Count) { return }
    $item = $script:historyView[$index]
    $remaining = @()
    $removed = $false
    foreach ($entry in $script:history)
    {
        if (-not $removed -and $entry.time -eq $item.TimeRaw -and $entry.text -eq $item.Raw)
        {
            $removed = $true
            continue
        }
        $remaining += $entry
    }
    $script:history = $remaining
    Save-History
    Refresh-HistoryView
    $historyStatus.Text = '已删除一条记录'
}

function Update-Autostart
{
    try
    {
        if ($autoStartCheck.IsChecked)
        {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($startupLnk)
            $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $shortcut.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
            $shortcut.WorkingDirectory = Split-Path $scriptPath -Parent
            $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
            $shortcut.Save()
            $historyStatus.Text = '已开启开机启动'
        }
        else
        {
            Remove-Item -LiteralPath $startupLnk -Force -ErrorAction SilentlyContinue
            $historyStatus.Text = '已关闭开机启动'
        }
    }
    catch { $historyStatus.Text = '设置失败' }
}

$settingsFile = Join-Path $dataDir 'settings.json'

function Get-AutoUpdateSetting
{
    if (Test-Path -LiteralPath $settingsFile)
    {
        try
        {
            $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
            if ($null -ne $settings.autoUpdate) { return [bool]$settings.autoUpdate }
        }
        catch { }
    }
    return $true
}

function Set-AutoUpdateSetting([bool]$enabled)
{
    try
    {
        @{ autoUpdate = $enabled } | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8
        $taskName = 'DoubaoVoiceHistory-AutoUpdate'
        $updater = Join-Path (Split-Path $PSCommandPath -Parent) 'Update.ps1'
        if ($enabled)
        {
            schtasks.exe /Query /TN $taskName 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0)
            {
                $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$updater`" -Auto"
                schtasks.exe /Create /SC HOURLY /MO 6 /TN $taskName /TR $tr /F 2>$null | Out-Null
            }
            else
            {
                schtasks.exe /Change /TN $taskName /ENABLE 2>$null | Out-Null
            }
        }
        else
        {
            schtasks.exe /Change /TN $taskName /DISABLE 2>$null | Out-Null
        }
    }
    catch { }
}

$script:updateJob = $null

function Start-UpdateCheck
{
    if ($null -ne $script:updateJob -and $script:updateJob.State -eq 'Running') { return }
    $checkUpdateButton.IsEnabled = $false
    $checkUpdateButton.Content = '检查中…'
    $historyStatus.Text = '正在检查 GitHub 最新版本…'
    $script:updateJob = Start-Job -ScriptBlock {
        param($appDir)
        $config = Get-Content (Join-Path $appDir 'update.json') -Raw | ConvertFrom-Json
        $local = (Get-Content (Join-Path $appDir 'VERSION.json') -Raw | ConvertFrom-Json).version
        $headers = @{ 'User-Agent' = 'DoubaoVoiceHistory'; 'Accept' = 'application/vnd.github+json' }
        $token = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'User')
        if ($token) { $headers['Authorization'] = "Bearer $token" }
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($config.repo)/releases/latest" -Headers $headers
        [pscustomobject]@{
            Current = $local
            Latest = ($release.tag_name -replace '^v','')
            Url = $release.html_url
            Body = $release.body
        }
    } -ArgumentList (Split-Path $PSCommandPath -Parent)
}

$script:updateTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:updateTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:updateTimer.Add_Tick({
    if ($null -eq $script:updateJob) { return }
    if ($script:updateJob.State -eq 'Running') { return }
    $result = @(Receive-Job $script:updateJob -ErrorAction SilentlyContinue)
    Remove-Job $script:updateJob -Force -ErrorAction SilentlyContinue
    $script:updateJob = $null
    $checkUpdateButton.IsEnabled = $true
    $checkUpdateButton.Content = '检查更新'
    if ($result.Count -eq 0) {
        $historyStatus.Text = '检查失败，请查看 update.log'
        return
    }
    $release = $result[-1]
    if ([version]$release.Latest -le [version]$release.Current) {
        $historyStatus.Text = "已是最新版本 $($release.Current)"
        return
    }
    $answer = [System.Windows.MessageBox]::Show(
        "发现新版本 $($release.Latest)（当前 $($release.Current)）`n`n是否下载并覆盖安装？",
        '检查更新',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        $historyStatus.Text = '已取消更新'
        return
    }
    $updater = Join-Path (Split-Path $PSCommandPath -Parent) 'Update.ps1'
    Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$updater,'-Install' -WindowStyle Hidden
    $historyStatus.Text = '正在下载并安装，程序即将重启…'
    $script:shutdownTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:shutdownTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:shutdownTimer.Add_Tick({
        $script:shutdownTimer.Stop()
        $app.Shutdown()
    })
    $script:shutdownTimer.Start()
})

$script:copyTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:copyTimer.Interval = [TimeSpan]::FromSeconds(1.6)
$script:copyTimer.Add_Tick({
    $script:copyTimer.Stop()
    $copyButton.Content = '复制'
    $statusText.Text = ''
})

$copyButton.Add_Click({
    Set-ClipboardText $script:currentText
    $copyButton.Content = '已复制'
    Flash-Status '已复制到剪贴板'
    $script:copyTimer.Stop(); $script:copyTimer.Start()
})

$transcriptText.Add_MouseLeftButtonUp({
    Set-ClipboardText $script:currentText
    Flash-Status '已复制到剪贴板'
    $script:copyTimer.Stop(); $script:copyTimer.Start()
})

$closeButton.Add_Click({ Hide-Overlay })
$historyButton.Add_Click({ Show-History })

$script:hideTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:hideTimer.Interval = [TimeSpan]::FromSeconds(22)
$script:hideTimer.Add_Tick({ Hide-Overlay })

$searchBox.Add_TextChanged({ Refresh-HistoryView })
$searchClearButton.Add_Click({ $searchBox.Text = ''; $searchBox.Focus() | Out-Null })
$checkUpdateButton.Add_Click({ Start-UpdateCheck })
$historyList.Add_SelectionChanged({ $deleteButton.IsEnabled = ($historyList.SelectedIndex -ge 0) })
$historyList.Add_PreviewMouseLeftButtonUp({ if ($historyList.SelectedIndex -ge 0) { Copy-SelectedHistory } })

$titlePanel.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq [System.Windows.Input.MouseButtonState]::Pressed) { $historyWindow.DragMove() }
})

$minButton.Add_Click({ $historyWindow.WindowState = 'Minimized' })
$closeHistoryButton.Add_Click({ $historyWindow.Hide() })

$historyWindow.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $historyWindow.Hide(); $e.Handled = $true; return }
    if ($searchBox.IsKeyboardFocusWithin) { return }
    if ($e.Key -eq [System.Windows.Input.Key]::Enter) { Copy-SelectedHistory; $e.Handled = $true }
    elseif ($e.Key -eq [System.Windows.Input.Key]::Delete) { Remove-SelectedHistory; $e.Handled = $true }
})

$deleteButton.Add_Click({ Remove-SelectedHistory })
$clearButton.Add_Click({
    $answer = [System.Windows.MessageBox]::Show('确定清空全部语音历史？此操作不可撤销。', '语音历史',
        [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($answer -eq [System.Windows.MessageBoxResult]::Yes)
    {
        $script:history = @()
        Save-History
        Refresh-HistoryView
        $historyStatus.Text = '历史已清空'
    }
})
$openDirButton.Add_Click({ Start-Process explorer.exe -ArgumentList $dataDir })
$autoStartCheck.IsChecked = Test-Path -LiteralPath $startupLnk
$autoStartCheck.Add_Click({ Update-Autostart })
$autoUpdateCheck.IsChecked = Get-AutoUpdateSetting
$autoUpdateCheck.Add_Click({
    $enabled = [bool]$autoUpdateCheck.IsChecked
    Set-AutoUpdateSetting $enabled
    $historyStatus.Text = if ($enabled) { '已开启自动更新' } else { '已关闭自动更新' }
})

$script:pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:pollTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$script:pollTimer.Add_Tick({
    if (((Get-Date) - $script:tapReadAt).TotalMilliseconds -ge 250) {
        $script:tapReadAt = Get-Date
        Read-VoiceTap
    }
    if (((Get-Date) - $script:targetCheckAt).TotalMilliseconds -ge 1000) {
        $script:targetCheckAt = Get-Date
        try {
            $foreground = [DvhNative]::GetForegroundWindow()
            $foregroundPid = 0
            [DvhNative]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid) | Out-Null
            $process = [System.Diagnostics.Process]::GetProcessById($foregroundPid)
            if ($process -and $process.ProcessName -notmatch 'ImeService|ImeWatchdog|powershell|pwsh') {
                $script:lastTargetPid = $foregroundPid
                $script:lastTargetName = $process.ProcessName
            }
        } catch { }
    }
    $hwnd = [DvhNative]::FindWindow('OimeVoiceWaveWindow', $null)
    $visible = ($hwnd -ne [IntPtr]::Zero) -and [DvhNative]::IsWindowVisible($hwnd)
    if ($visible -and -not $script:voiceVisible)
    {
        $script:voiceVisible = $true
        try
        {
            $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
            $candidate = Find-TextAncestor $focused
            if ($null -eq $candidate) { $candidate = $script:lastFocusElement }
            $script:focusElement = $candidate
            $script:beforeText = Get-ElementText $candidate
            $foreground = [DvhNative]::GetForegroundWindow()
            $foregroundPid = 0
            $threadId = [DvhNative]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
            $gui = New-Object DvhNative+GUITHREADINFO
            $gui.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][DvhNative+GUITHREADINFO])
            if ([DvhNative]::GetGUIThreadInfo($threadId, [ref]$gui) -and $gui.hwndFocus -ne [IntPtr]::Zero) {
                $focusByHwnd = [System.Windows.Automation.AutomationElement]::FromHandle($gui.hwndFocus)
                if (Test-TextElement $focusByHwnd) {
                    $script:focusElement = $focusByHwnd
                    $script:beforeText = Get-ElementText $focusByHwnd
                }
            }
            $script:uiaSnapshot = Get-UiaTextSnapshot
            $className = New-Object System.Text.StringBuilder 256
            [DvhNative]::GetClassName($foreground, $className, 256) | Out-Null
            Write-Log ("foreground=0x{0:X} class={1} snapshot={2}" -f [int64]$foreground, $className.ToString(), @($script:uiaSnapshot).Count)
            $script:clipboardMode = $false
            $script:clipboardBefore = $null
            $script:tapText = ''
            $script:lastTapText = ''
            $script:lastTapAt = [datetime]::MinValue
            if ($null -eq $script:beforeText -and $className.ToString() -match 'mmui::MainWindow') {
                $script:clipboardMode = $true
                $script:clipboardBefore = Copy-FocusedTextViaClipboard
                Write-Log ("clipboard fallback before_len={0}" -f $(if ($null -eq $script:clipboardBefore) { -1 } else { $script:clipboardBefore.Length }))
            }
            Write-Log ("voice start; before_len={0}" -f $(if ($null -eq $script:beforeText) { -1 } else { $script:beforeText.Length }))
            if ($script:lastTargetPid -gt 0) {
                Write-Log ("target pid={0} name={1}" -f $script:lastTargetPid, $script:lastTargetName)
                Inject-VoiceHook $script:lastTargetPid
            }
        }
        catch { $script:focusElement = $null; $script:beforeText = $null }
    }
    elseif (-not $visible -and $script:voiceVisible)
    {
        $script:voiceVisible = $false
        $script:pendingStage = 0
        $script:pendingUntil = (Get-Date).AddMilliseconds(350)
        Show-Overlay -Pending
    }
    if ($null -ne $script:pendingUntil -and (Get-Date) -ge $script:pendingUntil)
    {
        $script:pendingUntil = $null
        try
        {
            $inserted = ''
            $bestFocused = $false
            $bestLength = -1
            foreach ($item in @($script:uiaSnapshot | Where-Object { $_ -and $_.Element }))
            {
                $nowText = Get-ElementText $item.Element
                $diff = Get-InsertedText $item.Text $nowText
                if ([string]::IsNullOrWhiteSpace($diff) -or $diff.Length -gt 1000) { continue }
                $isFocused = $false
                try { $isFocused = [bool]$item.Element.Current.HasKeyboardFocus } catch { }
                if (($isFocused -and -not $bestFocused) -or
                    ($isFocused -eq $bestFocused -and $diff.Length -gt $bestLength))
                {
                    $inserted = $diff
                    $bestFocused = $isFocused
                    $bestLength = $diff.Length
                }
            }
            if ([string]::IsNullOrWhiteSpace($inserted))
            {
                $afterText = Get-ElementText $script:focusElement
                if ($null -eq $afterText)
                {
                    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
                    $afterText = Get-ElementText (Find-TextAncestor $focused)
                }
                $inserted = Get-InsertedText $script:beforeText $afterText
            }
            if (-not (Test-VoiceText $inserted)) { $inserted = '' }
            Write-Log ("voice commit snapshot_candidates={0} inserted_len={1}" -f @($script:uiaSnapshot).Count, $inserted.Length)
            if ([string]::IsNullOrWhiteSpace($inserted) -and $script:clipboardMode -and (Get-ForegroundWindowClass) -match 'mmui::MainWindow') {
                $afterClipboard = Copy-FocusedTextViaClipboard
                $inserted = Get-InsertedText $script:clipboardBefore $afterClipboard
                Write-Log ("clipboard fallback after_len={0} inserted_len={1}" -f $(if ($null -eq $afterClipboard) { -1 } else { $afterClipboard.Length }), $inserted.Length)
            }
            $elementName = ''
            try { $elementName = $script:focusElement.Current.Name } catch { }
            if (-not [string]::IsNullOrWhiteSpace($inserted) -and
                ($inserted -eq $elementName -or $inserted.Length -gt 1000)) { $inserted = '' }
            if (-not [string]::IsNullOrWhiteSpace($inserted))
            {
                Add-HistoryEntry $inserted | Out-Null
                Show-Overlay $inserted
                if ($historyWindow.IsVisible) { Refresh-HistoryView }
            }
            elseif ($script:pendingStage -lt 3)
            {
                $script:pendingStage++
                $script:pendingUntil = (Get-Date).AddMilliseconds($(if ($script:pendingStage -eq 1) { 600 } else { 1200 }))
            }
            else {
                if (Test-VoiceText $script:tapText) {
                    Set-ClipboardText $script:tapText
                    Show-Overlay $script:tapText
                    $statusText.Text = '输入法未插入，已复制到剪贴板'
                    Write-Log 'IME_DROPPED rescued from tap'
                } else { Show-Overlay '' }
            }
        }
        catch { Show-Overlay '' }
        if ($null -eq $script:pendingUntil) {
            $script:beforeText = $null
            $script:focusElement = $null
            $script:uiaSnapshot = @()
            $script:clipboardMode = $false
            $script:clipboardBefore = $null
        }
    }
})

$script:voiceVisible = $false
$script:pendingUntil = $null
$script:pendingStage = 0
$script:uiaSnapshot = @()
$script:clipboardMode = $false
$script:clipboardBefore = $null
$script:tapOffset = 0
try {
    $tapStartPath = Join-Path $dataDir 'voice-tap.log'
    if (Test-Path -LiteralPath $tapStartPath) {
        $script:tapOffset = (Get-Item -LiteralPath $tapStartPath).Length
        Write-Log ("voice tap start offset={0}" -f $script:tapOffset)
    }
} catch { }
$script:tapText = ''
$script:lastTapText = ''
$script:lastTapAt = [datetime]::MinValue
$script:tapReadAt = [datetime]::MinValue
$script:lastTargetPid = 0
$script:lastTargetName = ''
$script:targetCheckAt = [datetime]::MinValue

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-MicIcon
$tray.Text = '豆包语音历史'
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menuShow = $menu.Items.Add('显示上次结果')
$menuHistory = $menu.Items.Add('历史记录')
$menuFolder = $menu.Items.Add('打开数据目录')
$menuDoctor = $menu.Items.Add('诊断与修复')
$menuUpdate = $menu.Items.Add('检查更新')
$menuExit = $menu.Items.Add('退出')
$tray.ContextMenuStrip = $menu
$menuShow.Add_Click({ if ($script:history.Count -gt 0) { Show-Overlay $script:history[0].text } })
$menuHistory.Add_Click({ Show-History })
$menuFolder.Add_Click({ Start-Process explorer.exe -ArgumentList $dataDir })
$menuDoctor.Add_Click({
    $doctor = Join-Path (Split-Path $PSCommandPath -Parent) 'Doctor.ps1'
    if (Test-Path $doctor) {
        Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$doctor,'-Fix'
    }
})
$menuUpdate.Add_Click({
    Show-History
    Start-UpdateCheck
})
$menuExit.Add_Click({ $tray.Visible = $false; $app.Shutdown() })
$tray.Add_DoubleClick({ Show-History })

Write-Log 'app start'
$script:pollTimer.Start()
$script:updateTimer.Start()

if ($Test)
{
    $now = Get-Date
    $script:history = @(
        [pscustomobject]@{ time = $now.AddMinutes(-2).ToString('yyyy-MM-dd HH:mm:ss'); text = '这是一条测试识别结果：今天下午三点开会，记得带上项目进度表和预算表。'; count = 2 },
        [pscustomobject]@{ time = $now.AddHours(-2).ToString('yyyy-MM-dd HH:mm:ss'); text = '把刚才那份报价单发给王工，顺便确认一下下周一能不能到场。'; count = 1 },
        [pscustomobject]@{ time = $now.AddDays(-1).ToString('yyyy-MM-dd HH:mm:ss'); text = '晚上七点之前把周报补完，重点写清楚这周的性能优化和遗留问题。'; count = 1 }
    )
    $startTimer = New-Object System.Windows.Threading.DispatcherTimer
    $startTimer.Interval = [TimeSpan]::FromMilliseconds(700)
    $startTimer.Add_Tick({ $startTimer.Stop(); Show-Overlay $script:history[0].text })
    $startTimer.Start()
    $historyTimer = New-Object System.Windows.Threading.DispatcherTimer
    $historyTimer.Interval = [TimeSpan]::FromSeconds(6)
    $historyTimer.Add_Tick({ $historyTimer.Stop(); Show-History })
    $historyTimer.Start()
    $testTimer = New-Object System.Windows.Threading.DispatcherTimer
    $testTimer.Interval = [TimeSpan]::FromSeconds(14)
    $testTimer.Add_Tick({ $testTimer.Stop(); $tray.Visible = $false; $app.Shutdown() })
    $testTimer.Start()
}

[void]$app.Run()
