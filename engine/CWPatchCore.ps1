# CWPatchCore.ps1 — общие функции патчей Contract Wars.
# Патч разрешения — чистая байтовая правка (без зависимостей).
# Патчи клика и автоспавна — через dnlib (поиск по именам методов, устойчиво к сборкам).
#
# Требуется: dnlib.dll рядом со скриптом (для клика/автоспавна).

# ---------- РАЗРЕШЕНИЕ (байтовый патч, без dnlib) ----------
function Test-PatternA($b, $i) {
    return ($b[$i] -eq 0x20 -and $b[$i+5] -eq 0x3D -and $b[$i+6] -eq 0x0F -and $b[$i+7] -eq 0 -and $b[$i+8] -eq 0 -and $b[$i+9] -eq 0 -and
            $b[$i+10] -eq 0x28 -and $b[$i+13] -eq 0 -and $b[$i+14] -eq 0x0A -and
            $b[$i+15] -eq 0x20 -and $b[$i+20] -eq 0x3E -and $b[$i+21] -eq 0x14 -and $b[$i+22] -eq 0 -and $b[$i+23] -eq 0 -and $b[$i+24] -eq 0 -and
            $b[$i+25] -eq 0x20 -and $b[$i+30] -eq 0x20 -and
            $b[$i+35] -eq 0x28 -and $b[$i+38] -eq 0 -and $b[$i+39] -eq 0x0A)
}
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
function Invoke-CWResolution {
    param([byte[]]$bytes, [int]$W, [int]$H, [scriptblock]$OnProgress = $null)
    $hitsA = @(); $hitsB = @()
    $total = $bytes.Length - 41
    $step = [Math]::Max(1, [int]($total / 100))
    for ($i = 5; $i -le $total; $i++) {
        if ($OnProgress -and ($i % $step) -eq 0) { & $OnProgress ([int](100 * $i / $total)) }
        if ($bytes[$i] -ne 0x20) { continue }
        if (Test-PatternA $bytes $i) { $hitsA += $i }
        if (Test-PatternB $bytes $i) { $hitsB += $i }
    }
    if ($hitsA.Count -ne 1 -or $hitsB.Count -ne 1) {
        return @{ ok=$false; msg="Разрешение: участки не найдены однозначно (A=$($hitsA.Count), B=$($hitsB.Count))." }
    }
    $a = $hitsA[0]; $bOff = $hitsB[0]
    $le = [BitConverter]::GetBytes([int]$W); for($n=0;$n -lt 4;$n++){ $bytes[$a+1+$n]=$le[$n]; $bytes[$a+26+$n]=$le[$n]; $bytes[$bOff+1+$n]=$le[$n] }
    $le = [BitConverter]::GetBytes([int]$H); for($n=0;$n -lt 4;$n++){ $bytes[$a+16+$n]=$le[$n]; $bytes[$a+31+$n]=$le[$n] }
    return @{ ok=$true; msg="Разрешение разблокировано (потолок ${W}x${H})." }
}

