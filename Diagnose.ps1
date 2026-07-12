# Диагностика: показывает участки Assembly-CSharp.dll, относящиеся к фильтру разрешений.
# Отправьте вывод разработчику патча, если основной скрипт пишет "A=1, B=0".
param([string]$GamePath = "")

function Find-GameDll {
    param([string]$Hint)
    $c = @()
    if ($Hint) { $c += $Hint }
    $c += (Get-Location).Path; $c += $PSScriptRoot; $c += "C:\Games\CWClient"
    foreach ($d in $c) {
        if (-not $d) { continue }
        foreach ($rel in @("CWClient_Data\Managed\Assembly-CSharp.dll","Managed\Assembly-CSharp.dll","Assembly-CSharp.dll")) {
            $p = Join-Path $d $rel; if (Test-Path $p) { return $p }
        }
    }
    return $null
}

$dll = Find-GameDll -Hint $GamePath
if (-not $dll) { Write-Host "DLL не найдена. Запустите: .\Diagnose.ps1 -GamePath `"C:\Games\CWClient`""; exit 1 }
Write-Host "DLL: $dll"
$b = [IO.File]::ReadAllBytes($dll)
Write-Host "Размер: $($b.Length) байт`n"

# Ищем все ldc.i4 <int> со значением 800, 1024..8192, 1920 — вероятные пороги разрешения.
Write-Host "=== Кандидаты (ldc.i4 со значением-разрешением и байты вокруг) ==="
$targets = @(800, 1280, 1360, 1366, 1440, 1600, 1680, 1920, 2048, 2560, 3840, 7680)
for ($i = 8; $i -le $b.Length - 10; $i++) {
    if ($b[$i] -ne 0x20) { continue }
    $v = [BitConverter]::ToInt32($b, $i + 1)
    if ($targets -notcontains $v) { continue }
    $next = $b[$i + 5]
    # интересуют только те, за которыми идёт условный переход (bgt/blt/ble/bge .un = 3D/3F/3E/41 и short-формы)
    if ($next -notin @(0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x2C, 0x2D, 0x30, 0x31, 0x32, 0x33)) { continue }
    $from = [Math]::Max(0, $i - 12); $to = [Math]::Min($b.Length - 1, $i + 9)
    $hex = ($b[$from..$to] | ForEach-Object { "{0:X2}" -f $_ }) -join ' '
    Write-Host ("off=0x{0:X}  val={1}  jmp=0x{2:X2}  :: {3}" -f $i, $v, $next, $hex)
}
Write-Host "`nСкопируйте весь вывод выше и отправьте разработчику."
