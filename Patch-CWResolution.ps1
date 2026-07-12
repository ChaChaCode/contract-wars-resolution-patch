# Contract Wars Resolution Unlock Patch
# Снимает ограничение разрешения 1920x1080 в клиенте Contract Wars (CWClient).
# Removes the 1920x1080 resolution cap in the Contract Wars client (CWClient).
#
# Использование / Usage:
#   PATCH.bat                                         # графическое окно (GUI)
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
    $candidates += $PSScriptRoot
    $candidates += "C:\Games\CWClient"
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

# --- Паттерн B: фильтр списка разрешений в меню настроек (SettingsGUI) ---
# IL: ... call Resolution.get_width; ldc.i4 W; bgt +16  (перед этим в пределах 48 байт есть ldc.i4 800)
function Test-PatternB($b, $j) {
    if (-not ($b[$j] -eq 0x20 -and $b[$j+5] -eq 0x3D -and $b[$j+6] -eq 0x16 -and $b[$j+7] -eq 0 -and $b[$j+8] -eq 0 -and $b[$j+9] -eq 0 -and
              $b[$j-5] -eq 0x28 -and $b[$j-1] -eq 0x0A)) { return $false }
    for ($k = [Math]::Max(0, $j-48); $k -lt $j; $k++) {
        if ($b[$k] -eq 0x20 -and $b[$k+1] -eq 0x20 -and $b[$k+2] -eq 0x03 -and $b[$k+3] -eq 0 -and $b[$k+4] -eq 0) { return $true }
    }
    return $false
}

function Write-Int32($b, $pos, $val) {
    $le = [BitConverter]::GetBytes([int]$val)
    for ($n = 0; $n -lt 4; $n++) { $b[$pos + $n] = $le[$n] }
}

# Применяет патч. Возвращает @{ ok = $true/$false; message = "..." }
function Invoke-CWPatch {
    param([string]$Dll, [int]$W, [int]$H)
    if ($W -lt 800 -or $W -gt 16384 -or $H -lt 600 -or $H -gt 16384) {
        return @{ ok = $false; message = "Недопустимые значения ширины/высоты." }
    }
    $bytes = [IO.File]::ReadAllBytes($Dll)
    $hitsA = @(); $hitsB = @()
    for ($i = 5; $i -le $bytes.Length - 41; $i++) {
        if (Test-PatternA $bytes $i) { $hitsA += $i }
        if (Test-PatternB $bytes $i) { $hitsB += $i }
    }
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
    return @{ ok = $true; message = "${backupMsg}Патч применён! Новый потолок: ${W}x${H}.`r`nЗапустите игру через CWClient.exe (НЕ через лаунчер) и выберите разрешение в настройках игры." }
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

# ============================ GUI ============================
if ($GUI) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Contract Wars — Resolution Unlock"
    $form.Size = New-Object System.Drawing.Size(560, 420)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = "Папка игры (где лежит CWClient.exe):"
    $lblPath.Location = New-Object System.Drawing.Point(15, 15)
    $lblPath.AutoSize = $true
    $form.Controls.Add($lblPath)

    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(15, 38)
    $txtPath.Size = New-Object System.Drawing.Size(430, 24)
    $form.Controls.Add($txtPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "Обзор..."
    $btnBrowse.Location = New-Object System.Drawing.Point(455, 36)
    $btnBrowse.Size = New-Object System.Drawing.Size(75, 26)
    $form.Controls.Add($btnBrowse)

    $lblRes = New-Object System.Windows.Forms.Label
    $lblRes.Text = "Максимальное разрешение (потолок):"
    $lblRes.Location = New-Object System.Drawing.Point(15, 75)
    $lblRes.AutoSize = $true
    $form.Controls.Add($lblRes)

    $cmbRes = New-Object System.Windows.Forms.ComboBox
    $cmbRes.Location = New-Object System.Drawing.Point(15, 98)
    $cmbRes.Size = New-Object System.Drawing.Size(300, 24)
    $cmbRes.DropDownStyle = "DropDownList"
    [void]$cmbRes.Items.Add("7680 x 4320 — универсально, все мониторы")
    [void]$cmbRes.Items.Add("3840 x 2160 — 4K")
    [void]$cmbRes.Items.Add("2560 x 1440 — 2K")
    $cmbRes.SelectedIndex = 0
    $form.Controls.Add($cmbRes)

    $btnPatch = New-Object System.Windows.Forms.Button
    $btnPatch.Text = "ПРИМЕНИТЬ ПАТЧ"
    $btnPatch.Location = New-Object System.Drawing.Point(15, 140)
    $btnPatch.Size = New-Object System.Drawing.Size(250, 40)
    $btnPatch.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnPatch)

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = "Откатить патч"
    $btnRestore.Location = New-Object System.Drawing.Point(280, 140)
    $btnRestore.Size = New-Object System.Drawing.Size(250, 40)
    $form.Controls.Add($btnRestore)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Location = New-Object System.Drawing.Point(15, 195)
    $txtLog.Size = New-Object System.Drawing.Size(515, 175)
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = "Vertical"
    $form.Controls.Add($txtLog)

    function Add-Log($msg) {
        $txtLog.AppendText("$msg`r`n")
    }

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
        $w, $h = switch ($cmbRes.SelectedIndex) {
            1 { 3840, 2160 }
            2 { 2560, 1440 }
            default { 7680, 4320 }
        }
        Add-Log "[*] DLL: $dll"
        try {
            $r = Invoke-CWPatch -Dll $dll -W $w -H $h
            if ($r.ok) { Add-Log "[+] $($r.message)" } else { Add-Log "[!] $($r.message)" }
        } catch {
            Add-Log "[!] Ошибка: $($_.Exception.Message)"
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
    $r = Invoke-CWPatch -Dll $dll -W $MaxWidth -H $MaxHeight
}
if ($r.ok) {
    Write-Host "[+] $($r.message)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "[!] $($r.message)" -ForegroundColor Red
    exit 1
}
