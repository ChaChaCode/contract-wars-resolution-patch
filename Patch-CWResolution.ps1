# Contract Wars Resolution Unlock Patch
# Снимает ограничение разрешения 1920x1080 в клиенте Contract Wars (CWClient).
# Removes the 1920x1080 resolution cap in the Contract Wars client (CWClient).
#
# Использование / Usage:
#   .\Patch-CWResolution.ps1                          # авто-поиск игры, потолок 7680x4320
#   .\Patch-CWResolution.ps1 -GamePath "D:\CWClient"  # указать папку игры
#   .\Patch-CWResolution.ps1 -Restore                 # откатить патч из бэкапа

param(
    [string]$GamePath = "",
    [int]$MaxWidth  = 7680,
    [int]$MaxHeight = 4320,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"

function Find-GameDll {
    param([string]$Hint)
    $candidates = @()
    if ($Hint) { $candidates += $Hint }
    $candidates += (Get-Location).Path
    $candidates += Split-Path -Parent $MyInvocation.PSCommandPath
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

$dll = Find-GameDll -Hint $GamePath
if (-not $dll) {
    Write-Host "[!] Assembly-CSharp.dll не найдена. Укажите папку игры: .\Patch-CWResolution.ps1 -GamePath `"C:\Games\CWClient`"" -ForegroundColor Red
    exit 1
}
Write-Host "[*] Найдена DLL: $dll"

$backup = "$dll.orig.bak"

if ($Restore) {
    if (-not (Test-Path $backup)) { Write-Host "[!] Бэкап не найден: $backup" -ForegroundColor Red; exit 1 }
    Copy-Item $backup $dll -Force
    Write-Host "[+] Оригинальная DLL восстановлена из бэкапа." -ForegroundColor Green
    exit 0
}

if ($MaxWidth -lt 800 -or $MaxWidth -gt 16384 -or $MaxHeight -lt 600 -or $MaxHeight -gt 16384) {
    Write-Host "[!] Недопустимые значения MaxWidth/MaxHeight." -ForegroundColor Red
    exit 1
}

$bytes = [IO.File]::ReadAllBytes($dll)

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

$hitsA = @(); $hitsB = @()
for ($i = 5; $i -le $bytes.Length - 41; $i++) {
    if (Test-PatternA $bytes $i) { $hitsA += $i }
    if (Test-PatternB $bytes $i) { $hitsB += $i }
}

if ($hitsA.Count -ne 1 -or $hitsB.Count -ne 1) {
    Write-Host "[!] Ожидаемые участки кода не найдены однозначно (A=$($hitsA.Count), B=$($hitsB.Count))." -ForegroundColor Red
    Write-Host "    Возможно, версия клиента отличается. Патч не применён, файл не изменён." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $backup)) {
    Copy-Item $dll $backup
    Write-Host "[*] Бэкап сохранён: $backup"
}

function Write-Int32($b, $pos, $val) {
    $le = [BitConverter]::GetBytes([int]$val)
    for ($n = 0; $n -lt 4; $n++) { $b[$pos + $n] = $le[$n] }
}

$a = $hitsA[0]; $bOff = $hitsB[0]
Write-Int32 $bytes ($a + 1)  $MaxWidth   # FixResolution: порог ширины
Write-Int32 $bytes ($a + 16) $MaxHeight  # FixResolution: порог высоты
Write-Int32 $bytes ($a + 26) $MaxWidth   # FixResolution: аргумент SetResolution width
Write-Int32 $bytes ($a + 31) $MaxHeight  # FixResolution: аргумент SetResolution height
Write-Int32 $bytes ($bOff + 1) $MaxWidth # SettingsGUI: потолок списка разрешений

[IO.File]::WriteAllBytes($dll, $bytes)
Write-Host "[+] Патч применён! Новый потолок: ${MaxWidth}x${MaxHeight}" -ForegroundColor Green
Write-Host "    Запустите игру через CWClient.exe (НЕ через лаунчер — он может откатить файл),"
Write-Host "    зайдите в настройки игры и выберите нужное разрешение в списке."
