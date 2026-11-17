Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# === НАСТРОЙКИ ===
$TargetDevice = "ACTON III"
$IntervalSeconds = 240 # 4 минуты между звуковыми импульсами

# === ГЕНЕРАЦИЯ НЕСЛЫШИМОГО ЗВУКА (1 сек, 15 Гц) ===
function Play-SilentTone {
    try {
        $sampleRate = 44100
        $duration = 1
        $frequency = 15
        $amplitude = 15
        $numSamples = $sampleRate * $duration

        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)

        $bw.Write([Text.Encoding]::ASCII.GetBytes("RIFF"))
        $bw.Write([int32](36 + $numSamples * 2))
        $bw.Write([Text.Encoding]::ASCII.GetBytes("WAVEfmt "))
        $bw.Write([int32]16)
        $bw.Write([int16]1)
        $bw.Write([int16]1)
        $bw.Write([int32]$sampleRate)
        $bw.Write([int32]($sampleRate * 2))
        $bw.Write([int16]2)
        $bw.Write([int16]16)
        $bw.Write([Text.Encoding]::ASCII.GetBytes("data"))
        $bw.Write([int32]($numSamples * 2))

        $bytes = New-Object byte[] ($numSamples * 2)
        for ($i = 0; $i -lt $numSamples; $i++) {
            $sample = [int16]($amplitude * [Math]::Sin(2 * [Math]::PI * $frequency * $i / $sampleRate))
            $bytes[$i * 2] = [byte]($sample -band 0xFF)
            $bytes[$i * 2 + 1] = [byte](($sample -shr 8) -band 0xFF)
        }
        $bw.Write($bytes)

        $ms.Position = 0
        $player = New-Object System.Media.SoundPlayer($ms)
        $player.PlaySync()
        
        $bw.Dispose()
        $ms.Dispose()
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Импульс отправлен на колонку." -ForegroundColor Green
    } catch {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Ошибка воспроизведения: $_" -ForegroundColor Red
    }
}

# === ФУНКЦИЯ ПОИСКА КОЛОНКИ ===
function Get-ActonDevice {
    $dev = Get-PnpDevice -Class AudioEndpoint -Status "OK" -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like "*$TargetDevice*" } | Select-Object -First 1
    if ($dev) { return $dev.FriendlyName }
    return $null
}

# === СОЗДАНИЕ ТРЕХ ИКОНОК ДЛЯ ТРЕЯ ===
function New-StatusIcon([System.Drawing.Color]$Color) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $g.Dispose()
    $brush.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$IconActive  = New-StatusIcon([System.Drawing.Color]::LimeGreen) # Зеленая: работает и найдена
$IconWaiting = New-StatusIcon([System.Drawing.Color]::Orange)    # Оранжевая: работает, но колонка не найдена
$IconPaused  = New-StatusIcon([System.Drawing.Color]::Crimson)   # Красная: остановлено вручную

# === НАСТРОЙКА ИКОНКИ И МЕНЮ ===
$NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$NotifyIcon.Icon = $IconWaiting
$NotifyIcon.Text = "Marshall Keep-Alive: Поиск..."
$NotifyIcon.Visible = $true

$ContextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$MenuDevice = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuDevice.Text = "Колонка: поиск..."
$MenuDevice.Enabled = $false

$MenuStart = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuStart.Text = "Запустить"
$MenuStart.Enabled = $false

$MenuStop = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuStop.Text = "Остановить"
$MenuStop.Enabled = $true

$MenuExit = New-Object System.Windows.Forms.ToolStripMenuItem
$MenuExit.Text = "Выход"

$ContextMenu.Items.AddRange(@($MenuDevice, (New-Object System.Windows.Forms.ToolStripSeparator), $MenuStart, $MenuStop, (New-Object System.Windows.Forms.ToolStripSeparator), $MenuExit))
$NotifyIcon.ContextMenuStrip = $ContextMenu

# === ЛОГИКА СТАТУСОВ И ТАЙМЕРЫ ===
$script:IsRunning = $true
$script:LastPulseTime = [DateTime]::MinValue

function Refresh-State {
    param([bool]$ForcePulse = $false)

    if (-not $script:IsRunning) {
        $MenuDevice.Text = "Колонка: на паузе"
        $NotifyIcon.Icon = $IconPaused
        $NotifyIcon.Text = "Marshall Keep-Alive: Остановлен"
        return
    }

    $foundName = Get-ActonDevice
    if ($foundName) {
        $MenuDevice.Text = "Найдена: $foundName"
        $NotifyIcon.Icon = $IconActive
        $NotifyIcon.Text = "Marshall Keep-Alive: Активен ($foundName)"

        if ($ForcePulse -or ((Get-Date) - $script:LastPulseTime).TotalSeconds -ge $IntervalSeconds) {
            Play-SilentTone
            $script:LastPulseTime = Get-Date
        }
    } else {
        $MenuDevice.Text = "Колонка: не подключена"
        $NotifyIcon.Icon = $IconWaiting
        $NotifyIcon.Text = "Marshall Keep-Alive: Ожидание колонки"
        if ($ForcePulse) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Колонка не найдена, режим ожидания." -ForegroundColor Yellow
        }
    }
}

# Таймер проверки статуса каждые 10 секунд
$CheckTimer = New-Object System.Windows.Forms.Timer
$CheckTimer.Interval = 10000 
$CheckTimer.Add_Tick({
    Refresh-State
})

$ContextMenu.Add_Opening({
    Refresh-State
})

$MenuStart.Add_Click({
    $script:IsRunning = $true
    $MenuStart.Enabled = $false
    $MenuStop.Enabled = $true
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Скрипт запущен пользователем." -ForegroundColor Cyan
    Refresh-State -ForcePulse $true
    $CheckTimer.Start()
})

$MenuStop.Add_Click({
    $script:IsRunning = $false
    $MenuStart.Enabled = $true
    $MenuStop.Enabled = $false
    $CheckTimer.Stop()
    Refresh-State
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Скрипт остановлен пользователем." -ForegroundColor Red
})

$MenuExit.Add_Click({
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Завершение работы..." -ForegroundColor Cyan
    $CheckTimer.Stop()
    $NotifyIcon.Visible = $false
    $NotifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# Первый запуск
Write-Host "Скрипт запущен. Иконка добавлена в системный трей." -ForegroundColor Cyan
Refresh-State -ForcePulse $true
$CheckTimer.Start()

[System.Windows.Forms.Application]::Run()
