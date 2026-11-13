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


function Log-Ui([string]$msg) {
  try {
    $p = Join-Path $env:TEMP 'desk-todo-ui.log'
    Add-Content -LiteralPath $p -Value ((Get-Date).ToString('HH:mm:ss') + ' ' + $msg) -Encoding UTF8
  } catch { }
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
    <Border.Effect>
      <DropShadowEffect BlurRadius="16" ShadowDepth="0" Opacity="0.55" Color="#000000"/>
    </Border.Effect>
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
            <Button x:Name="BtnCfg" Content="⚙" Width="24" Height="20" FontSize="12" Margin="0,0,4,0"
                    Background="#22FFFFFF" Foreground="#EAF1FF" BorderThickness="0" ToolTip="设置"/>
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
        <ScrollViewer x:Name="WeekScroll" Grid.Column="0" VerticalScrollBarVisibility="Auto" Padding="4,2,2,4">
          <StackPanel x:Name="WeekPanel"/>
        </ScrollViewer>
        <Rectangle Grid.Column="1" Fill="#26FFFFFF"/>
        <ScrollViewer x:Name="LongScroll" Grid.Column="2" VerticalScrollBarVisibility="Auto" Padding="4,2,2,4">
          <StackPanel x:Name="LongPanel"/>
        </ScrollViewer>
      </Grid>
    </DockPanel>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in 'Root','Header','Title','BtnAdd','BtnClose','BtnCfg','WeekPanel','LongPanel','WeekScroll','LongScroll') {
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
  $border.Margin = New-Object System.Windows.Thickness 0,0,0,4
  $border.Padding = New-Object System.Windows.Thickness 7,4,7,4
  $border.Cursor = [System.Windows.Input.Cursors]::Hand
  $border.Add_MouseEnter({ param($s, $e) try { $s.Background = Brush '#2EFFFFFF' } catch { } })
  $border.Add_MouseLeave({ param($s, $e) try { $s.Background = Brush '#14FFFFFF' } catch { } })
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
    $t1 = New-TextBlock $ev.title 13 '#EAF1FF'
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
    $t2 = New-TextBlock $dueTxt 11.5 $dueColor
    $t2.HorizontalAlignment = 'Right'
    $line.Children.Add($t2) | Out-Null
    $sp.Children.Add($line) | Out-Null
    $grid.Children.Add($sp) | Out-Null
    $panel.Children.Add($border) | Out-Null
    $border.Child = $grid
    $border.Tag = @{ kind = 'long'; id = [string]$ev.id; date = '' }
    $border.Add_MouseLeftButtonUp({ param($s, $e) Show-DetailById $s.Tag })
    return
  }

  $line = New-Object System.Windows.Controls.StackPanel
  $line.Orientation = 'Horizontal'
  $tTime = New-TextBlock ([string]$ev.start) 12.5 '#EAF1FF' 'Bold'
  $tTime.Width = 44
  $line.Children.Add($tTime) | Out-Null
  $tTitle = New-TextBlock ([string]$ev.title) 13 '#EAF1FF'
  $line.Children.Add($tTitle) | Out-Null
  $sp.Children.Add($line) | Out-Null

  $sub = @()
  $pl = Abbrev ([string]$ev.place)
  if ($pl) { $sub += $pl }
  if ($sub.Count -gt 0) {
    $tSub = New-TextBlock ($sub -join ' · ') 11 '#9FB4D6'
    $sp.Children.Add($tSub) | Out-Null
  }
  $grid.Children.Add($sp) | Out-Null
  $border.Child = $grid
  $panel.Children.Add($border) | Out-Null
  $border.Tag = @{ kind = 'event'; id = [string]$ev.id; date = $dateKey }
  $border.Add_MouseLeftButtonUp({ param($s, $e) Show-DetailById $s.Tag })
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
    $hl = New-TextBlock ("$head · $($day.Month)/$($day.Day)") 11 ($(if ($i -eq 0) { '#64D2FF' } else { '#8FA6C8' })) ($(if ($i -eq 0) { 'Bold' } else { 'Normal' }))
    $hl.Margin = New-Object System.Windows.Thickness 2,5,0,2
    $WeekPanel.Children.Add($hl) | Out-Null

    if ($events.Count -eq 0) {
      $empty = New-TextBlock '——' 10 '#5A6E8C'
      $empty.Margin = New-Object System.Windows.Thickness 6,0,0,2
      $WeekPanel.Children.Add($empty) | Out-Null
      continue
    }
    foreach ($ev in $events) {
      $past = ($i -eq 0) -and ((Mins ([string]$ev.end)) -lt $nowMin)
      Add-Item $WeekPanel $ev 'event' $dk $past
    }
  }

  try { $WeekScroll.ScrollToTop() } catch { }
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

