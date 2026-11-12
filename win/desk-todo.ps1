param(
  [Parameter(Mandatory = $true)][string]$DataPath,
  [int]$ApiPort = 0,
  [double]$Opacity = 0.85,
  [int]$WinWidth = 520,
  [int]$WinHeight = 330,
  [int]$Top = 16,
  [int]$Right = 16,
  [string]$Topmost = 'false',
  [string]$Silent = 'false'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:DataPath = $DataPath
$script:ApiPort = $ApiPort
$script:Silent = ($Silent -eq 'true')
$script:Data = $null
$script:FiredKeys = @{}
$script:DragSaving = $false

function Read-Data {
  try {
    $raw = Get-Content -LiteralPath $script:DataPath -Raw -Encoding UTF8
    if (-not $raw) { return $null }
    return $raw | ConvertFrom-Json
  } catch { return $null }
}

function Write-Data($d) {
  try {
    $json = $d | ConvertTo-Json -Depth 12
    $dir = Split-Path -Parent $script:DataPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($script:DataPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:Data = $d
  } catch { }
}

function Pad2([int]$n) { return $n.ToString('00') }
function DayKey([datetime]$d) { return "$($d.Year)-$(Pad2 $d.Month)-$(Pad2 $d.Day)" }
function Mins([string]$t) {
  if (-not $t) { return 0 }
  $p = $t.Split(':')
  return ([int]$p[0]) * 60 + [int]$p[1]
}

function Abbrev([string]$place) {
  if (-not $place) { return '' }
  $s = $place -replace '^武进', ''
  $s = $s -replace '东区国际教室', '东区'
  $s = $s -replace '教学主楼', '主楼'
  $s = $s -replace '教学辅楼', '辅楼'
  $s = $s -replace '阶教楼', ''
  return $s.Trim()
}

function Brush([string]$hex) {
  return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)))
}

$colorMap = @{ gold = '#FFD166'; green = '#7EE0A8'; blue = '#7FB2FF'; pink = '#FF9EC7'; orange = '#FFB27F' }

# ───────────── 界面 ─────────────
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" Topmost="$Topmost"
        Width="$WinWidth" Height="$WinHeight" FontFamily="Microsoft YaHei">
  <Window.Resources>
    <Style TargetType="{x:Type ScrollBar}">
      <Setter Property="Width" Value="6"/>
      <Setter Property="Background" Value="#00000000"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ScrollBar}">
            <Grid Background="#00000000">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border CornerRadius="3" Background="#33FFFFFF" Margin="1,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="Root" CornerRadius="12" BorderThickness="1" BorderBrush="#2AFFFFFF">
    <Border.Background>
      <SolidColorBrush Color="#0A111D" Opacity="$Opacity" />
    </Border.Background>
    <DockPanel>
      <Border x:Name="Header" DockPanel.Dock="Top" Background="#14FFFFFF" CornerRadius="12,12,0,0" Padding="8,5">
        <Grid>
          <TextBlock x:Name="Title" Foreground="#EAF1FF" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnAdd" Content="＋" Width="24" Height="20" FontSize="12" Margin="0,0,4,0"
                    Background="#22FFFFFF" Foreground="#EAF1FF" BorderThickness="0" ToolTip="新增待办"/>
            <Button x:Name="BtnClose" Content="－" Width="24" Height="20" FontSize="12"
                    Background="#22FFFFFF" Foreground="#EAF1FF" BorderThickness="0" ToolTip="隐藏"/>
          </StackPanel>
        </Grid>
      </Border>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="1.7*"/>
          <ColumnDefinition Width="1"/>
          <ColumnDefinition Width="1*"/>
        </Grid.ColumnDefinitions>
        <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" Padding="4,2,2,4">
          <StackPanel x:Name="WeekPanel"/>
        </ScrollViewer>
        <Rectangle Grid.Column="1" Fill="#26FFFFFF"/>
        <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto" Padding="4,2,2,4">
          <StackPanel x:Name="LongPanel"/>
        </ScrollViewer>
      </Grid>
    </DockPanel>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in 'Root','Header','Title','BtnAdd','BtnClose','WeekPanel','LongPanel') {
  Set-Variable -Name $n -Value $win.FindName($n) -Scope Script
}