# ---------- dnlib helpers ----------
function Load-Dnlib($scriptDir) {
    $dn = Join-Path $scriptDir "dnlib.dll"
    if (-not (Test-Path $dn)) { throw "dnlib.dll не найдена рядом со скриптом ($dn)" }
    # Windows помечает скачанные из интернета файлы (Zone.Identifier), из-за чего .NET
    # отказывается загружать сборку (HRESULT 0x80131515). Снимаем метку со всех файлов патчера.
    try { Get-ChildItem -Path $scriptDir -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch { }
    Add-Type -Path $dn
}
function Get-InputMemberRef($mod, $name) {
    foreach ($mr in $mod.GetMemberRefs()) {
        if ($mr.DeclaringType -and $mr.DeclaringType.Name -eq "Input" -and $mr.Name -eq $name) { return $mr }
    }
    return $null
}
function Get-ILStart($mod, $method, $bytes) {
    $foff = [uint32]$mod.Metadata.PEImage.ToFileOffset($method.RVA)
    $hdr = $bytes[$foff]
    if (($hdr -band 0x3) -eq 0x2) { return $foff + 1 } else { return $foff + 12 }
}
function Write-Token([byte[]]$bytes, [int]$off, [uint32]$token) {
    $le = [BitConverter]::GetBytes($token); for($n=0;$n -lt 4;$n++){ $bytes[$off+$n]=$le[$n] }
}

# ---------- КЛИК «READY!» (LoadingGUI): GetMouseButtonDown -> GetMouseButton ----------
function Invoke-CWClickFix {
    param($mod, [byte[]]$bytes)
    $t = $mod.Find("LoadingGUI", $true)
    if (-not $t) { return @{ ok=$false; msg="Клик: класс LoadingGUI не найден." } }
    $m = $t.Methods | Where-Object { $_.Name -eq "GameGUI" }
    if (-not $m -or -not $m.Body) { return @{ ok=$false; msg="Клик: метод GameGUI не найден." } }
    $inst = $m.Body.Instructions
    $idx = -1
    for ($i=0;$i -lt $inst.Count;$i++){
        if ($inst[$i].OpCode.Name -eq "call" -and $inst[$i].Operand -and $inst[$i].Operand.Name -eq "GetMouseButtonDown") {
            for ($k=$i+1;$k -le [Math]::Min($i+4,$inst.Count-1);$k++){ if ($inst[$k].Operand -and $inst[$k].Operand.Name -eq "get_MaxVisible") { $idx=$i; break } }
        }
        if ($idx -ge 0) { break }
    }
    if ($idx -lt 0) { return @{ ok=$false; msg="Клик: место (GetMouseButtonDown+MaxVisible) не найдено." } }
    $gmb = Get-InputMemberRef $mod "GetMouseButton"
    if (-not $gmb) { return @{ ok=$false; msg="Клик: GetMouseButton не импортирован в сборку." } }
    $ilStart = Get-ILStart $mod $m $bytes
    $tokOff = $ilStart + $inst[$idx].Offset + 1
    Write-Token $bytes $tokOff ([uint32]$gmb.MDToken.Raw)
    return @{ ok=$true; msg="Клик входа сделан надёжным." }
}

# ---------- АВТОСПАВН: клик входа Mouse0 всегда истинный ----------
# Применимо к режимам, где вход в бой идёт кликом ЛКМ (Mouse0):
#   DMSpawn (Deathmatch), TESpawn (Team Elimination).
# TCSpawn/TDSSpawn используют выбор точки/команды — там клика входа нет, не трогаем.
# Защитные условия (мёртв/спектатор, таймер спавна, выбор команды) остаются в самом коде,
# патч лишь делает «клик» всегда истинным, поэтому спавн происходит автоматически.
function Invoke-CWAutospawn {
    param($mod, [byte[]]$bytes)
    $done = 0; $modes = @{ DMSpawn="Deathmatch"; TESpawn="Team Elimination" }
    $patched = @()
    foreach ($cls in @("DMSpawn","TESpawn")) {
        $t = $mod.Find("SpectatorGUInamespace.$cls", $true)
        if (-not $t) { continue }
        $m = $t.Methods | Where-Object { $_.Name -eq "OnUpdate" }
        if (-not $m -or -not $m.Body) { continue }
        $inst = $m.Body.Instructions
        # ищем клик входа: ldc.i4 323 (Mouse0) ; call GetKeyDown/GetKey ; за которым brtrue
        $idx = -1
        for ($i=1;$i -lt $inst.Count-1;$i++){
            if ($inst[$i].OpCode.Name -eq "call" -and $inst[$i].Operand -and
                ($inst[$i].Operand.Name -eq "GetKeyDown" -or $inst[$i].Operand.Name -eq "GetKey") -and
                "$($inst[$i-1].Operand)" -eq "323" -and
                $inst[$i+1].OpCode.Name -eq "brtrue") { $idx=$i; break }
        }
        if ($idx -lt 0) { continue }
        # заменяем [ldc.i4 323][call] на ldc.i4.1 + NOP-ы (до начала brtrue)
        $ilStart = Get-ILStart $mod $m $bytes
        $offLdc = $ilStart + $inst[$idx-1].Offset
        $offNext = $ilStart + $inst[$idx+1].Offset
        $len = $offNext - $offLdc
        $bytes[$offLdc] = 0x17
        for ($k=1;$k -lt $len;$k++){ $bytes[$offLdc+$k] = 0x00 }
        $done++; $patched += $modes[$cls]
    }
    if ($done -eq 0) { return @{ ok=$false; msg="Автоспавн: места клика спавна не найдены." } }
    return @{ ok=$true; msg="Автоспавн включён: $($patched -join ', '). Вход в бой без клика (в командных — после выбора стороны). Tactical Conquest / Target Designation используют выбор точки — не затронуты." }
}

# ---------- FOV: базовый угол обзора «от бедра» ----------
# В ClientAmmunitions.CallLateUpdate ветка «не прицеливаюсь» задаёт nowCamFov = 60f.
# Ищем literal 60, за которым идёт stfld nowCamFov, БЕЗ вычитания worldAimFov (то есть чистое
# присвоение — ветка «от бедра»). ADS-ветки (60 - worldAimFov) не трогаем — прицел сохраняется.
# Также правим сброс fov=60 (ldc.r4 60 ; call set_fov) для консистентности.
function Invoke-CWFov {
    param($mod, [byte[]]$bytes, [int]$Fov)
    if ($Fov -lt 60 -or $Fov -gt 140) { return @{ ok=$false; msg="FOV вне диапазона 60..140." } }
    $t = $mod.Find("ClientAmmunitions", $true)
    if (-not $t) { return @{ ok=$false; msg="FOV: класс ClientAmmunitions не найден." } }
    $le = [BitConverter]::GetBytes([float]$Fov)
    $done = 0
    foreach ($m in $t.Methods) {
        if (-not $m.HasBody) { continue }
        $inst = $m.Body.Instructions
        $ilStart = Get-ILStart $mod $m $bytes
        for ($i=0; $i -lt $inst.Count-1; $i++) {
            if ($inst[$i].OpCode.Name -ne "ldc.r4") { continue }
            $val = [float]$inst[$i].Operand
            if ($val -ne 60.0) { continue }
            $next = $inst[$i+1]
            $isHipFov = ($next.OpCode.Name -eq "stfld" -and "$($next.Operand)" -match "nowCamFov")
            $isReset  = (($next.OpCode.Name -eq "callvirt" -or $next.OpCode.Name -eq "call") -and "$($next.Operand)" -match "set_fov")
            if (-not ($isHipFov -or $isReset)) { continue }
            $off = $ilStart + $inst[$i].Offset + 1   # +1: пропускаем opcode 0x22, дальше 4 байта float
            for ($n=0; $n -lt 4; $n++) { $bytes[$off+$n] = $le[$n] }
            $done++
        }
    }
    if ($done -eq 0) { return @{ ok=$false; msg="FOV: место (nowCamFov=60) не найдено." } }
    return @{ ok=$true; msg="FOV изменён на ${Fov}° (обзор от бедра). Прицеливание не затронуто." }
}