function Show-DetailById($tag) {
  try {
    $id = [string]$tag.id
    $kind = [string]$tag.kind
    $dk = [string]$tag.date
    $d = Read-Data
    if (-not $d) { return }
    $col = if ($kind -eq 'event') { 'events' } else { 'longterm' }
    $item = @($d.$col) | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1
    if (-not $item) { Log-Ui ("详情找不到记录 id=" + $id); return }
    Show-Detail $item $kind $dk
  } catch { Log-Ui ("Show-DetailById 失败: " + $_.Exception.Message) }
}

function Show-Detail($ev, [string]$kind, [string]$dateKey) {
  Log-Ui ("打开详情 kind=$kind id=" + [string]$ev.id)
  $shell = New-DialogShell 380 330 ('详情')
  $w = $shell.Win
  $sp = $shell.Panel

  $t = New-TextBlock ([string]$ev.title) 13.5 '#EAF1FF' 'Bold'
  $sp.Children.Add($t) | Out-Null

  $meta = ''
  if ($kind -eq 'event') { $meta = ([string]$ev.start) + ' – ' + ([string]$ev.end) }
  else { if ($ev.due) { $meta = 'DDL：' + [string]$ev.due } else { $meta = '没有明确 DDL' } }
  $tm = New-TextBlock $meta 11 '#9FB4D6'
  $tm.Margin = New-Object System.Windows.Thickness 0,4,0,0
  $sp.Children.Add($tm) | Out-Null

  if ($ev.place) {
    $tp = New-TextBlock ('地点：' + (Abbrev ([string]$ev.place))) 11 '#9FB4D6'
    $sp.Children.Add($tp) | Out-Null
  }

  $sp.Children.Add((New-Lbl '我的备注')) | Out-Null
  $note = New-Object System.Windows.Controls.TextBox
  $note.Text = [string]$ev.note
  $note.Width = 340
  $note.Height = 92
  $note.AcceptsReturn = $true
  $note.TextWrapping = 'Wrap'
  $note.Background = Brush '#22FFFFFF'
  $note.Foreground = Brush '#EAF1FF'
  $note.BorderThickness = New-Object System.Windows.Thickness 0
  $note.Padding = New-Object System.Windows.Thickness 6
  $note.FontSize = 12
  $sp.Children.Add($note) | Out-Null

  $hint = New-TextBlock '' 10 '#FF9E9E'
  $hint.Margin = New-Object System.Windows.Thickness 0,4,0,0
  $sp.Children.Add($hint) | Out-Null

  $btns = New-Object System.Windows.Controls.StackPanel
  $btns.Orientation = 'Horizontal'
  $btns.Margin = New-Object System.Windows.Thickness 0,8,0,0

  $doneText = if ($kind -eq 'event') {
    if ([string]$ev.doneOn -eq $dateKey) { '取消完成' } else { '今天完成' }
  } else {
    if ($ev.done) { '取消完成' } else { '完成' }
  }

  $btnSave = New-DlgButton '保存备注' '#3364D2FF' 10
  $btnDone = New-DlgButton $doneText
  $btnEdit = New-DlgButton '编辑'
  $btnDel = New-DlgButton '删除'
  $btnClose = New-DlgButton '关闭'
  foreach ($c in @($btnSave, $btnDone, $btnEdit, $btnDel, $btnClose)) { $btns.Children.Add($c) | Out-Null }
  $sp.Children.Add($btns) | Out-Null

  $evId = [string]$ev.id
  $dlgKind = $kind
  $dk = $dateKey

  $btnClose.Add_Click({ $w.Close() })

  $btnSave.Add_Click({
    try {
      $d = Read-Data
      $col = if ($dlgKind -eq 'event') { 'events' } else { 'longterm' }
      $target = @($d.$col) | Where-Object { [string]$_.id -eq $evId } | Select-Object -First 1
      if ($target) {
        $target | Add-Member -NotePropertyName note -NotePropertyValue $note.Text -Force
        Write-Data $d
        Render
        Log-Ui "备注已保存 $evId"
      } else { $hint.Text = '找不到这条记录' }
    } catch { $hint.Text = $_.Exception.Message; Log-Ui "保存备注失败: $($_.Exception.Message)" }
  })

  $btnDone.Add_Click({
    try {
      $d = Read-Data
      $col = if ($dlgKind -eq 'event') { 'events' } else { 'longterm' }
      $target = @($d.$col) | Where-Object { [string]$_.id -eq $evId } | Select-Object -First 1
      if ($target) {
        if ($dlgKind -eq 'event') {
          $cur = [string]$target.doneOn
          if ($cur -eq $dk) { $target.PSObject.Properties.Remove('doneOn') }
          else { $target | Add-Member -NotePropertyName doneOn -NotePropertyValue $dk -Force }
        } else {
          $target | Add-Member -NotePropertyName done -NotePropertyValue (-not [bool]$target.done) -Force
        }
        Write-Data $d
        Render
        Log-Ui "完成状态已切换 $evId"
        $w.Close()
      }
    } catch { $hint.Text = $_.Exception.Message; Log-Ui "切换完成失败: $($_.Exception.Message)" }
  })

  $btnEdit.Add_Click({
    $w.Close()
    Show-Editor $dlgKind $evId
  })

  $btnDel.Add_Click({
    try {
      $d = Read-Data
      if ($dlgKind -eq 'event') {
        $before = @($d.events).Count
        $d.events = @(@($d.events) | Where-Object { [string]$_.id -ne $evId })
        Log-Ui ("删除事件 $evId，$before -> " + @($d.events).Count)
      } else {
        $before = @($d.longterm).Count
        $d.longterm = @(@($d.longterm) | Where-Object { [string]$_.id -ne $evId })
        Log-Ui ("删除长期 $evId，$before -> " + @($d.longterm).Count)
      }
      Write-Data $d
      Render
      $w.Close()
    } catch { $hint.Text = $_.Exception.Message; Log-Ui "删除失败: $($_.Exception.Message)" }
  })

  $w.ShowDialog() | Out-Null
}
function Show-Settings {
  $w = New-Object System.Windows.Window
  $w.WindowStyle = 'None'; $w.AllowsTransparency = $true; $w.Background = 'Transparent'
  $w.ShowInTaskbar = $false; $w.Topmost = $true
  $w.Width = 320; $w.Height = 260
  $w.WindowStartupLocation = 'CenterOwner'; $w.Owner = $script:MainWin

  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = New-Object System.Windows.CornerRadius 10
  $b.Background = Brush '#F0142136'
  $b.BorderBrush = Brush '#5964D2FF'
  $b.BorderThickness = New-Object System.Windows.Thickness 1
  $b.Padding = New-Object System.Windows.Thickness 12
  $sp = New-Object System.Windows.Controls.StackPanel

  $t = New-TextBlock '设置' 13 '#EAF1FF' 'Bold'
  $sp.Children.Add($t) | Out-Null

  $lw = New-TextBlock '宽度 / 高度' 10.5 '#7F93B3'
  $lw.Margin = New-Object System.Windows.Thickness 0,8,0,3
  $sp.Children.Add($lw) | Out-Null

  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = 'Horizontal'
  $tw = New-Object System.Windows.Controls.TextBox
  $tw.Width = 70; $tw.Text = [string][int]$win.Width; $tw.Background = Brush '#22FFFFFF'
  $tw.Foreground = Brush '#EAF1FF'; $tw.BorderThickness = 0; $tw.Padding = New-Object System.Windows.Thickness 4
  $row.Children.Add($tw) | Out-Null
  $x1 = New-TextBlock ' × ' 12 '#9FB4D6'; $x1.VerticalAlignment = 'Center'
  $row.Children.Add($x1) | Out-Null
  $th = New-Object System.Windows.Controls.TextBox
  $th.Width = 70; $th.Text = [string][int]$win.Height; $th.Background = Brush '#22FFFFFF'
  $th.Foreground = Brush '#EAF1FF'; $th.BorderThickness = 0; $th.Padding = New-Object System.Windows.Thickness 4
  $row.Children.Add($th) | Out-Null
  $sp.Children.Add($row) | Out-Null

  $lo = New-TextBlock '背景不透明度' 10.5 '#7F93B3'
  $lo.Margin = New-Object System.Windows.Thickness 0,10,0,3
  $sp.Children.Add($lo) | Out-Null

  $sl = New-Object System.Windows.Controls.Slider
  $sl.Minimum = 0.3; $sl.Maximum = 0.95; $sl.TickFrequency = 0.05
  $curOp = 0.85
  try { if ($script:Data.settings.opacity) { $curOp = [double]$script:Data.settings.opacity } } catch { }
  $sl.Value = $curOp
  $sp.Children.Add($sl) | Out-Null

  $btns = New-Object System.Windows.Controls.StackPanel
  $btns.Orientation = 'Horizontal'; $btns.Margin = New-Object System.Windows.Thickness 0,12,0,0
  $ok = New-Object System.Windows.Controls.Button
  $ok.Content = '应用'; $ok.Padding = New-Object System.Windows.Thickness 12,4,12,4
  $ok.Background = Brush '#3364D2FF'; $ok.Foreground = Brush '#EAF1FF'; $ok.BorderThickness = 0; $ok.FontSize = 12
  $btns.Children.Add($ok) | Out-Null
  $cancel = New-Object System.Windows.Controls.Button
  $cancel.Content = '取消'; $cancel.Padding = New-Object System.Windows.Thickness 12,4,12,4
  $cancel.Margin = New-Object System.Windows.Thickness 8,0,0,0
  $cancel.Background = Brush '#22FFFFFF'; $cancel.Foreground = Brush '#EAF1FF'; $cancel.BorderThickness = 0; $cancel.FontSize = 12
  $btns.Children.Add($cancel) | Out-Null
  $sp.Children.Add($btns) | Out-Null

  $b.Child = $sp; $w.Content = $b

  $cancel.Add_Click({ $w.Close() })
  $ok.Add_Click({
    $nw = 520; $nh = 330
    [void][int]::TryParse($tw.Text, [ref]$nw)
    [void][int]::TryParse($th.Text, [ref]$nh)
    if ($nw -lt 300) { $nw = 300 }; if ($nw -gt 960) { $nw = 960 }
    if ($nh -lt 140) { $nh = 140 }; if ($nh -gt 680) { $nh = 680 }
    $win.Width = $nw; $win.Height = $nh
    $op = [math]::Round($sl.Value, 2)
    $Root.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb([byte](255*$op), 10, 17, 29))
    $d = Read-Data
    if ($d) {
      if (-not $d.settings) { $d | Add-Member -NotePropertyName settings -NotePropertyValue ([pscustomobject]@{}) -Force }
      $d.settings | Add-Member -NotePropertyName w -NotePropertyValue $nw -Force
      $d.settings | Add-Member -NotePropertyName h -NotePropertyValue $nh -Force
      $d.settings | Add-Member -NotePropertyName opacity -NotePropertyValue $op -Force
      Write-Data $d
    }
    $w.Close()
  })
  $w.ShowDialog() | Out-Null
}