# 位置
$wa = [System.Windows.SystemParameters]::WorkArea
$d0 = Read-Data
$sx = $null; $sy = $null
if ($d0 -and $d0.settings) {
  if ($d0.settings.PSObject.Properties.Name -contains 'w' -and $d0.settings.w) { $win.Width = [double]$d0.settings.w }
  if ($d0.settings.PSObject.Properties.Name -contains 'h' -and $d0.settings.h) { $win.Height = [double]$d0.settings.h }
  if ($d0.settings.PSObject.Properties.Name -contains 'opacity' -and $d0.settings.opacity) {
    $Root.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb([byte](255*[double]$d0.settings.opacity), 10, 17, 29))
  }
  if (($d0.settings.PSObject.Properties.Name -contains 'x') -and $d0.settings.x -ne $null) { $sx = [double]$d0.settings.x }
  if (($d0.settings.PSObject.Properties.Name -contains 'y') -and $d0.settings.y -ne $null) { $sy = [double]$d0.settings.y }
}
if ($sx -ne $null) { $win.Left = $sx } else { $win.Left = $wa.Right - $win.Width - $Right }
if ($sy -ne $null) { $win.Top = $sy } else { $win.Top = $wa.Top + $Top }

# ───────────── 渲染 ─────────────
$wd = @('周日','周一','周二','周三','周四','周五','周六')

function New-TextBlock([string]$text, [double]$size, [string]$color, [string]$weight = 'Normal') {
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $text
  $tb.FontSize = $size
  $tb.Foreground = Brush $color
  if ($weight -eq 'Bold') { $tb.FontWeight = [System.Windows.FontWeights]::Bold }
  $tb.TextTrimming = 'CharacterEllipsis'
  return $tb
}

function Add-Item($panel, $ev, [string]$kind, [string]$dateKey, [bool]$past, [bool]$isLong = $false) {
  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = New-Object System.Windows.CornerRadius 7
  $border.Background = Brush '#14FFFFFF'
  $border.Margin = New-Object System.Windows.Thickness 0,0,0,3
  $border.Padding = New-Object System.Windows.Thickness 6,3,6,3
  $border.Cursor = [System.Windows.Input.Cursors]::Hand
  if ($past) { $border.Opacity = 0.45 }

  $grid = New-Object System.Windows.Controls.Grid
  $col0 = New-Object System.Windows.Controls.ColumnDefinition
  $col0.Width = New-Object System.Windows.GridLength 3
  $col1 = New-Object System.Windows.Controls.ColumnDefinition
  $grid.ColumnDefinitions.Add($col0)
  $grid.ColumnDefinitions.Add($col1)

  $bar = New-Object System.Windows.Shapes.Rectangle
  $bar.Width = 3
  $bar.RadiusX = 1.5; $bar.RadiusY = 1.5
  $cname = $ev.color; if (-not $cname) { $cname = 'blue' }
  if ($colorMap.ContainsKey($cname)) { $bar.Fill = Brush $colorMap[$cname] } else { $bar.Fill = Brush '#7FB2FF' }
  [System.Windows.Controls.Grid]::SetColumn($bar, 0)
  $grid.Children.Add($bar) | Out-Null

  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Margin = New-Object System.Windows.Thickness 6,0,0,0
  [System.Windows.Controls.Grid]::SetColumn($sp, 1)
  if ($isLong) {
    $line = New-Object System.Windows.Controls.StackPanel
    $line.Orientation = 'Horizontal'
    $t1 = New-TextBlock $ev.title 12.5 '#EAF1FF'
    $t1.Width = 150
    $line.Children.Add($t1) | Out-Null
    $dueTxt = ''; $dueColor = '#AFC4E6'
    if ($ev.due) {
      $dd = [datetime]::Parse($ev.due)
      $left = [math]::Ceiling(($dd - (Get-Date).Date).TotalDays)
      if ($left -lt 0) { $dueTxt = "$(-$left)天前"; $dueColor = '#FF8A8A' }
      elseif ($left -eq 0) { $dueTxt = '今天'; $dueColor = '#FF8A8A' }
      else { $dueTxt = "$left 天"; if ($left -le 3) { $dueColor = '#FF8A8A' } elseif ($left -le 10) { $dueColor = '#FFCC66' } }
    }
    $t2 = New-TextBlock $dueTxt 11 $dueColor
    $t2.HorizontalAlignment = 'Right'
    $line.Children.Add($t2) | Out-Null
    $sp.Children.Add($line) | Out-Null
    $grid.Children.Add($sp) | Out-Null
    $panel.Children.Add($border) | Out-Null
    $border.Child = $grid
    $border.Add_MouseLeftButtonUp({ param($s, $e) Show-Detail $ev 'long' '' })
    return
  }

  $line = New-Object System.Windows.Controls.StackPanel
  $line.Orientation = 'Horizontal'
  $tTime = New-TextBlock ([string]$ev.start) 12 '#EAF1FF' 'Bold'
  $tTime.Width = 44
  $line.Children.Add($tTime) | Out-Null
  $tTitle = New-TextBlock ([string]$ev.title) 12.5 '#EAF1FF'
  $line.Children.Add($tTitle) | Out-Null
  $sp.Children.Add($line) | Out-Null

  $sub = @()
  $pl = Abbrev ([string]$ev.place)
  if ($pl) { $sub += $pl }
  if ($sub.Count -gt 0) {
    $tSub = New-TextBlock ($sub -join ' · ') 10.5 '#9FB4D6'
    $sp.Children.Add($tSub) | Out-Null
  }
  $grid.Children.Add($sp) | Out-Null
  $border.Child = $grid
  $panel.Children.Add($border) | Out-Null
  $border.Add_MouseLeftButtonUp({ param($s, $e) Show-Detail $ev 'event' $dateKey })
}

