# Contract Wars Resolution Unlock Patch
# Снимает ограничение разрешения 1920x1080 в клиенте Contract Wars (CWClient).
# Removes the 1920x1080 resolution cap in the Contract Wars client (CWClient).
#
# Использование / Usage:
#   PATCH.vbs (в корне архива)                        # графическое окно без консолей (рекомендуется)
#   .\Patch-CWResolution.ps1 -GUI                     # графическое окно (GUI)
#   .\Patch-CWResolution.ps1                          # консоль: авто-поиск игры, потолок 7680x4320
#   .\Patch-CWResolution.ps1 -GamePath "D:\CWClient"  # консоль: указать папку игры
#   .\Patch-CWResolution.ps1 -Restore                 # консоль: откатить патч из бэкапа

param(
    [string]$GamePath = "",
    [int]$MaxWidth  = 7680,
    [int]$MaxHeight = 4320,
    [switch]$Restore,
    [switch]$GUI
)

$ErrorActionPreference = "Stop"

function Find-GameDll {
    param([string]$Hint)
    $candidates = @()
    if ($Hint) { $candidates += $Hint }
    $candidates += (Get-Location).Path
    # скрипт лежит в engine\ — проверим саму engine и папки выше (patch может лежать в папке игры)
    $candidates += $PSScriptRoot
    $d = $PSScriptRoot
    for ($up = 0; $up -lt 3 -and $d; $up++) { $d = Split-Path -Parent $d; if ($d) { $candidates += $d } }
    # типовые места установки
    $candidates += "C:\Games\CWClient"
    $candidates += "C:\Program Files (x86)\CWClient"
    $candidates += "C:\Program Files\CWClient"
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        foreach ($rel in @("CWClient_Data\Managed\Assembly-CSharp.dll", "Managed\Assembly-CSharp.dll", "Assembly-CSharp.dll")) {
            $p = Join-Path $c $rel
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

# --- Паттерн A: Utility.FixResolution ---
# IL: ldc.i4 W; bgt +0F; call Screen.get_height; ldc.i4 H; ble +14; ldc.i4 W; ldc.i4 H; call SetResolution
# Значения констант замаскированы — патч работает и на оригинале, и поверх старого патча.
function Test-PatternA($b, $i) {
    return ($b[$i] -eq 0x20 -and $b[$i+5] -eq 0x3D -and $b[$i+6] -eq 0x0F -and $b[$i+7] -eq 0 -and $b[$i+8] -eq 0 -and $b[$i+9] -eq 0 -and
            $b[$i+10] -eq 0x28 -and $b[$i+13] -eq 0 -and $b[$i+14] -eq 0x0A -and
            $b[$i+15] -eq 0x20 -and $b[$i+20] -eq 0x3E -and $b[$i+21] -eq 0x14 -and $b[$i+22] -eq 0 -and $b[$i+23] -eq 0 -and $b[$i+24] -eq 0 -and
            $b[$i+25] -eq 0x20 -and $b[$i+30] -eq 0x20 -and
            $b[$i+35] -eq 0x28 -and $b[$i+38] -eq 0 -and $b[$i+39] -eq 0x0A)
}

# --- Паттерн B: верхний фильтр списка разрешений в меню настроек (SettingsGUI) ---
# Ищем: ldc.i4 <ширина 1024..16384> сразу за которым идёт условный переход
# (bgt/ble/blt/bge в long-форме 0x3D..0x41 или short 0x2C..0x33).
# Подтверждаем контекст двумя признаками в окне ±64 байта:
#   * рядом есть call get_width  (28 xx xx xx 0A)
#   * рядом есть нижний порог 800  (ldc.i4 800 = 20 20 03 00 00)
# Ничего не привязано к точным смещениям — устойчиво к разным сборкам клиента.
function Test-PatternB($b, $j) {
    if ($b[$j] -ne 0x20) { return $false }
    $jmp = $b[$j+5]
    $isJump = ($jmp -ge 0x3D -and $jmp -le 0x41) -or ($jmp -ge 0x2C -and $jmp -le 0x33)
    if (-not $isJump) { return $false }
    $v = [BitConverter]::ToInt32($b, $j+1)
    if ($v -lt 1024 -or $v -gt 16384) { return $false }
    $has800 = $false; $hasCall = $false
    $lo = [Math]::Max(0, $j-64); $hi = [Math]::Min($b.Length-6, $j+64)
    for ($k = $lo; $k -le $hi; $k++) {
        if ($b[$k] -eq 0x20 -and $b[$k+1] -eq 0x20 -and $b[$k+2] -eq 0x03 -and $b[$k+3] -eq 0 -and $b[$k+4] -eq 0) { $has800 = $true }
        if ($b[$k] -eq 0x28 -and $b[$k+4] -eq 0x0A) { $hasCall = $true }
    }
    return ($has800 -and $hasCall)
}

function Write-Int32($b, $pos, $val) {
    $le = [BitConverter]::GetBytes([int]$val)
    for ($n = 0; $n -lt 4; $n++) { $b[$pos + $n] = $le[$n] }
}

# Применяет патч. Возвращает @{ ok = $true/$false; message = "..." }
# $OnProgress — колбэк (0..100), вызывается по ходу сканирования DLL.
function Invoke-CWPatch {
    param([string]$Dll, [int]$W, [int]$H, [scriptblock]$OnProgress = $null)
    if ($W -lt 800 -or $W -gt 16384 -or $H -lt 600 -or $H -gt 16384) {
        return @{ ok = $false; message = "Недопустимые значения ширины/высоты." }
    }
    if ($OnProgress) { & $OnProgress 0 }
    $bytes = [IO.File]::ReadAllBytes($Dll)
    $hitsA = @(); $hitsB = @()
    $total = $bytes.Length - 41
    $step = [Math]::Max(1, [int]($total / 100))
    for ($i = 5; $i -le $total; $i++) {
        if ($OnProgress -and ($i % $step) -eq 0) { & $OnProgress ([int](100 * $i / $total)) }
        # Быстрый отсев: оба паттерна начинаются с ldc.i4 (opcode 0x20). Переход НЕ проверяем
        # здесь — его форма (long/short) отличается между сборками и обрабатывается в Test-PatternB.
        if ($bytes[$i] -ne 0x20) { continue }
        if (Test-PatternA $bytes $i) { $hitsA += $i }
        if (Test-PatternB $bytes $i) { $hitsB += $i }
    }
    if ($OnProgress) { & $OnProgress 100 }
    if ($hitsA.Count -ne 1 -or $hitsB.Count -ne 1) {
        return @{ ok = $false; message = "Ожидаемые участки кода не найдены однозначно (A=$($hitsA.Count), B=$($hitsB.Count)). Возможно, версия клиента отличается. Файл не изменён." }
    }
    $backup = "$Dll.orig.bak"
    $backupMsg = ""
    if (-not (Test-Path $backup)) {
        Copy-Item $Dll $backup
        $backupMsg = "Бэкап сохранён: $backup`r`n"
    }
    $a = $hitsA[0]; $bOff = $hitsB[0]
    Write-Int32 $bytes ($a + 1)  $W   # FixResolution: порог ширины
    Write-Int32 $bytes ($a + 16) $H   # FixResolution: порог высоты
    Write-Int32 $bytes ($a + 26) $W   # FixResolution: аргумент SetResolution width
    Write-Int32 $bytes ($a + 31) $H   # FixResolution: аргумент SetResolution height
    Write-Int32 $bytes ($bOff + 1) $W # SettingsGUI: потолок списка разрешений
    [IO.File]::WriteAllBytes($Dll, $bytes)
    return @{ ok = $true; message = "${backupMsg}Патч применён! Новый потолок: ${W}x${H}.`r`nЗапустите игру и выберите нужное разрешение в настройках." }
}

function Invoke-CWRestore {
    param([string]$Dll)
    $backup = "$Dll.orig.bak"
    if (-not (Test-Path $backup)) {
        return @{ ok = $false; message = "Бэкап не найден: $backup" }
    }
    Copy-Item $backup $Dll -Force
    return @{ ok = $true; message = "Оригинальная DLL восстановлена из бэкапа." }
}

# Диагностика: собирает текст с кандидатами участков кода для отправки разработчику.
function Get-CWDiagnostics {
    param([string]$Dll)
    $b = [IO.File]::ReadAllBytes($Dll)
    $lines = @()
    $lines += "DLL: $Dll"
    $lines += "Размер: $($b.Length) байт"
    # счётчики паттернов
    $ca = 0; $cb = 0
    for ($i = 5; $i -le $b.Length - 41; $i++) {
        if ($b[$i] -ne 0x20) { continue }
        if (Test-PatternA $b $i) { $ca++ }
        if (Test-PatternB $b $i) { $cb++ }
    }
    $lines += "Паттерны: A=$ca, B=$cb"
    $lines += "--- Кандидаты (ldc.i4 <разрешение> + переход) ---"
    $targets = @(800, 1280, 1360, 1366, 1440, 1600, 1680, 1920, 2048, 2560, 3840, 7680)
    for ($i = 12; $i -le $b.Length - 10; $i++) {
        if ($b[$i] -ne 0x20) { continue }
        $v = [BitConverter]::ToInt32($b, $i + 1)
        if ($targets -notcontains $v) { continue }
        $next = $b[$i + 5]
        if ($next -notin @(0x3D,0x3E,0x3F,0x40,0x41,0x2C,0x2D,0x30,0x31,0x32,0x33)) { continue }
        $hex = ($b[($i-12)..($i+9)] | ForEach-Object { "{0:X2}" -f $_ }) -join ' '
        $lines += ("off=0x{0:X}  val={1}  jmp=0x{2:X2}  :: {3}" -f $i, $v, $next, $hex)
    }
    return ($lines -join "`r`n")
}

# ============================ GUI ============================
if ($GUI) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # --- Подключаем модуль патч-функций (разрешение / клик / автоспавн) ---
    $cwScriptDir = $PSScriptRoot
    if (-not $cwScriptDir) { $cwScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    . (Join-Path $cwScriptDir "CWPatchCore.ps1")

    # --- Палитра ---
    # Палитра в стиле UI игры: тёмная сталь + золото CW
    $clrBack    = [System.Drawing.Color]::FromArgb(38, 41, 43)     # фон окна (тёмно-стальной)
    $clrPanel   = [System.Drawing.Color]::FromArgb(52, 56, 58)     # поля ввода
    $clrText    = [System.Drawing.Color]::FromArgb(222, 224, 222)  # основной текст
    $clrMuted   = [System.Drawing.Color]::FromArgb(148, 152, 150)  # подписи
    $clrAccent  = [System.Drawing.Color]::FromArgb(198, 156, 60)   # золото CW
    $clrAccentH = [System.Drawing.Color]::FromArgb(226, 184, 88)   # золото при наведении
    $clrBtn2    = [System.Drawing.Color]::FromArgb(66, 70, 72)     # второстепенная кнопка (сталь)
    $clrBtn2H   = [System.Drawing.Color]::FromArgb(84, 89, 91)
    $clrOk      = [System.Drawing.Color]::FromArgb(150, 200, 120)  # зелёный для лога/готово

    $fontMain  = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $fontSmall = New-Object System.Drawing.Font("Segoe UI", 8.5)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Contract Wars — Tweaks Patch"
    $form.ClientSize = New-Object System.Drawing.Size(560, 610)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.BackColor = $clrBack
    $form.Font = $fontMain

    # --- Шапка ---
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "CONTRACT WARS"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 17, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = $clrAccent
    $lblTitle.Location = New-Object System.Drawing.Point(18, 14)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = "TWEAKS — РАЗРЕШЕНИЕ · КЛИК · АВТОСПАВН"
    $lblSub.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $lblSub.ForeColor = $clrMuted
    $lblSub.Location = New-Object System.Drawing.Point(20, 46)
    $lblSub.AutoSize = $true
    $form.Controls.Add($lblSub)

    $line = New-Object System.Windows.Forms.Panel
    $line.BackColor = $clrAccent
    $line.Location = New-Object System.Drawing.Point(20, 70)
    $line.Size = New-Object System.Drawing.Size(520, 2)
    $form.Controls.Add($line)

    # --- Папка игры ---
    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = "ПАПКА ИГРЫ  (где лежит CWClient.exe)"
    $lblPath.Font = $fontSmall
    $lblPath.ForeColor = $clrMuted
    $lblPath.Location = New-Object System.Drawing.Point(20, 86)
    $lblPath.AutoSize = $true
    $form.Controls.Add($lblPath)

    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(20, 107)
    $txtPath.Size = New-Object System.Drawing.Size(420, 26)
    $txtPath.BackColor = $clrPanel
    $txtPath.ForeColor = $clrText
    $txtPath.BorderStyle = "FixedSingle"
    $form.Controls.Add($txtPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "Обзор..."
    $btnBrowse.Location = New-Object System.Drawing.Point(452, 105)
    $btnBrowse.Size = New-Object System.Drawing.Size(88, 27)
    $btnBrowse.FlatStyle = "Flat"
    $btnBrowse.FlatAppearance.BorderSize = 0
    $btnBrowse.BackColor = $clrBtn2
    $btnBrowse.ForeColor = $clrText
    $btnBrowse.Cursor = "Hand"
    $btnBrowse.Add_MouseEnter({ $this.BackColor = $clrBtn2H })
    $btnBrowse.Add_MouseLeave({ $this.BackColor = $clrBtn2 })
    $form.Controls.Add($btnBrowse)

    # --- Разрешение ---
    $lblRes = New-Object System.Windows.Forms.Label
    $lblRes.Text = "МАКСИМАЛЬНОЕ РАЗРЕШЕНИЕ"
    $lblRes.Font = $fontSmall
    $lblRes.ForeColor = $clrMuted
    $lblRes.Location = New-Object System.Drawing.Point(20, 146)
    $lblRes.AutoSize = $true
    $form.Controls.Add($lblRes)

    $cmbRes = New-Object System.Windows.Forms.ComboBox
    $cmbRes.Location = New-Object System.Drawing.Point(20, 167)
    $cmbRes.Size = New-Object System.Drawing.Size(330, 26)
    $cmbRes.DropDownStyle = "DropDownList"
    $cmbRes.FlatStyle = "Flat"
    $cmbRes.BackColor = $clrPanel
    $cmbRes.ForeColor = $clrText
    [void]$cmbRes.Items.Add("7680 x 4320 — универсально, все мониторы")
    [void]$cmbRes.Items.Add("3840 x 2160 — 4K")
    [void]$cmbRes.Items.Add("2560 x 1440 — 2K")
    $cmbRes.SelectedIndex = 0
    $form.Controls.Add($cmbRes)

    # --- ЧТО ПАТЧИТЬ ---
    $lblWhat = New-Object System.Windows.Forms.Label
    $lblWhat.Text = "ЧТО ПАТЧИТЬ"
    $lblWhat.Font = $fontSmall
    $lblWhat.ForeColor = $clrMuted
    $lblWhat.Location = New-Object System.Drawing.Point(20, 203)
    $lblWhat.AutoSize = $true
    $form.Controls.Add($lblWhat)

    $chkRes = New-Object System.Windows.Forms.CheckBox
    $chkRes.Text = "Разблокировать разрешение (2K / 4K / 8K)"
    $chkRes.Location = New-Object System.Drawing.Point(20, 224)
    $chkRes.Size = New-Object System.Drawing.Size(520, 22)
    $chkRes.Checked = $true
    $chkRes.ForeColor = $clrText
    $chkRes.BackColor = $clrBack
    $chkRes.FlatStyle = "Flat"
    $chkRes.Add_CheckedChanged({ $cmbRes.Enabled = $chkRes.Checked })
    $form.Controls.Add($chkRes)

    $chkClick = New-Object System.Windows.Forms.CheckBox
    $chkClick.Text = "Исправить клик входа в игру (надёжный)"
    $chkClick.Location = New-Object System.Drawing.Point(20, 248)
    $chkClick.Size = New-Object System.Drawing.Size(520, 22)
    $chkClick.Checked = $true
    $chkClick.ForeColor = $clrText
    $chkClick.BackColor = $clrBack
    $chkClick.FlatStyle = "Flat"
    $form.Controls.Add($chkClick)

    $chkAuto = New-Object System.Windows.Forms.CheckBox
    $chkAuto.Text = "Автоспавн — сразу в бой без клика (DM, Team Elimination)"
    $chkAuto.Location = New-Object System.Drawing.Point(20, 272)
    $chkAuto.Size = New-Object System.Drawing.Size(520, 22)
    $chkAuto.Checked = $false
    $chkAuto.ForeColor = $clrText
    $chkAuto.BackColor = $clrBack
    $chkAuto.FlatStyle = "Flat"
    $form.Controls.Add($chkAuto)

    # --- Кнопки ---
    $btnPatch = New-Object System.Windows.Forms.Button
    $btnPatch.Text = "ПРИМЕНИТЬ ПАТЧ"
    $btnPatch.Location = New-Object System.Drawing.Point(20, 300)
    $btnPatch.Size = New-Object System.Drawing.Size(330, 46)
    $btnPatch.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $btnPatch.FlatStyle = "Flat"
    $btnPatch.FlatAppearance.BorderSize = 0
    $btnPatch.BackColor = $clrAccent
    $btnPatch.ForeColor = [System.Drawing.Color]::FromArgb(24, 26, 32)
    $btnPatch.Cursor = "Hand"
    $btnPatch.Add_MouseEnter({ if ($this.Enabled) { $this.BackColor = $clrAccentH } })
    $btnPatch.Add_MouseLeave({ $this.BackColor = $clrAccent })
    $form.Controls.Add($btnPatch)

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = "Откатить"
    $btnRestore.Location = New-Object System.Drawing.Point(365, 300)
    $btnRestore.Size = New-Object System.Drawing.Size(175, 46)
    $btnRestore.FlatStyle = "Flat"
    $btnRestore.FlatAppearance.BorderSize = 0
    $btnRestore.BackColor = $clrBtn2
    $btnRestore.ForeColor = $clrText
    $btnRestore.Cursor = "Hand"
    $btnRestore.Add_MouseEnter({ if ($this.Enabled) { $this.BackColor = $clrBtn2H } })
    $btnRestore.Add_MouseLeave({ $this.BackColor = $clrBtn2 })
    $form.Controls.Add($btnRestore)

    # --- Прогресс (кастомный, цветной) ---
    $lblProgress = New-Object System.Windows.Forms.Label
    $lblProgress.Text = ""
    $lblProgress.Font = $fontSmall
    $lblProgress.ForeColor = $clrMuted
    $lblProgress.Location = New-Object System.Drawing.Point(20, 360)
    $lblProgress.AutoSize = $true
    $form.Controls.Add($lblProgress)

    $pbTrack = New-Object System.Windows.Forms.Panel
    $pbTrack.Location = New-Object System.Drawing.Point(20, 382)
    $pbTrack.Size = New-Object System.Drawing.Size(520, 14)
    $pbTrack.BackColor = $clrPanel
    $form.Controls.Add($pbTrack)

    $pbFill = New-Object System.Windows.Forms.Panel
    $pbFill.Location = New-Object System.Drawing.Point(0, 0)
    $pbFill.Size = New-Object System.Drawing.Size(0, 14)
    $pbFill.BackColor = $clrAccent
    $pbTrack.Controls.Add($pbFill)

    function Set-ProgressPct($pct) {
        $pbFill.Width = [int]($pbTrack.Width * $pct / 100)
    }

    # --- Журнал ---
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Location = New-Object System.Drawing.Point(20, 408)
    $txtLog.Size = New-Object System.Drawing.Size(520, 118)
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = "Vertical"
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(16, 18, 22)
    $txtLog.ForeColor = $clrOk
    $txtLog.BorderStyle = "FixedSingle"
    $txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
    $form.Controls.Add($txtLog)

    function Add-Log($msg) {
        $txtLog.AppendText("$msg`r`n")
    }

    # --- Нижняя панель: копирование лога + контакт ---
    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = "Скопировать лог"
    $btnCopy.Location = New-Object System.Drawing.Point(20, 536)
    $btnCopy.Size = New-Object System.Drawing.Size(150, 30)
    $btnCopy.FlatStyle = "Flat"
    $btnCopy.FlatAppearance.BorderSize = 0
    $btnCopy.BackColor = $clrBtn2
    $btnCopy.ForeColor = $clrText
    $btnCopy.Cursor = "Hand"
    $btnCopy.Add_MouseEnter({ $this.BackColor = $clrBtn2H })
    $btnCopy.Add_MouseLeave({ $this.BackColor = $clrBtn2 })
    $btnCopy.Add_Click({
        if ($txtLog.Text.Trim()) {
            [System.Windows.Forms.Clipboard]::SetText($txtLog.Text)
            $lblCopied.Text = "Лог скопирован в буфер обмена"
        } else {
            $lblCopied.Text = "Лог пуст"
        }
    })
    $form.Controls.Add($btnCopy)

    $btnDiag = New-Object System.Windows.Forms.Button
    $btnDiag.Text = "Диагностика"
    $btnDiag.Location = New-Object System.Drawing.Point(178, 536)
    $btnDiag.Size = New-Object System.Drawing.Size(120, 30)
    $btnDiag.FlatStyle = "Flat"
    $btnDiag.FlatAppearance.BorderSize = 0
    $btnDiag.BackColor = $clrBtn2
    $btnDiag.ForeColor = $clrText
    $btnDiag.Cursor = "Hand"
    $btnDiag.Add_MouseEnter({ $this.BackColor = $clrBtn2H })
    $btnDiag.Add_MouseLeave({ $this.BackColor = $clrBtn2 })
    $form.Controls.Add($btnDiag)

    $lblCopied = New-Object System.Windows.Forms.Label
    $lblCopied.Text = ""
    $lblCopied.Font = $fontSmall
    $lblCopied.ForeColor = $clrOk
    $lblCopied.Location = New-Object System.Drawing.Point(306, 543)
    $lblCopied.AutoSize = $true
    $form.Controls.Add($lblCopied)

    # --- Контакт для обращений ---
    $lblContactPre = New-Object System.Windows.Forms.Label
    $lblContactPre.Text = "Ошибка? Скопируйте лог и напишите:"
    $lblContactPre.Font = $fontSmall
    $lblContactPre.ForeColor = $clrMuted
    $lblContactPre.Location = New-Object System.Drawing.Point(20, 580)
    $lblContactPre.AutoSize = $true
    $form.Controls.Add($lblContactPre)

    $lnkTg = New-Object System.Windows.Forms.LinkLabel
    $lnkTg.Text = "t.me/Moxy1337"
    $lnkTg.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $lnkTg.LinkColor = $clrAccent
    $lnkTg.ActiveLinkColor = $clrAccentH
    $lnkTg.Location = New-Object System.Drawing.Point(232, 580)
    $lnkTg.AutoSize = $true
    $lnkTg.Add_LinkClicked({ Start-Process "https://t.me/Moxy1337" })
    $form.Controls.Add($lnkTg)

    function Get-DllFromForm {
        $p = $txtPath.Text.Trim()
        if (-not $p) { Add-Log "[!] Укажите папку игры."; return $null }
        $dll = Find-GameDll -Hint $p
        if (-not $dll) { Add-Log "[!] Assembly-CSharp.dll не найдена в '$p'. Выберите папку, где лежит CWClient.exe."; return $null }
        return $dll
    }

    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Выберите папку игры (где лежит CWClient.exe)"
        if ($txtPath.Text -and (Test-Path $txtPath.Text)) { $dlg.SelectedPath = $txtPath.Text }
        if ($dlg.ShowDialog($form) -eq "OK") { $txtPath.Text = $dlg.SelectedPath }
    })

    $btnPatch.Add_Click({
        $dll = Get-DllFromForm
        if (-not $dll) { return }
        if (-not ($chkRes.Checked -or $chkClick.Checked -or $chkAuto.Checked)) {
            Add-Log "[!] Не выбран ни один патч. Отметьте галочку в разделе «Что патчить»."
            return
        }
        $w, $h = switch ($cmbRes.SelectedIndex) {
            1 { 3840, 2160 }
            2 { 2560, 1440 }
            default { 7680, 4320 }
        }
        Add-Log "[*] DLL: $dll"
        $btnPatch.Enabled = $false; $btnRestore.Enabled = $false; $btnBrowse.Enabled = $false
        $lblProgress.ForeColor = $clrMuted
        Set-ProgressPct 0
        $applied = @()
        $hadError = $false
        try {
            # Единый бэкап до первого патча
            $backup = "$dll.orig.bak"
            if (-not (Test-Path $backup)) {
                Copy-Item $dll $backup
                Add-Log "[+] Бэкап сохранён: $backup"
            }

            # 1) Разрешение — чисто байтовый патч (файл пишем сразу, dnlib не держим)
            if ($chkRes.Checked) {
                $lblProgress.Text = "Разрешение: сканирование DLL..."
                $bytes = [IO.File]::ReadAllBytes($dll)
                $r = Invoke-CWResolution -bytes $bytes -W $w -H $h -OnProgress {
                    param($pct)
                    Set-ProgressPct $pct
                    $lblProgress.Text = "Разрешение: $pct%"
                    [System.Windows.Forms.Application]::DoEvents()
                }
                if ($r.ok) {
                    [IO.File]::WriteAllBytes($dll, $bytes)
                    Add-Log "[+] $($r.msg)"
                    $applied += "разрешение ${w}x${h}"
                } else {
                    $hadError = $true
                    Add-Log "[!] $($r.msg)"
                }
            }

            # 2) Клик и/или автоспавн — через dnlib (переоткрываем файл)
            if ($chkClick.Checked -or $chkAuto.Checked) {
                $dnlibOk = $false
                try {
                    Load-Dnlib $cwScriptDir
                    $dnlibOk = $true
                } catch {
                    $hadError = $true
                    Add-Log "[!] Для клика/автоспавна нужна dnlib.dll рядом с патчером."
                    Add-Log "    ($($_.Exception.Message))"
                }
                if ($dnlibOk) {
                    $lblProgress.Text = "Клик / автоспавн: разбор сборки..."
                    [System.Windows.Forms.Application]::DoEvents()
                    $mod = $null
                    try {
                        $mod = [dnlib.DotNet.ModuleDefMD]::Load($dll)
                        $bytes = [IO.File]::ReadAllBytes($dll)
                        $changed = $false
                        if ($chkClick.Checked) {
                            $rc = Invoke-CWClickFix -mod $mod -bytes $bytes
                            if ($rc.ok) { Add-Log "[+] $($rc.msg)"; $applied += "клик входа"; $changed = $true }
                            else { $hadError = $true; Add-Log "[!] $($rc.msg)" }
                        }
                        if ($chkAuto.Checked) {
                            $ra = Invoke-CWAutospawn -mod $mod -bytes $bytes
                            if ($ra.ok) { Add-Log "[+] $($ra.msg)"; $applied += "автоспавн"; $changed = $true }
                            else { $hadError = $true; Add-Log "[!] $($ra.msg)" }
                        }
                        if ($mod) { $mod.Dispose(); $mod = $null }
                        if ($changed) { [IO.File]::WriteAllBytes($dll, $bytes) }
                    } catch {
                        $hadError = $true
                        Add-Log "[!] Ошибка клика/автоспавна: $($_.Exception.Message)"
                    } finally {
                        if ($mod) { $mod.Dispose() }
                    }
                }
            }

            Set-ProgressPct 100
            if ($applied.Count -gt 0) {
                $lblProgress.Text = "Готово!"
                $lblProgress.ForeColor = $clrOk
                Add-Log "[+] Готово! Применено: $($applied -join ', ')."
            } else {
                $lblProgress.Text = "Ничего не применено."
                $lblProgress.ForeColor = [System.Drawing.Color]::FromArgb(235, 100, 100)
                Set-ProgressPct 0
            }
        } catch {
            $lblProgress.Text = "Ошибка."
            $lblProgress.ForeColor = [System.Drawing.Color]::FromArgb(235, 100, 100)
            Set-ProgressPct 0
            Add-Log "[!] Ошибка: $($_.Exception.Message)"
        } finally {
            $btnPatch.Enabled = $true; $btnRestore.Enabled = $true; $btnBrowse.Enabled = $true
        }
    })

    $btnRestore.Add_Click({
        $dll = Get-DllFromForm
        if (-not $dll) { return }
        try {
            $r = Invoke-CWRestore -Dll $dll
            if ($r.ok) { Add-Log "[+] $($r.message)" } else { Add-Log "[!] $($r.message)" }
        } catch {
            Add-Log "[!] Ошибка: $($_.Exception.Message)"
        }
    })

    $btnDiag.Add_Click({
        $dll = Get-DllFromForm
        if (-not $dll) { return }
        try {
            $diag = Get-CWDiagnostics -Dll $dll
            Add-Log "[*] === ДИАГНОСТИКА (скопируйте лог и пришлите в Telegram) ==="
            Add-Log $diag
            [System.Windows.Forms.Clipboard]::SetText($txtLog.Text)
            $lblCopied.Text = "Диагностика готова и скопирована"
        } catch {
            Add-Log "[!] Ошибка диагностики: $($_.Exception.Message)"
        }
    })

    # Авто-поиск игры при открытии окна
    $autoDll = Find-GameDll -Hint $GamePath
    if ($autoDll) {
        $txtPath.Text = (Get-Item $autoDll).Directory.Parent.Parent.FullName
        Add-Log "[*] Игра найдена автоматически: $($txtPath.Text)"
    } else {
        Add-Log "[*] Игра не найдена автоматически — укажите папку кнопкой «Обзор...»."
    }

    [void]$form.ShowDialog()
    exit 0
}

# ============================ Консольный режим ============================
$dll = Find-GameDll -Hint $GamePath
if (-not $dll) {
    Write-Host "[!] Assembly-CSharp.dll не найдена. Укажите папку игры: .\Patch-CWResolution.ps1 -GamePath `"C:\Games\CWClient`"" -ForegroundColor Red
    exit 1
}
Write-Host "[*] Найдена DLL: $dll"

if ($Restore) {
    $r = Invoke-CWRestore -Dll $dll
} else {
    $r = Invoke-CWPatch -Dll $dll -W $MaxWidth -H $MaxHeight -OnProgress {
        param($pct)
        Write-Progress -Activity "Применение патча" -Status "$pct%" -PercentComplete $pct
    }
    Write-Progress -Activity "Применение патча" -Completed
}
if ($r.ok) {
    Write-Host "[+] $($r.message)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "[!] $($r.message)" -ForegroundColor Red
    exit 1
}