function New-Editor-Combo([int]$from, [int]$to, [string]$sel) {
  $cb = New-Object System.Windows.Controls.ComboBox
  $cb.Width = 62
  $cb.Height = 26
  $cb.FontSize = 12
  $cb.Background = Brush '#22FFFFFF'
  $cb.Foreground = Brush '#EAF1FF'
  $cb.BorderThickness = New-Object System.Windows.Thickness 0
  for ($i = $from; $i -le $to; $i++) {
    [void]$cb.Items.Add((Pad2 $i))
  }
  if ($sel) { $cb.SelectedItem = $sel } else { $cb.SelectedIndex = 0 }
  return $cb
}

function New-Lbl([string]$text) {
  $l = New-TextBlock $text 10.5 '#7F93B3'
  $l.Margin = New-Object System.Windows.Thickness 0,8,0,3
  return $l
}

function New-Box([string]$value, [double]$width = 380, [double]$height = 26) {
  $t = New-Object System.Windows.Controls.TextBox
  $t.Text = [string]$value
  $t.Width = $width
  $t.Height = $height
  $t.FontSize = 12
  $t.Background = Brush '#22FFFFFF'
  $t.Foreground = Brush '#EAF1FF'
  $t.BorderThickness = New-Object System.Windows.Thickness 0
  $t.Padding = New-Object System.Windows.Thickness 5,3,5,3
  return $t
}