function Render {
  $script:Data = Read-Data
  if (-not $script:Data) { return }
  $now = Get-Date
  $nowMin = $now.Hour * 60 + $now.Minute
  $wkStart = $now.Date.AddDays(- ((([int]$now.DayOfWeek) + 6) % 7))
  $wkEnd = $wkStart.AddDays(6)
  $wkNo = ''
  if ($script:Data.semester -and $script:Data.semester.week1Monday) {
    try {
      $w1 = [datetime]::Parse([string]$script:Data.semester.week1Monday)
      $n = [math]::Floor((($wkStart - $w1.Date).TotalDays / 7)) + 1
      if ($n -gt 0) { $wkNo = "第${n}周 · " }
    } catch { }
  }
  $Title.Text = $wkNo + "$($wkStart.Month)/$($wkStart.Day)–$($wkEnd.Month)/$($wkEnd.Day)"
  $WeekPanel.Children.Clear()
  $LongPanel.Children.Clear()

  for ($i = 0; $i -lt 7; $i++) {
    $day = $now.Date.AddDays($i)
    $dk = DayKey $day
    $events = @()
    foreach ($ev in $script:Data.events) {
      $evDay = [datetime]::Parse($ev.day)
      $hit = $false
      if ((DayKey $evDay) -eq $dk) { $hit = $true }
      elseif ($ev.repeat -eq 'weekly' -and $evDay.DayOfWeek -eq $day.DayOfWeek -and $day -ge $evDay) { $hit = $true }
      if ($hit -and $ev.doneOn -eq $dk) { $hit = $false }
      if ($hit) { $events += $ev }
    }
    $events = $events | Sort-Object { Mins ([string]$_.start) }

    $head = if ($i -eq 0) { '今天' } elseif ($i -eq 1) { '明天' } else { $wd[[int]$day.DayOfWeek] }
    $hl = New-TextBlock ("$head · $($day.Month)/$($day.Day)") 10.5 ($(if ($i -eq 0) { '#64D2FF' } else { '#8FA6C8' })) ($(if ($i -eq 0) { 'Bold' } else { 'Normal' }))
    $hl.Margin = New-Object System.Windows.Thickness 2,5,0,2
    $WeekPanel.Children.Add($hl) | Out-Null

    if ($events.Count -eq 0) {
      $empty = New-TextBlock '——' 10 '#44597A'
      $empty.Margin = New-Object System.Windows.Thickness 6,0,0,2
      $WeekPanel.Children.Add($empty) | Out-Null
      continue
    }
    foreach ($ev in $events) {
      $past = ($i -eq 0) -and ((Mins ([string]$ev.end)) -lt $nowMin)
      Add-Item $WeekPanel $ev 'event' $dk $past
    }
  }

  $longs = @()
  if ($script:Data.longterm) { $longs = $script:Data.longterm | Sort-Object { if ($_.due) { $_.due } else { '9999-99-99' } } }
  if ($longs.Count -eq 0) {
    $WeekPanel.Dispatcher.Invoke([action]{}) | Out-Null
    $empty = New-TextBlock '暂无' 10 '#44597A'
    $LongPanel.Children.Add($empty) | Out-Null
  } else {
    foreach ($it in $longs) { Add-Item $LongPanel $it 'long' '' $false $true }
  }
}

