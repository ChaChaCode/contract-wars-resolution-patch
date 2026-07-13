# Launch-Borderless.ps1 — запускает Contract Wars в режиме ОКНА БЕЗ РАМКИ (borderless)
# на весь монитор. Использует встроенный флаг движка Unity -popupwindow + оконный режим.
# НЕ модифицирует код игры — только способ запуска. Окно не сворачивается при клике на
# другой монитор (удобно для нескольких мониторов).
param(
    [int]$Monitor = 1,
    [string]$GamePath = ""
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

# --- найти игру ---
function Find-GameExe($hint) {
    $cands = @()
    if ($hint) { $cands += $hint }
    $cands += Split-Path -Parent $PSScriptRoot   # engine\.. = папка игры, если патч внутри
    $cands += "C:\Games\CWClient"
    $cands += "C:\Program Files (x86)\CWClient"
    foreach ($c in $cands) {
        if (-not $c) { continue }
        $exe = Join-Path $c "CWClient.exe"
        if (Test-Path $exe) { return $exe }
    }
    return $null
}
$exe = Find-GameExe $GamePath
if (-not $exe) {
    [System.Windows.Forms.MessageBox]::Show("CWClient.exe не найден. Положите патч в папку игры или укажите путь.", "Borderless", "OK", "Error") | Out-Null
    exit 1
}

# --- выбрать монитор ---
$screens = [System.Windows.Forms.Screen]::AllScreens
if ($Monitor -lt 1 -or $Monitor -gt $screens.Count) { $scr = [System.Windows.Forms.Screen]::PrimaryScreen }
else { $scr = $screens[$Monitor - 1] }
$w = $scr.Bounds.Width
$h = $scr.Bounds.Height

# --- прописать оконный режим в реестр Unity (иначе игра стартует в fullscreen) ---
$key = "HKCU:\Software\Absolutsoft\Contract Wars"
if (Test-Path $key) {
    Set-ItemProperty $key -Name "Screenmanager Is Fullscreen mode_h3981298716" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty $key -Name "Screenmanager Resolution Width_h182942802"  -Value $w -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty $key -Name "Screenmanager Resolution Height_h2627697771" -Value $h -Type DWord -ErrorAction SilentlyContinue
}

# --- запуск с borderless-флагом движка Unity ---
# ВАЖНО: рабочая директория ДОЛЖНА быть папкой игры (лаунчер делает так же через
# Directory.GetCurrentDirectory()). Иначе игра не находит данные и профиль не грузится.
# -popupwindow: окно без рамки (borderless) на уровне движка. -force-gfx-st: как в лаунчере.
$gameDir = Split-Path -Parent $exe
Start-Process $exe -WorkingDirectory $gameDir -ArgumentList "-force-gfx-st","-popupwindow","-screen-fullscreen","0","-screen-width","$w","-screen-height","$h"