function New-DlgButton([string]$text, [string]$bg = '#22FFFFFF', [double]$pad = 12) {
  $btn = New-Object System.Windows.Controls.Button
  $btn.Content = $text
  $btn.Padding = New-Object System.Windows.Thickness $pad,4,$pad,4
  $btn.Margin = New-Object System.Windows.Thickness 8,0,0,0
  $btn.Background = Brush $bg
  $btn.Foreground = Brush '#EAF1FF'
  $btn.BorderThickness = New-Object System.Windows.Thickness 0
  $btn.FontSize = 12
  return $btn
}

function New-DialogShell([double]$w, [double]$h, [string]$title) {
  $win2 = New-Object System.Windows.Window
  $win2.WindowStyle = 'None'
  $win2.AllowsTransparency = $true
  $win2.Background = 'Transparent'
  $win2.ShowInTaskbar = $false
  $win2.Topmost = $true
  $win2.Width = $w
  $win2.Height = $h
  $win2.WindowStartupLocation = 'CenterOwner'
  $win2.Owner = $script:MainWin
  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = New-Object System.Windows.CornerRadius 10
  $border.Background = Brush '#F0142136'
  $border.BorderBrush = Brush '#5964D2FF'
  $border.BorderThickness = New-Object System.Windows.Thickness 1
  $border.Padding = New-Object System.Windows.Thickness 14
  $panel = New-Object System.Windows.Controls.StackPanel
  $head = New-TextBlock $title 13.5 '#EAF1FF' 'Bold'
  $panel.Children.Add($head) | Out-Null
  $border.Child = $panel
  $win2.Content = $border
  return @{ Win = $win2; Panel = $panel }
}