# ───────────── 详情 / 编辑 ─────────────
function Show-Detail($ev, [string]$kind, [string]$dateKey) {
  $w = New-Object System.Windows.Window
  $w.WindowStyle = 'None'; $w.AllowsTransparency = $true; $w.Background = 'Transparent'
  $w.ShowInTaskbar = $false; $w.Topmost = ($Topmost -eq 'true')
  $w.Width = 380; $w.Height = 300
  $w.WindowStartupLocation = 'CenterOwner'
  $w.Owner = $win

  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = New-Object System.Windows.CornerRadius 10
  $b.Background = Brush '#F0142136'
  $b.BorderBrush = Brush '#5964D2FF'
  $b.BorderThickness = New-Object System.Windows.Thickness 1
  $b.Padding = New-Object System.Windows.Thickness 12

  $sp = New-Object System.Windows.Controls.StackPanel
  $t = New-TextBlock ([string]$ev.title) 14 '#EAF1FF' 'Bold'
  $sp.Children.Add($t) | Out-Null

  $meta = ''
  if ($kind -eq 'event') { $meta = "$($ev.start) – $($ev.end)" }
  else { if ($ev.due) { $meta = "DDL：$($ev.due)" } else { $meta = '没有明确 DDL' } }
  $tm = New-TextBlock $meta 11 '#9FB4D6'
  $tm.Margin = New-Object System.Windows.Thickness 0,4,0,0
  $sp.Children.Add($tm) | Out-Null

  if ($ev.place) {
    $tp = New-TextBlock ("地点：" + (Abbrev ([string]$ev.place))) 11 '#9FB4D6'
    $sp.Children.Add($tp) | Out-Null
  }

  $lb = New-TextBlock '我的备注' 10.5 '#7F93B3'
  $lb.Margin = New-Object System.Windows.Thickness 0,8,0,3
  $sp.Children.Add($lb) | Out-Null

  $note = New-Object System.Windows.Controls.TextBox
  $note.Text = [string]$ev.note
  $note.Height = 90
  $note.AcceptsReturn = $true
  $note.TextWrapping = 'Wrap'
  $note.Background = Brush '#22FFFFFF'
  $note.Foreground = Brush '#EAF1FF'
  $note.BorderThickness = New-Object System.Windows.Thickness 0
  $note.Padding = New-Object System.Windows.Thickness 6
  $note.FontSize = 12
  $sp.Children.Add($note) | Out-Null

  $btns = New-Object System.Windows.Controls.StackPanel
  $btns.Orientation = 'Horizontal'
  $btns.Margin = New-Object System.Windows.Thickness 0,10,0,0

  function New-Btn([string]$text, [scriptblock]$onClick) {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = $text
    $btn.Padding = New-Object System.Windows.Thickness 10,3,10,3
    $btn.Margin = New-Object System.Windows.Thickness 0,0,6,0
    $btn.Background = Brush '#3364D2FF'
    $btn.Foreground = Brush '#EAF1FF'
    $btn.BorderThickness = New-Object System.Windows.Thickness 0
    $btn.FontSize = 11.5
    $btn.Add_Click($onClick)
    return $btn
  }

  $btnSave = New-Btn '保存备注' {
    $d = Read-Data
    $target = if ($kind -eq 'event') { $d.events | Where-Object { $_.id -eq $ev.id } } else { $d.longterm | Where-Object { $_.id -eq $ev.id } }
    if ($target) { $target.note = $note.Text; Write-Data $d; Render }
    $w.Close()
  }
  $btns.Children.Add($btnSave) | Out-Null

  $btnDone = New-Btn ($(if ($kind -eq 'event') { if ($ev.doneOn -eq $dateKey) { '取消完成' } else { '今天完成' } } else { if ($ev.done) { '取消完成' } else { '完成' } })) {
    $d = Read-Data
    if ($kind -eq 'event') {
      $target = $d.events | Where-Object { $_.id -eq $ev.id }
      if ($target) {
        if ($dateKey -and $target.doneOn -eq $dateKey) { $target.PSObject.Properties.Remove('doneOn') } else { $target | Add-Member -NotePropertyName doneOn -NotePropertyValue $dateKey -Force }
      }
    } else {
      $target = $d.longterm | Where-Object { $_.id -eq $ev.id }
      if ($target) { $target.done = -not $target.done }
    }
    Write-Data $d; Render; $w.Close()
  }
  $btns.Children.Add($btnDone) | Out-Null

  $btnDel = New-Btn '删除' {
    $d = Read-Data
    if ($kind -eq 'event') { $d.events = @($d.events | Where-Object { $_.id -ne $ev.id }) }
    else { $d.longterm = @($d.longterm | Where-Object { $_.id -ne $ev.id }) }
    Write-Data $d; Render; $w.Close()
  }
  $btns.Children.Add($btnDel) | Out-Null

  $btnClose = New-Btn '关闭' { $w.Close() }
  $btns.Children.Add($btnClose) | Out-Null

  $sp.Children.Add($btns) | Out-Null
  $b.Child = $sp
  $w.Content = $b
  $w.Add_MouseLeftButtonDown({ try { (Get-Process -Id $PID).Refresh(); } catch {} })
  $w.ShowDialog() | Out-Null
}

function Show-QuickAdd {
  $w = New-Object System.Windows.Window
  $w.WindowStyle = 'None'; $w.AllowsTransparency = $true; $w.Background = 'Transparent'
  $w.ShowInTaskbar = $false; $w.Topmost = $true
  $w.Width = 420; $w.Height = 190
  $w.WindowStartupLocation = 'CenterOwner'; $w.Owner = $win

  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = New-Object System.Windows.CornerRadius 10
  $b.Background = Brush '#F0142136'
  $b.BorderBrush = Brush '#5964D2FF'
  $b.BorderThickness = New-Object System.Windows.Thickness 1
  $b.Padding = New-Object System.Windows.Thickness 12
  $sp = New-Object System.Windows.Controls.StackPanel

  $t = New-TextBlock '新增待办 —— 直接写一句人话' 12 '#EAF1FF' 'Bold'
  $sp.Children.Add($t) | Out-Null
  $hint = New-TextBlock '例：15号下午3点在图书馆交作业 / 明天9点到11点 东区414 数值分析' 10 '#7F93B3'
  $hint.Margin = New-Object System.Windows.Thickness 0,3,0,6
  $sp.Children.Add($hint) | Out-Null

  $tb = New-Object System.Windows.Controls.TextBox
  $tb.Height = 34; $tb.FontSize = 13
  $tb.Background = Brush '#22FFFFFF'; $tb.Foreground = Brush '#EAF1FF'; $tb.BorderThickness = 0
  $tb.Padding = New-Object System.Windows.Thickness 6
  $sp.Children.Add($tb) | Out-Null

  $err = New-TextBlock '' 10.5 '#FF9E9E'
  $err.Margin = New-Object System.Windows.Thickness 0,4,0,0
  $sp.Children.Add($err) | Out-Null

  $btns = New-Object System.Windows.Controls.StackPanel
  $btns.Orientation = 'Horizontal'; $btns.Margin = New-Object System.Windows.Thickness 0,8,0,0
  $ok = New-Object System.Windows.Controls.Button
  $ok.Content = '识别并添加'; $ok.Padding = New-Object System.Windows.Thickness 10,4,10,4
  $ok.Background = Brush '#3364D2FF'; $ok.Foreground = Brush '#EAF1FF'; $ok.BorderThickness = 0; $ok.FontSize = 12
  $btns.Children.Add($ok) | Out-Null
  $cancel = New-Object System.Windows.Controls.Button
  $cancel.Content = '取消'; $cancel.Padding = New-Object System.Windows.Thickness 10,4,10,4
  $cancel.Margin = New-Object System.Windows.Thickness 6,0,0,0
  $cancel.Background = Brush '#22FFFFFF'; $cancel.Foreground = Brush '#EAF1FF'; $cancel.BorderThickness = 0; $cancel.FontSize = 12
  $btns.Children.Add($cancel) | Out-Null
  $sp.Children.Add($btns) | Out-Null
  $b.Child = $sp; $w.Content = $b

  $cancel.Add_Click({ $w.Close() })
  $ok.Add_Click({
    $text = $tb.Text.Trim()
    if (-not $text) { $err.Text = '先写点什么'; return }
    $parsed = $null
    if ($script:ApiPort -gt 0) {
      try {
        $body = @{ text = $text } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$($script:ApiPort)/parse" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 3
        $parsed = $resp
      } catch { }
    }
    $d = Read-Data
    $id = 'e' + [int64]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds
    $item = [pscustomobject]@{ id = $id; title = $text; day = (DayKey (Get-Date)); start = '09:00'; end = '10:00'; place = ''; color = 'blue'; remindMin = 15; repeat = 'none'; note = '' }
    if ($parsed -and $parsed.ok) {
      if ($parsed.title) { $item.title = [string]$parsed.title }
      if ($parsed.date) { $item.day = [string]$parsed.date }
      if ($parsed.start) { $item.start = [string]$parsed.start }
      if ($parsed.end) { $item.end = [string]$parsed.end }
      if ($parsed.place) { $item.place = [string]$parsed.place }
    } else {
      $err.Text = '识别服务不可用，已按「今天 09:00」添加，之后可右键编辑'
    }
    $d.events = @($d.events) + $item
    Write-Data $d
    Render
    $w.Close()
  })
  $w.ShowDialog() | Out-Null
}