function Show-Editor([string]$kind, [string]$id) {
  $isEvent = ($kind -eq 'event')
  $d = Read-Data
  if (-not $d) { return }
  $item = $null
  if ($id) {
    if ($isEvent) { $item = @($d.events) | Where-Object { [string]$_.id -eq [string]$id } | Select-Object -First 1 }
    else { $item = @($d.longterm) | Where-Object { [string]$_.id -eq [string]$id } | Select-Object -First 1 }
  }

  $cap = if ($id) { '编辑' } elseif ($isEvent) { '新增待办' } else { '新增长期任务' }
  $shell = New-DialogShell 430 $(if ($isEvent) { 470 } else { 320 }) $cap
  $w = $shell.Win
  $sp = $shell.Panel

  $sp.Children.Add((New-Lbl '标题')) | Out-Null
  $tbTitle = New-Box ($(if ($item) { $item.title } else { '' })) 380
  $sp.Children.Add($tbTitle) | Out-Null

  $tbDate = $null; $cbSh = $null; $cbSm = $null; $cbEh = $null; $cbEm = $null
  $tbPlace = $null; $tbRemind = $null; $cbRepeat = $null; $tbDue = $null

  if ($isEvent) {
    $sp.Children.Add((New-Lbl '日期')) | Out-Null
    $tbDate = New-Box ($(if ($item) { $item.day } else { (DayKey (Get-Date)) })) 130
    $sp.Children.Add($tbDate) | Out-Null

    $sp.Children.Add((New-Lbl '时间（时 / 分：最上 00，最下 23 / 59）')) | Out-Null
    $rowT = New-Object System.Windows.Controls.StackPanel
    $rowT.Orientation = 'Horizontal'
    $s0 = if ($item) { [string]$item.start } else { '08:00' }
    $e0 = if ($item) { [string]$item.end } else { '09:00' }
    $sp1 = $s0.Split(':'); $ep1 = $e0.Split(':')
    $cbSh = New-Editor-Combo 0 23 $sp1[0]
    $cbSm = New-Editor-Combo 0 59 $sp1[1]
    $cbEh = New-Editor-Combo 0 23 $ep1[0]
    $cbEm = New-Editor-Combo 0 59 $ep1[1]
    $l1 = New-TextBlock '开始 ' 11 '#9FB4D6'; $l1.VerticalAlignment = 'Center'
    $c1 = New-TextBlock ':' 12 '#9FB4D6'; $c1.VerticalAlignment = 'Center'; $c1.Margin = New-Object System.Windows.Thickness 2,0,2,0
    $l2 = New-TextBlock '   结束 ' 11 '#9FB4D6'; $l2.VerticalAlignment = 'Center'
    $c2 = New-TextBlock ':' 12 '#9FB4D6'; $c2.VerticalAlignment = 'Center'; $c2.Margin = New-Object System.Windows.Thickness 2,0,2,0
    foreach ($c in @($l1, $cbSh, $c1, $cbSm, $l2, $cbEh, $c2, $cbEm)) { $rowT.Children.Add($c) | Out-Null }
    $sp.Children.Add($rowT) | Out-Null

    $sp.Children.Add((New-Lbl '地点')) | Out-Null
    $tbPlace = New-Box ($(if ($item) { $item.place } else { '' })) 380
    $sp.Children.Add($tbPlace) | Out-Null

    $row2 = New-Object System.Windows.Controls.StackPanel
    $row2.Orientation = 'Horizontal'
    $r1 = New-TextBlock '提前分钟 ' 11 '#9FB4D6'; $r1.VerticalAlignment = 'Center'
    $tbRemind = New-Box ($(if ($item -and $null -ne $item.remindMin) { [string]$item.remindMin } else { '15' })) 66
    $r2 = New-TextBlock '   重复 ' 11 '#9FB4D6'; $r2.VerticalAlignment = 'Center'
    $cbRepeat = New-Object System.Windows.Controls.ComboBox
    $cbRepeat.Width = 96; $cbRepeat.Height = 26; $cbRepeat.FontSize = 12
    $cbRepeat.Background = Brush '#22FFFFFF'
    $cbRepeat.Foreground = Brush '#EAF1FF'
    $cbRepeat.BorderThickness = New-Object System.Windows.Thickness 0
    [void]$cbRepeat.Items.Add('只一次')
    [void]$cbRepeat.Items.Add('每周')
    if ($item -and $item.repeat -eq 'weekly') { $cbRepeat.SelectedIndex = 1 } else { $cbRepeat.SelectedIndex = 0 }
    foreach ($c in @($r1, $tbRemind, $r2, $cbRepeat)) { $row2.Children.Add($c) | Out-Null }
    $sp.Children.Add($row2) | Out-Null
  } else {
    $sp.Children.Add((New-Lbl '截止日期（YYYY-MM-DD，可空）')) | Out-Null
    $tbDue = New-Box ($(if ($item) { $item.due } else { '' })) 170
    $sp.Children.Add($tbDue) | Out-Null
  }

  $sp.Children.Add((New-Lbl '备注（写一句人话，点「识别」自动填上面）')) | Out-Null
  $tbNote = New-Box ($(if ($item) { $item.note } else { '' })) 380 56
  $tbNote.AcceptsReturn = $true
  $tbNote.TextWrapping = 'Wrap'
  $sp.Children.Add($tbNote) | Out-Null

  $hint = New-TextBlock '' 10.5 '#64D2FF'
  $hint.Margin = New-Object System.Windows.Thickness 0,4,0,0
  $sp.Children.Add($hint) | Out-Null

  $btns = New-Object System.Windows.Controls.StackPanel
  $btns.Orientation = 'Horizontal'
  $btns.Margin = New-Object System.Windows.Thickness 0,10,0,0

  $btnParse = New-DlgButton '识别'
  $btnSave = New-DlgButton '保存' '#3364D2FF' 14
  $btnCancel = New-DlgButton '取消'
  foreach ($c in @($btnParse, $btnSave, $btnCancel)) { $btns.Children.Add($c) | Out-Null }
  $sp.Children.Add($btns) | Out-Null

  $btnCancel.Add_Click({ $w.Close() })

  $btnParse.Add_Click({
    $txt = $tbNote.Text.Trim()
    if (-not $txt) { $hint.Text = '先在备注里写一句'; return }
    if ($script:ApiPort -le 0) { $hint.Text = '识别服务不可用（插件未运行）'; return }
    try {
      $body = @{ text = $txt } | ConvertTo-Json -Compress
      $r = Invoke-RestMethod -Uri "http://127.0.0.1:$($script:ApiPort)/parse" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 3
      if ($r.ok) {
        if ($r.title) { $tbTitle.Text = [string]$r.title }
        if ($isEvent) {
          if ($r.date) { $tbDate.Text = [string]$r.date }
          if ($r.start) { $p = ([string]$r.start).Split(':'); $cbSh.SelectedItem = $p[0]; $cbSm.SelectedItem = $p[1] }
          if ($r.end) { $p2 = ([string]$r.end).Split(':'); $cbEh.SelectedItem = $p2[0]; $cbEm.SelectedItem = $p2[1] }
          if ($r.place) { $tbPlace.Text = [string]$r.place }
        }
        $hint.Text = '识别为：' + [string]$r.date + ' ' + [string]$r.start + '-' + [string]$r.end + ' ' + [string]$r.place + ' ' + [string]$r.title
      } else { $hint.Text = '没认出时间或地点' }
    } catch { $hint.Text = '识别服务出错' }
  })

  $btnSave.Add_Click({
    $d2 = Read-Data
    if (-not $d2) { return }
    $t = $tbTitle.Text.Trim()
    if (-not $t) { $hint.Text = '标题不能空'; return }
    if ($isEvent) {
      $target = $null
      if ($id) { $target = @($d2.events) | Where-Object { [string]$_.id -eq [string]$id } | Select-Object -First 1 }
      if (-not $target) {
        $newId = 'e' + [int64]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds
        $target = [pscustomobject]@{ id = $newId }
        $d2.events = @($d2.events) + $target
      }
      $target | Add-Member -NotePropertyName title -NotePropertyValue $t -Force
      $dayVal = if ($tbDate.Text.Trim()) { $tbDate.Text.Trim() } else { DayKey (Get-Date) }
      $target | Add-Member -NotePropertyName day -NotePropertyValue $dayVal -Force
      $target | Add-Member -NotePropertyName start -NotePropertyValue ([string]$cbSh.SelectedItem + ':' + [string]$cbSm.SelectedItem) -Force
      $target | Add-Member -NotePropertyName end -NotePropertyValue ([string]$cbEh.SelectedItem + ':' + [string]$cbEm.SelectedItem) -Force
      $target | Add-Member -NotePropertyName place -NotePropertyValue $tbPlace.Text.Trim() -Force
      $rem = 15
      if ($tbRemind.Text -match '^\d+$') { $rem = [int]$tbRemind.Text }
      $target | Add-Member -NotePropertyName remindMin -NotePropertyValue $rem -Force
      $rep = if ($cbRepeat.SelectedIndex -eq 1) { 'weekly' } else { 'none' }
      $target | Add-Member -NotePropertyName repeat -NotePropertyValue $rep -Force
      $target | Add-Member -NotePropertyName note -NotePropertyValue $tbNote.Text -Force
      if (-not ($target.PSObject.Properties.Name -contains 'color')) { $target | Add-Member -NotePropertyName color -NotePropertyValue 'blue' -Force }
    } else {
      $target = $null
      if ($id) { $target = @($d2.longterm) | Where-Object { [string]$_.id -eq [string]$id } | Select-Object -First 1 }
      if (-not $target) {
        $newId = 'l' + [int64]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds
        $target = [pscustomobject]@{ id = $newId; done = $false }
        $d2.longterm = @($d2.longterm) + $target
      }
      $target | Add-Member -NotePropertyName title -NotePropertyValue $t -Force
      $target | Add-Member -NotePropertyName due -NotePropertyValue $tbDue.Text.Trim() -Force
      $target | Add-Member -NotePropertyName note -NotePropertyValue $tbNote.Text -Force
      if (-not ($target.PSObject.Properties.Name -contains 'done')) { $target | Add-Member -NotePropertyName done -NotePropertyValue $false -Force }
    }
    Write-Data $d2
    Render
    $w.Close()
  })

  $w.ShowDialog() | Out-Null
}
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
$BtnAdd.Add_Click({ Show-Editor 'event' $null })
$BtnAdd.Add_MouseRightButtonUp({ Show-Editor 'long' $null })
$BtnCfg.Add_Click({ Show-Settings })
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