# ───────────── 提醒 ─────────────
function Play-Chime([bool]$urgent) {
  if ($script:Silent) { return }
  try {
    $sp = New-Object System.Media.SoundPlayer ((Join-Path $PSScriptRoot '..\assets\chime.wav'))
    $sp.Load(); $sp.Play()
  } catch { }
}

function Show-Toast([string]$title, [string]$body, [bool]$urgent) {
  $w = New-Object System.Windows.Window
  $w.WindowStyle = 'None'; $w.AllowsTransparency = $true; $w.Background = 'Transparent'
  $w.ShowInTaskbar = $false; $w.Topmost = $true
  $w.Width = 380; $w.Height = 92
  $wa = [System.Windows.SystemParameters]::WorkArea
  $w.Left = $wa.Right - 380 - 16
  $w.Top = $wa.Bottom - 92 - 72
  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = New-Object System.Windows.CornerRadius 10
  $b.Background = Brush '#F00E1626'
  $b.BorderBrush = Brush ($(if ($urgent) { '#CCFF9878' } else { '#8064D2FF' }))
  $b.BorderThickness = New-Object System.Windows.Thickness 1
  $b.Padding = New-Object System.Windows.Thickness 12,8,12,8
  $sp = New-Object System.Windows.Controls.StackPanel
  $t = New-TextBlock $title 13 '#EAF1FF' 'Bold'
  $sp.Children.Add($t) | Out-Null
  $bd = New-TextBlock $body 11 '#9FB4D6'
  $sp.Children.Add($bd) | Out-Null
  $b.Child = $sp
  $w.Content = $b
  $w.Show()
  Play-Chime $urgent
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromSeconds($(if ($urgent) { 12 } else { 8 }))
  $timer.Add_Tick({ $timer.Stop(); $w.Close() })
  $timer.Start()
}

function Check-Reminders {
  $d = Read-Data
  if (-not $d) { return }
  $now = Get-Date
  $nowMin = $now.Hour * 60 + $now.Minute
  $today = DayKey $now
  foreach ($ev in $d.events) {
    $evDay = [datetime]::Parse($ev.day)
    $occurs = ((DayKey $evDay) -eq $today) -or ($ev.repeat -eq 'weekly' -and $evDay.DayOfWeek -eq $now.DayOfWeek -and $now.Date -ge $evDay)
    if (-not $occurs) { continue }
    if ($ev.doneOn -eq $today) { continue }
    $startMin = Mins ([string]$ev.start)
    $remind = if ($null -ne $ev.remindMin) { [int]$ev.remindMin } else { 15 }
    $diff = $startMin - $nowMin
    if ($remind -gt 0 -and $diff -le $remind -and $diff -gt ($remind - 2)) {
      $k = "$($ev.id)|$today|pre"
      if (-not $script:FiredKeys.ContainsKey($k)) {
        $script:FiredKeys[$k] = 1
        $body = "$remind 分钟后" + $(if ($ev.place) { " · $($ev.place)" } else { '' })
        Show-Toast "马上要开始 · $($ev.title)" $body $false
      }
    }
    if ($diff -le 0 -and $diff -gt -2) {
      $k = "$($ev.id)|$today|now"
      if (-not $script:FiredKeys.ContainsKey($k)) {
        $script:FiredKeys[$k] = 1
        Show-Toast "开始了 · $($ev.title)" ([string]$ev.place) $true
      }
    }
    if ($diff -lt -2 -and $diff -gt -90) {
      $stage = [math]::Floor((-$diff) / 10)
      if ($stage -ge 1 -and $stage -le 3) {
        $k = "$($ev.id)|$today|late$stage"
        if (-not $script:FiredKeys.ContainsKey($k)) {
          $script:FiredKeys[$k] = 1
          Show-Toast "还没完成 · $($ev.title)" "已经过去 $(-$diff) 分钟" $true
        }
      }
    }
  }
  foreach ($it in $d.longterm) {
    if ($it.done -or -not $it.due) { continue }
    $due = [datetime]::Parse($it.due)
    $days = [math]::Ceiling(($due - $now.Date).TotalDays)
    if ($days -eq 3 -or $days -eq 1 -or $days -eq 0) {
      $k = "$($it.id)|ddl|$days"
      if (-not $script:FiredKeys.ContainsKey($k)) {
        $script:FiredKeys[$k] = 1
        $body = if ($days -eq 0) { '今天到期' } else { "$days 天后到期（$($it.due)）" }
        Show-Toast "临期 · $($it.title)" $body $true
      }
    }
  }
}

# ───────────── 交互 ─────────────
$Header.Add_MouseLeftButtonDown({
  try { $win.DragMove() } catch { }
})
$script:LocTimer = $null
$win.Add_LocationChanged({
  try {
    if ($null -eq $win) { return }
    if ($script:LocTimer) { $script:LocTimer.Stop() }
    $script:LocTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:LocTimer.Interval = [TimeSpan]::FromMilliseconds(700)
    $script:LocTimer.Add_Tick({
      try { $script:LocTimer.Stop() } catch { }
      try {
        $d = Read-Data
        if ($d) {
          if (-not $d.settings) { $d | Add-Member -NotePropertyName settings -NotePropertyValue ([pscustomobject]@{}) -Force }
          $d.settings | Add-Member -NotePropertyName x -NotePropertyValue ([double]$win.Left) -Force
          $d.settings | Add-Member -NotePropertyName y -NotePropertyValue ([double]$win.Top) -Force
          $d.settings | Add-Member -NotePropertyName w -NotePropertyValue ([double]$win.Width) -Force
          $d.settings | Add-Member -NotePropertyName h -NotePropertyValue ([double]$win.Height) -Force
          Write-Data $d
        }
      } catch { }
    })
    $script:LocTimer.Start()
  } catch { }
})
$BtnAdd.Add_Click({ Show-QuickAdd })
$BtnClose.Add_Click({ $win.Hide() })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(20)
$timer.Add_Tick({ Check-Reminders })
$timer.Start()

$fsTimer = New-Object System.Windows.Threading.DispatcherTimer
$fsTimer.Interval = [TimeSpan]::FromSeconds(3)
$fsTimer.Add_Tick({
  try {
    $fi = Get-Item -LiteralPath $script:DataPath -ErrorAction SilentlyContinue
    if ($fi -and $script:LastWrite -ne $fi.LastWriteTimeUtc.Ticks) {
      $script:LastWrite = $fi.LastWriteTimeUtc.Ticks
      Render
    }
  } catch { }
})
$fsTimer.Start()

Render
$script:LastWrite = (Get-Item -LiteralPath $script:DataPath).LastWriteTimeUtc.Ticks
[void]$win.ShowDialog()
