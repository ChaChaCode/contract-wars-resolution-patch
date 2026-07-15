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

# ---------- ОТКЛЮЧЕНИЕ ТРЯСКИ КАМЕРЫ ПРИ ДВИЖЕНИИ (Bober / view bobbing) ----------
# Класс Bober отвечает за покачивание камеры при ходьбе (используется только в
# ClientMoveController.CallLateUpdate для визуала). Три метода дают визуальный выход:
#   Update()     -> пишет Bober.rotation (наклон камеры)
#   Position1()  -> смещение позиции камеры (Vector3)
#   Position2()  -> смещение позиции камеры (Vector3)
# Обнуляем ВЫХОД этих методов (rotation = identity, позиции = Vector3.zero),
# не трогая шаги/звук (AdvanceStep/NextStep/sum/step остаются нетронутыми).
# Принимает путь к Assembly-CSharp.dll, ВОЗВРАЩАЕТ новые байты (@{ ok; bytes; msg }).
function Invoke-CWNoBob {
    param([string]$DllPath)
    if (-not (Test-Path $DllPath)) { return @{ ok=$false; msg="NoBob: DLL не найдена: $DllPath" } }
    $mod = [dnlib.DotNet.ModuleDefMD]::Load([IO.File]::ReadAllBytes($DllPath))
    try {
        $t = $mod.Find("Bober", $true)
        if (-not $t) { return @{ ok=$false; msg="Тряска: класс Bober не найден (ничего не изменено)." } }
        $Op = [dnlib.DotNet.Emit.OpCodes]

        # переиспользуем уже существующие в модуле ссылки:
        #   Vector3::get_zero () и Quaternion::get_identity ()
        $getZero = $null; $getIdentity = $null
        foreach ($mr in $mod.GetMemberRefs()) {
            if (-not $mr.DeclaringType) { continue }
            if (-not $getZero     -and $mr.DeclaringType.Name -eq "Vector3"    -and $mr.Name -eq "get_zero")     { $getZero = $mr }
            if (-not $getIdentity -and $mr.DeclaringType.Name -eq "Quaternion" -and $mr.Name -eq "get_identity") { $getIdentity = $mr }
        }
        if (-not $getZero -or -not $getIdentity) { return @{ ok=$false; msg="Тряска: ссылки Vector3.zero/Quaternion.identity не найдены." } }

        $done = @()

        # --- Position1 / Position2: тело -> return Vector3.zero ---
        foreach ($name in @("Position1","Position2")) {
            $m = $t.Methods | Where-Object { $_.Name -eq $name -and $_.HasBody }
            if ($m) {
                $m.Body.ExceptionHandlers.Clear()
                $m.Body.Variables.Clear()
                $m.Body.Instructions.Clear()
                [void]$m.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Call, $getZero))
                [void]$m.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Ret))
                $m.Body.KeepOldMaxStack = $false
                $done += $name
            }
        }

        # --- Update: тело -> this.rotation = Quaternion.identity; return ---
        $mu = $t.Methods | Where-Object { $_.Name -eq "Update" -and $_.HasBody }
        if ($mu) {
            $rotField = $t.Fields | Where-Object { $_.Name -eq "rotation" } | Select-Object -First 1
            if ($rotField) {
                $mu.Body.ExceptionHandlers.Clear()
                $mu.Body.Variables.Clear()
                $mu.Body.Instructions.Clear()
                [void]$mu.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Ldarg_0))
                [void]$mu.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Call, $getIdentity))
                [void]$mu.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Stfld, $rotField))
                [void]$mu.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Ret))
                $mu.Body.KeepOldMaxStack = $false
                $done += "Update"
            }
        }

        if ($done.Count -eq 0) { return @{ ok=$false; msg="Тряска: методы Bober не найдены." } }

        # --- ПОКАЧИВАНИЕ ОРУЖИЯ/РУК (armsRoot) в ClientMoveController.CallLateUpdate ---
        # Два источника, оба гасим:
        #   1) инерция от движения мыши — поле prevDelta (Vector2) крутит armsRoot через RotateAround.
        #      Обнуляем prevDelta ПОСЛЕ его накопления и ПЕРЕД первым использованием в armsRoot-блоке.
        #   2) постоянное «дыхание» по времени — Mathf.Sin/Cos(realtimeSinceStartup) в углах Euler
        #      для armsRoot.set_localRotation. Заменяем каждый Sin/Cos на 0 (pop; ldc.r4 0),
        #      сохраняя базовый наклон (state.euler.x + JumpEuler) и звук шагов.
        $armsMsg = ""
        $tc = $mod.Find("ClientMoveController", $true)
        $mc = if ($tc) { $tc.Methods | Where-Object { $_.Name -eq "CallLateUpdate" -and $_.HasBody } } else { $null }
        if ($mc) {
            $ci = $mc.Body.Instructions
            # get_zero (Vector2) — уже есть в модуле, используется этим же методом
            $v2zero = $null
            foreach ($mr in $mod.GetMemberRefs()) {
                if ($mr.DeclaringType -and $mr.DeclaringType.Name -eq "Vector2" -and $mr.Name -eq "get_zero") { $v2zero = $mr; break }
            }
            # поле prevDelta
            $prevDelta = $tc.Fields | Where-Object { $_.Name -eq "prevDelta" } | Select-Object -First 1
            # индекс первого использования prevDelta ИМЕННО в armsRoot-блоке:
            # ищем первый RotateAround, затем поднимаемся к началу его armsRoot-блока (ldfld armsRoot).
            $firstRot = -1
            for ($i=0; $i -lt $ci.Count; $i++) { if ("$($ci[$i].Operand)" -match "Transform::RotateAround") { $firstRot=$i; break } }
            $insAt = -1
            if ($firstRot -ge 0) {
                for ($i=$firstRot; $i -ge 1; $i--) {
                    if ("$($ci[$i].Operand)" -match "ClientMoveController::armsRoot") { $insAt=$i-1; break }
                }
            }
            $bobbedArms = $false
            if ($v2zero -and $prevDelta -and $insAt -ge 0) {
                $anchor = $ci[$insAt]  # вставляем перед этим объектом
                $ins = @(
                    [dnlib.DotNet.Emit.Instruction]::Create($Op::Ldarg_0),
                    [dnlib.DotNet.Emit.Instruction]::Create($Op::Call, $v2zero),
                    [dnlib.DotNet.Emit.Instruction]::Create($Op::Stfld, $prevDelta)
                )
                $ai = $ci.IndexOf($anchor)
                for ($j=0; $j -lt $ins.Count; $j++) { $ci.Insert($ai+$j, $ins[$j]) }
                $bobbedArms = $true
            }
            # заменить Mathf.Sin/Cos на 0 (pop; ldc.r4 0) — только в armsRoot-части (после первого RotateAround-блока).
            $sinCos = 0
            # пересобираем список (индексы сместились после вставки)
            $startScan = 0
            for ($i=0; $i -lt $ci.Count; $i++) { if ("$($ci[$i].Operand)" -match "Transform::RotateAround") { $startScan=$i; break } }
            for ($i=$ci.Count-1; $i -ge $startScan; $i--) {
                if ($ci[$i].OpCode.Name -eq "call" -and "$($ci[$i].Operand)" -match "Mathf::(Sin|Cos)") {
                    $ci[$i].OpCode = $Op::Pop; $ci[$i].Operand = $null
                    $ci.Insert($i+1, [dnlib.DotNet.Emit.Instruction]::Create($Op::Ldc_R4, [float]0))
                    $sinCos++
                }
            }
            if ($bobbedArms -or $sinCos -gt 0) {
                $mc.Body.KeepOldMaxStack = $false
                $mc.Body.SimplifyBranches(); $mc.Body.OptimizeBranches()
                $armsMsg = "; оружие: инерция=$([int]$bobbedArms), дыхание=$sinCos"
                $done += "оружие"
            }
        }

        # --- ТРЯСКА ОТ ПУЛЬ/ВЗРЫВОВ/ПРИЗЕМЛЕНИЯ (CameraShaker) ---
        # CameraShaker.CustomUpdate() вычисляет pos (смещение), которое добавляется к камере и
        # оружию в CallLateUpdate. Источники InitShake: попадание пули (ClientNetPlayer.Hit),
        # взрывы (ExplosionFromServer, MortarExplosion), приземление (OnGrounded).
        # Гасим ВСЮ тряску, обнуляя pos: тело CustomUpdate -> this.pos = Vector3.zero; return.
        $ts = $mod.Find("CameraShaker", $true)
        if ($ts) {
            $cu = $ts.Methods | Where-Object { $_.Name -eq "CustomUpdate" -and $_.HasBody }
            $posField = $ts.Fields | Where-Object { $_.Name -eq "pos" } | Select-Object -First 1
            if ($cu -and $posField -and $getZero) {
                $cu.Body.ExceptionHandlers.Clear()
                $cu.Body.Variables.Clear()
                $cu.Body.Instructions.Clear()
                [void]$cu.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Ldarg_0))
                [void]$cu.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Call, $getZero))
                [void]$cu.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Stfld, $posField))
                [void]$cu.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Ret))
                $cu.Body.KeepOldMaxStack = $false
                $armsMsg += "; тряска от пуль/взрывов убрана"
                $done += "пули/взрывы"
            }
        }

        $opts = New-Object dnlib.DotNet.Writer.ModuleWriterOptions($mod)
        $opts.MetadataOptions.Flags = [dnlib.DotNet.Writer.MetadataFlags]::PreserveAll
        $ms = New-Object System.IO.MemoryStream
        $mod.Write($ms, $opts)
        return @{ ok=$true; bytes=$ms.ToArray(); msg="Тряска камеры и оружия при движении отключена ($($done -join ', ')$armsMsg)." }
    } finally { $mod.Dispose() }
}

# ---------- СНЕГ + ЛУЧИ/БЛИКИ СОЛНЦА ----------
# 1) Снег: SnowFlakes.Update управляет видимостью снежинок (MeshRenderer.enabled).
#    Переписываем Update так, чтобы он каждый кадр ВЫКЛЮЧАЛ все рендереры снежинок → снега нет.
#    (Массив _flakesRenderers создаётся в Start; логика теплового прицела не ломается.)
# 2) Лучи/блики солнца: SunOnGlass.OnRenderImage — пост-эффект, накладывающий солнце/лучи/блик
#    на кадр (слепит). Заменяем тело на простое Graphics.Blit(source, destination) — картинка
#    проходит без эффекта. LensFlares.Draw и VisibilityChecker больше не вызываются.
# Принимает путь к DLL, ВОЗВРАЩАЕТ новые байты (@{ ok; bytes; msg }).
function Invoke-CWNoSnowSun {
    param([string]$DllPath)
    if (-not (Test-Path $DllPath)) { return @{ ok=$false; msg="NoSnowSun: DLL не найдена: $DllPath" } }
    $mod = [dnlib.DotNet.ModuleDefMD]::Load([IO.File]::ReadAllBytes($DllPath))
    try {
        $Op    = [dnlib.DotNet.Emit.OpCodes]
        $Instr = [dnlib.DotNet.Emit.Instruction]
        $done = @()

        # ===== 1) СНЕГ: SnowFlakes.Update -> выключить все рендереры и выйти =====
        $tSnow = $mod.Find("SnowFlakes", $true)
        if ($tSnow) {
            $mu = $tSnow.Methods | Where-Object { $_.Name -eq "Update" -and $_.HasBody }
            $renderersField = $tSnow.Fields | Where-Object { $_.Name -eq "_flakesRenderers" } | Select-Object -First 1
            # set_enabled(bool) на Renderer — берём ссылку из старого тела Update
            $setEnabled = $null
            if ($mu) { foreach ($x in $mu.Body.Instructions) { if ("$($x.Operand)" -match "Renderer::set_enabled") { $setEnabled = $x.Operand; break } } }
            if ($mu -and $renderersField -and $setEnabled) {
                $mu.Body.ExceptionHandlers.Clear()
                $mu.Body.Variables.Clear()
                $ins = $mu.Body.Instructions
                $ins.Clear()
                # for (int i=0; i<_flakesRenderers.Length; i++) _flakesRenderers[i].enabled = false;
                $loc_i = New-Object dnlib.DotNet.Emit.Local($mod.CorLibTypes.Int32)
                [void]$mu.Body.Variables.Add($loc_i)
                $lblCond = $Instr::Create($Op::Ldloc_0)          # метка проверки условия
                $lblBody = $Instr::Create($Op::Ldarg_0)          # метка тела цикла
                # i = 0
                [void]$ins.Add($Instr::Create($Op::Ldc_I4_0))
                [void]$ins.Add($Instr::Create($Op::Stloc_0))
                [void]$ins.Add($Instr::Create($Op::Br, $lblCond))
                # тело: _flakesRenderers[i].enabled = false
                [void]$ins.Add($lblBody)                          # ldarg.0
                [void]$ins.Add($Instr::Create($Op::Ldfld, $renderersField))
                [void]$ins.Add($Instr::Create($Op::Ldloc_0))
                [void]$ins.Add($Instr::Create($Op::Ldelem_Ref))
                [void]$ins.Add($Instr::Create($Op::Ldc_I4_0))
                [void]$ins.Add($Instr::Create($Op::Callvirt, $setEnabled))
                # i++
                [void]$ins.Add($Instr::Create($Op::Ldloc_0))
                [void]$ins.Add($Instr::Create($Op::Ldc_I4_1))
                [void]$ins.Add($Instr::Create($Op::Add))
                [void]$ins.Add($Instr::Create($Op::Stloc_0))
                # cond: i < _flakesRenderers.Length
                [void]$ins.Add($lblCond)                          # ldloc.0
                [void]$ins.Add($Instr::Create($Op::Ldarg_0))
                [void]$ins.Add($Instr::Create($Op::Ldfld, $renderersField))
                [void]$ins.Add($Instr::Create($Op::Ldlen))
                [void]$ins.Add($Instr::Create($Op::Conv_I4))
                [void]$ins.Add($Instr::Create($Op::Blt, $lblBody))
                [void]$ins.Add($Instr::Create($Op::Ret))
                $mu.Body.KeepOldMaxStack = $false
                $mu.Body.SimplifyBranches(); $mu.Body.OptimizeBranches()
                $done += "снег"
            }
        }

        # ===== 2) СОЛНЦЕ/ЛУЧИ/БЛИКИ: SunOnGlass.OnRenderImage -> Graphics.Blit(src, dest) =====
        $tSun = $mod.Find("SunOnGlass", $true)
        if ($tSun) {
            $ri = $tSun.Methods | Where-Object { $_.Name -eq "OnRenderImage" -and $_.HasBody }
            # 2-арг Graphics.Blit(Texture, RenderTexture) — уже есть в теле метода
            $blit2 = $null
            if ($ri) {
                foreach ($x in $ri.Body.Instructions) {
                    if ("$($x.Operand)" -match "Graphics::Blit" -and "$($x.Operand)" -notmatch "Material") { $blit2 = $x.Operand; break }
                }
            }
            if ($ri -and $blit2) {
                $ri.Body.ExceptionHandlers.Clear()
                $ri.Body.Variables.Clear()
                $ri.Body.Instructions.Clear()
                [void]$ri.Body.Instructions.Add($Instr::Create($Op::Ldarg_1))   # source
                [void]$ri.Body.Instructions.Add($Instr::Create($Op::Ldarg_2))   # destination
                [void]$ri.Body.Instructions.Add($Instr::Create($Op::Call, $blit2))
                [void]$ri.Body.Instructions.Add($Instr::Create($Op::Ret))
                $ri.Body.KeepOldMaxStack = $false
                $done += "лучи/блики солнца"
            }
        }

        if ($done.Count -eq 0) { return @{ ok=$false; msg="Снег/солнце: подходящие методы не найдены (ничего не изменено)." } }

        $opts = New-Object dnlib.DotNet.Writer.ModuleWriterOptions($mod)
        $opts.MetadataOptions.Flags = [dnlib.DotNet.Writer.MetadataFlags]::PreserveAll
        $ms = New-Object System.IO.MemoryStream
        $mod.Write($ms, $opts)
        return @{ ok=$true; bytes=$ms.ToArray(); msg="Отключено: $($done -join ', ')." }
    } finally { $mod.Dispose() }
}

# ---------- СТАБИЛЬНАЯ ОТДАЧА РУК (предсказуемая, как в CS) ----------
# При каждом выстреле Animations.PlayFire играет СЛУЧАЙНУЮ fire-анимацию: имя = "fire" +
# CircleRandom.GetI() (случайный индекс). Из-за этого руки с оружием дёргает то влево, то
# вправо хаотично, прицел теряется. Делаем CircleRandom.GetI() всегда возвращающим 1 →
# каждый выстрел играет ОДНУ И ТУ ЖЕ анимацию отдачи, руки дёргает предсказуемо (вверх/назад),
# прицел не «таскает» в стороны. GetI используется ТОЛЬКО для fireRand (3 метода стрельбы),
# так что ничего постороннего не затрагивается. Разброс пуль (серверный) не трогаем.
# Возвращает новые байты (@{ ok; bytes; msg }).
function Invoke-CWStableRecoil {
    param([string]$DllPath)
    if (-not (Test-Path $DllPath)) { return @{ ok=$false; msg="Отдача: DLL не найдена: $DllPath" } }
    $mod = [dnlib.DotNet.ModuleDefMD]::Load([IO.File]::ReadAllBytes($DllPath))
    try {
        $Op = [dnlib.DotNet.Emit.OpCodes]
        $t = $mod.Find("CircleRandom", $true)
        if (-not $t) { return @{ ok=$false; msg="Отдача: класс CircleRandom не найден (ничего не изменено)." } }
        $m = $t.Methods | Where-Object { $_.Name -eq "GetI" -and $_.HasBody }
        if (-not $m) { return @{ ok=$false; msg="Отдача: CircleRandom.GetI не найден." } }
        # тело -> return 1 (всегда первая fire-анимация → одинаковая отдача каждый выстрел)
        $m.Body.ExceptionHandlers.Clear()
        $m.Body.Variables.Clear()
        $m.Body.Instructions.Clear()
        [void]$m.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Ldc_I4_1))
        [void]$m.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::Create($Op::Ret))
        $m.Body.KeepOldMaxStack = $false

        $opts = New-Object dnlib.DotNet.Writer.ModuleWriterOptions($mod)
        $opts.MetadataOptions.Flags = [dnlib.DotNet.Writer.MetadataFlags]::PreserveAll
        $ms = New-Object System.IO.MemoryStream
        $mod.Write($ms, $opts)
        return @{ ok=$true; bytes=$ms.ToArray(); msg="Отдача рук сделана стабильной (одинаковая анимация каждый выстрел)." }
    } finally { $mod.Dispose() }
}

# ---------- НИКНЕЙМЫ ИГРОКОВ НАД ГОЛОВАМИ (красный=враг, синий=союзник) ----------
# Игра уже рисует ник союзников через RadarGUI.DrawFriendEntityScreenspaceInfo (безопасно,
# со всеми проверками разработчиков). Врагов штатно не показывает. Делаем через ЭТУ ЖЕ функцию:
#   1) убираем внутренний guard "he is not a friend" (чтобы рисовала и врагов);
#   2) перед выводом ника ставим цвет по параметру friendly: синий (свой) / красный (враг);
#   3) в RadarGUI.GameGUI перенаправляем вызовы DrawEnemyEntityScreenspaceInfo на DrawFriend.
# В дезматче IsTeam всегда false → все красные (штатная логика игры). Свой перебор игроков
# НЕ используем — это давало нативный краш; здесь только правки внутри штатного кода.
# Возвращает новые байты (@{ ok; bytes; msg }).
function Invoke-CWNicks {
    param([string]$DllPath)
    if (-not (Test-Path $DllPath)) { return @{ ok=$false; msg="Ники: DLL не найдена: $DllPath" } }
    $mod = [dnlib.DotNet.ModuleDefMD]::Load([IO.File]::ReadAllBytes($DllPath))
    try {
        $Op    = [dnlib.DotNet.Emit.OpCodes]
        $Instr = [dnlib.DotNet.Emit.Instruction]
        $rg = $mod.Find("RadarGUI", $true)
        if (-not $rg) { return @{ ok=$false; msg="Ники: класс RadarGUI не найден (ничего не изменено)." } }
        $df = $rg.Methods | Where-Object { $_.Name -eq "DrawFriendEntityScreenspaceInfo" -and $_.HasBody }
        if (-not $df) { return @{ ok=$false; msg="Ники: DrawFriendEntityScreenspaceInfo не найден." } }

        # ссылки Color::.ctor и UnityEngine.GUI::set_color — из тела этой же функции
        $colorCtor = $null; $setColor = $null
        foreach ($x in $df.Body.Instructions) {
            if ("$($x.Operand)" -match "Color::\.ctor") { $colorCtor = $x.Operand }
            if ("$($x.Operand)" -match "UnityEngine\.GUI::set_color") { $setColor = $x.Operand }
        }
        if (-not $colorCtor -or -not $setColor) { return @{ ok=$false; msg="Ники: ссылки Color/set_color не найдены." } }

        $ins = $df.Body.Instructions

        # (1) убрать guard "he is not a friend!"
        $gi = -1
        for ($i=0; $i -lt $ins.Count; $i++) { if ($ins[$i].OpCode.Name -eq "ldstr" -and "$($ins[$i].Operand)" -match "not a friend") { $gi = $i; break } }
        if ($gi -ge 0) {
            $brtrue = -1
            for ($k=$gi-1; $k -ge $gi-4; $k--) { if ($ins[$k].OpCode.Name -match "brtrue") { $brtrue = $k; break } }
            if ($brtrue -ge 0) {
                $ins[$brtrue].OpCode = $Op::Br     # безусловно на нормальный код
                if ($ins[$brtrue-1].OpCode.Name -match "ldarg") { $ins[$brtrue-1].OpCode = $Op::Nop; $ins[$brtrue-1].Operand = $null }
                for ($k=$gi; $k -lt $gi+3 -and $k -lt $ins.Count; $k++) {
                    if ($ins[$k].OpCode.Name -eq "ldstr" -or "$($ins[$k].Operand)" -match "LogError") { $ins[$k].OpCode = $Op::Nop; $ins[$k].Operand = $null }
                }
            }
        }

        # (2) перед ник-блоком вставить цвет по friendly (arg3): синий/красный
        $nickLabel = -1
        for ($i=0; $i -lt $ins.Count; $i++) {
            if ("$($ins[$i].Operand)" -match "GUI::Label") {
                for ($j=[Math]::Max(0,$i-25); $j -lt $i; $j++) { if ("$($ins[$j].Operand)" -match "get_Nick") { $nickLabel = $i; break } }
                if ($nickLabel -ge 0) { break }
            }
        }
        if ($nickLabel -lt 0) { return @{ ok=$false; msg="Ники: место вывода ника не найдено." } }
        $blockStart = -1
        for ($k=$nickLabel-1; $k -ge 0; $k--) { if ("$($ins[$k].Operand)" -match "set_alignment") { $blockStart = $k-2; break } }
        if ($blockStart -lt 0) { return @{ ok=$false; msg="Ники: начало ник-блока не найдено." } }
        $anchorObj = $ins[$blockStart]
        $lblBlue = $Instr::Create($Op::Ldc_R4, [float]0.3)
        $seq = @(
            $Instr::Create($Op::Ldarg_3),
            $Instr::Create($Op::Brtrue, $lblBlue),
            $Instr::Create($Op::Ldc_R4, [float]1),    # красный: враг
            $Instr::Create($Op::Ldc_R4, [float]0.2),
            $Instr::Create($Op::Ldc_R4, [float]0.2),
            $Instr::Create($Op::Ldc_R4, [float]1),
            $Instr::Create($Op::Newobj, $colorCtor),
            $Instr::Create($Op::Call, $setColor),
            $Instr::Create($Op::Br, $anchorObj),
            $lblBlue,                                  # синий: союзник (0.3,...)
            $Instr::Create($Op::Ldc_R4, [float]0.5),
            $Instr::Create($Op::Ldc_R4, [float]1),
            $Instr::Create($Op::Ldc_R4, [float]1),
            $Instr::Create($Op::Newobj, $colorCtor),
            $Instr::Create($Op::Call, $setColor)
        )
        $ai = $ins.IndexOf($anchorObj)
        for ($j=0; $j -lt $seq.Count; $j++) { $ins.Insert($ai+$j, $seq[$j]) }
        $df.Body.KeepOldMaxStack = $false
        $df.Body.SimplifyBranches(); $df.Body.OptimizeBranches()

        # (3) GameGUI: DrawEnemy... -> DrawFriend...
        $gg = $rg.Methods | Where-Object { $_.Name -eq "GameGUI" -and $_.HasBody }
        $cnt = 0
        if ($gg) {
            foreach ($x in $gg.Body.Instructions) { if ("$($x.Operand)" -match "RadarGUI::DrawEnemyEntityScreenspaceInfo") { $x.Operand = $df; $cnt++ } }
            $gg.Body.KeepOldMaxStack = $false
        }

        $opts = New-Object dnlib.DotNet.Writer.ModuleWriterOptions($mod)
        $opts.MetadataOptions.Flags = [dnlib.DotNet.Writer.MetadataFlags]::PreserveAll
        $ms = New-Object System.IO.MemoryStream
        $mod.Write($ms, $opts)
        return @{ ok=$true; bytes=$ms.ToArray(); msg="Ники игроков включены (красный=враг, синий=союзник; перенаправлено вызовов: $cnt)." }
    } finally { $mod.Dispose() }
}

# ---------- СВОЙ ВИДИМЫЙ ТРАССЕР (ярко-красная 3D-линия через LineRenderer) ----------
# Родной трассер игры (частицы) почти не виден. Рисуем собственную линию: в НАЧАЛО
# Tracer.Create вставляем вызов CWTracer.Spawn(start, end) — внешний класс CWTracer
# (CWTracer.dll кладётся в Managed игры) создаёт короткоживущую ярко-красную линию от
# ствола к точке попадания. Родные частицы не трогаем (пусть остаются как есть).
# Параметры Tracer.Create: arg0=start (Vector3), arg1=end (Vector3).
# $TracerDllPath — путь к CWTracer.dll. Возвращает новые байты (@{ ok; bytes; msg }).
function Invoke-CWTracers {
    param([string]$DllPath, [string]$TracerDllPath)
    if (-not (Test-Path $DllPath)) { return @{ ok=$false; msg="Трассеры: DLL не найдена: $DllPath" } }
    if (-not $TracerDllPath -or -not (Test-Path $TracerDllPath)) { return @{ ok=$false; msg="Трассеры: CWTracer.dll не найдена рядом с патчером." } }
    $mod = [dnlib.DotNet.ModuleDefMD]::Load([IO.File]::ReadAllBytes($DllPath))
    $scr = [dnlib.DotNet.ModuleDefMD]::Load([IO.File]::ReadAllBytes($TracerDllPath))
    try {
        $Op    = [dnlib.DotNet.Emit.OpCodes]
        $Instr = [dnlib.DotNet.Emit.Instruction]
        $imp   = New-Object dnlib.DotNet.Importer($mod)

        $t = $mod.Find("Tracer", $true)
        if (-not $t) { return @{ ok=$false; msg="Трассеры: класс Tracer не найден (ничего не изменено)." } }
        $m = $t.Methods | Where-Object { $_.Name -eq "Create" -and $_.HasBody }
        if (-not $m) { return @{ ok=$false; msg="Трассеры: Tracer.Create не найден." } }

        # ссылка на CWTracer.Spawn(Vector3, Vector3)
        $cwt = $scr.Find("CWTracer", $true)
        if (-not $cwt) { return @{ ok=$false; msg="Трассеры: класс CWTracer не найден в CWTracer.dll." } }
        $spawn = $cwt.Methods | Where-Object { $_.Name -eq "Spawn" } | Select-Object -First 1
        if (-not $spawn) { return @{ ok=$false; msg="Трассеры: CWTracer.Spawn не найден." } }
        $spawnRef = $imp.Import($spawn)

        # Вставляем в САМОЕ НАЧАЛО метода: CWTracer.Spawn(arg0, arg1);
        # (start=arg0, end=arg1 — Tracer.Create статический, поэтому arg0/arg1 = параметры)
        $ins = $m.Body.Instructions
        $first = $ins[0]
        $newList = @(
            $Instr::Create($Op::Ldarg_0),
            $Instr::Create($Op::Ldarg_1),
            $Instr::Create($Op::Call, $spawnRef)
        )
        for ($j = 0; $j -lt $newList.Count; $j++) { $ins.Insert($j, $newList[$j]) }
        $m.Body.KeepOldMaxStack = $false
        $m.Body.SimplifyBranches(); $m.Body.OptimizeBranches()

        $opts = New-Object dnlib.DotNet.Writer.ModuleWriterOptions($mod)
        $opts.MetadataOptions.Flags = [dnlib.DotNet.Writer.MetadataFlags]::PreserveAll
        $ms = New-Object System.IO.MemoryStream
        $mod.Write($ms, $opts)
        return @{ ok=$true; bytes=$ms.ToArray(); msg="Свой видимый трассер добавлен (ярко-красная линия от ствола к цели)." }
    } finally { $mod.Dispose(); $scr.Dispose() }
}

# Хелперы для чтения/записи ldc.i4 (короткие и полные формы).
function Get-LdcI4Value($inst) {
    switch ($inst.OpCode.Name) {
        "ldc.i4.0" { 0 } "ldc.i4.1" { 1 } "ldc.i4.2" { 2 } "ldc.i4.3" { 3 } "ldc.i4.4" { 4 }
        "ldc.i4.5" { 5 } "ldc.i4.6" { 6 } "ldc.i4.7" { 7 } "ldc.i4.8" { 8 } "ldc.i4.m1" { -1 }
        "ldc.i4.s" { [int]$inst.Operand } "ldc.i4" { [int]$inst.Operand } default { $null }
    }
}
function Set-LdcI4($inst, $Op, [int]$val) {
    if ($val -ge -128 -and $val -le 127) { $inst.OpCode = $Op::Ldc_I4_S; $inst.Operand = [sbyte]$val }
    else { $inst.OpCode = $Op::Ldc_I4; $inst.Operand = [int]$val }
}

# ---------- ЛАУНЧЕР: запуск игры в окне без рамки (borderless) ----------
# Патчит CWClientLauncher.exe: StartGameControl.StartGame ставит аргументы запуска игры.
# Делаем так, чтобы аргументы ВСЕГДА содержали -popupwindow -screen-fullscreen 0 (borderless),
# независимо от галки в лаунчере. Тогда родной лаунчер сам запускает игру без рамки.
# $LauncherPath — путь к CWClientLauncher.exe. Возвращает @{ ok; msg }.
function Invoke-CWLauncherBorderless {
    param([string]$LauncherPath)
    if (-not (Test-Path $LauncherPath)) { return @{ ok=$false; msg="Лаунчер не найден: $LauncherPath" } }
    $mod = [dnlib.DotNet.ModuleDefMD]::Load([IO.File]::ReadAllBytes($LauncherPath))
    try {
        $t = $mod.GetTypes() | Where-Object { $_.Name -eq "StartGameControl" } | Select-Object -First 1
        if (-not $t) { return @{ ok=$false; msg="Лаунчер: StartGameControl не найден (другая версия?)." } }
        $m = $t.Methods | Where-Object { $_.Name -eq "StartGame" -and $_.HasBody }
        if (-not $m) { return @{ ok=$false; msg="Лаунчер: StartGame не найден." } }
        $inst = $m.Body.Instructions
        $Op = [dnlib.DotNet.Emit.OpCodes]
        # 1) строку аргументов игры заменить на borderless (ищем ldstr, за которым set_Arguments рядом)
        $argStr = $false
        for ($i=0; $i -lt $inst.Count-1; $i++) {
            if ($inst[$i].OpCode.Name -eq "ldstr") {
                # проверим, что в пределах +2 идёт set_Arguments
                for ($k=$i+1; $k -le [Math]::Min($i+2,$inst.Count-1); $k++) {
                    if ("$($inst[$k].Operand)" -match "set_Arguments") {
                        $cur = "$($inst[$i].Operand)"
                        $inst[$i].Operand = "-popupwindow -screen-fullscreen 0" + $(if ($cur -match "force-gfx") { " -force-gfx-st" } else { "" })
                        $argStr = $true
                    }
                }
            }
        }
        if (-not $argStr) { return @{ ok=$false; msg="Лаунчер: место аргументов запуска не найдено." } }
        # 2) убрать условие галки — set_Arguments должен вызываться ВСЕГДА.
        # brfalse.s, у которых цель = ldloc.0 (переход мимо установки аргументов), заменяем на pop.
        for ($i=0; $i -lt $inst.Count; $i++) {
            if ($inst[$i].OpCode.Name -eq "brfalse.s" -and "$($inst[$i].Operand)" -match "ldloc\.0") {
                $inst[$i].OpCode = $Op::Pop; $inst[$i].Operand = $null
            }
        }
        $m.Body.KeepOldMaxStack = $false
        # бэкап оригинала
        $bak = "$LauncherPath.orig.bak"
        if (-not (Test-Path $bak)) { Copy-Item $LauncherPath $bak }
        $opts = New-Object dnlib.DotNet.Writer.ModuleWriterOptions($mod)
        $opts.MetadataOptions.Flags = [dnlib.DotNet.Writer.MetadataFlags]::PreserveAll
        $ms = New-Object System.IO.MemoryStream
        $mod.Write($ms, $opts)
        return @{ ok=$true; bytes=$ms.ToArray(); msg="Лаунчер пропатчен: запускает игру в окне без рамки (borderless)." }
    } finally { $mod.Dispose() }
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

# ---------- FOV-ползунок + выпадающий список режима экрана (единый проход dnlib) ----------
# Объединяет отлаженные трансформации над ОДНИМ загруженным модулем, ПЕРЕСОБИРАЕТ его
# (Insert инструкций требует mod.Write) и ВОЗВРАЩАЕТ новые байты — не правит переданный $bytes.
# Порядок применения строго: (1) fov-чтение PlayerPrefs в ClientAmmunitions.CallLateUpdate,
# (2) fov-ползунок + сдвиг блока графики в SettingsGUI.InterfaceGUI,
# (3) screen-тумблеры (get_fullScreen+SetResolution -> CWScreen.Toggle) + Apply в Main,
# (4) ВЫПАДАЮЩИЙ СПИСОК выбора режима экрана (3 режима) в SettingsGUI.InterfaceGUI —
#     dropdown-IL собирается инлайн (операнды берутся из штатного SimpleQualityDropDown),
#     затем ПЕРЕНОСИТСЯ в конец группы окна (перед первым из двух закрывающих EndGroup окна),
#     чтобы рисоваться поверх остальных элементов. Старый чекбокс больше НЕ вставляется.
# CWScreen — public-класс с public static полем dropOpen и public-методами, поэтому
# InternalsVisibleTo НЕ требуется (доступ к public-членам не зависит от границ сборки).
# $DllPath — путь к патчимой Assembly-CSharp.dll; $ScreenDllPath — путь к CWScreen.dll (для Importer).
function Invoke-CWFovScreen {
    param([string]$DllPath, [string]$ScreenDllPath, [int]$Fov = 90)

    if (-not (Test-Path $DllPath)) { return @{ ok=$false; msg="FOV/Screen: не найден DLL: $DllPath" } }
    if (-not (Test-Path $ScreenDllPath)) { return @{ ok=$false; msg="FOV/Screen: не найден CWScreen.dll: $ScreenDllPath" } }

    $Instruction = [dnlib.DotNet.Emit.Instruction]
    $OpCodes     = [dnlib.DotNet.Emit.OpCodes]
    $Op          = $OpCodes
    $Instr       = $Instruction

    $mod = [dnlib.DotNet.ModuleDefMD]::Load([IO.File]::ReadAllBytes($DllPath))
    $scr = [dnlib.DotNet.ModuleDefMD]::Load([IO.File]::ReadAllBytes($ScreenDllPath))
    try {
        $imp = New-Object dnlib.DotNet.Importer($mod)

        # ===== ссылки CWScreen (screen_patch — тумблеры/Apply; dropdown — список режимов) =====
        $cwType    = $scr.Find("CWScreen",$true)
        $toggleRef = $imp.Import(($cwType.Methods | Where-Object { $_.Name -eq "Toggle" }))
        $applyRef  = $imp.Import(($cwType.Methods | Where-Object { $_.Name -eq "Apply" }))
        # dropdown-список: CurName (главная кнопка), ModeName/SetMode (пункты), поле dropOpen (состояние).
        # Все члены CWScreen public => IVT не нужен, Importer импортирует их напрямую.
        $curNameRef  = $imp.Import(($cwType.Methods | Where-Object { $_.Name -eq "CurName" }))
        $modeNameRef = $imp.Import(($cwType.Methods | Where-Object { $_.Name -eq "ModeName" }))
        $setModeRef  = $imp.Import(($cwType.Methods | Where-Object { $_.Name -eq "SetMode" }))
        $dropOpenRef = $imp.Import(($cwType.Fields  | Where-Object { $_.Name -eq "dropOpen" }))

        # ===== общие ссылки PlayerPrefs (fov_step1 + fov_step2) =====
        $getInt = $null; $hasKey = $null; $setInt = $null
        foreach ($mr in $mod.GetMemberRefs()) {
            if ($mr.DeclaringType -and $mr.DeclaringType.Name -eq "PlayerPrefs") {
                if ($mr.Name -eq "GetInt" -and $mr.MethodSig.Params.Count -eq 1) { $getInt = $mr }
                if ($mr.Name -eq "HasKey") { $hasKey = $mr }
                if ($mr.Name -eq "SetInt") { $setInt = $mr }
            }
        }

        # ===== (0) убрать "(при полноэкранном режиме)" из подписи разрешения =====
        # Теперь есть переключатель окно/полный экран, поэтому уточнение в скобках лишнее.
        foreach ($t0 in $mod.GetTypes()) {
            foreach ($m0 in $t0.Methods) {
                if (-not $m0.HasBody) { continue }
                foreach ($i0 in $m0.Body.Instructions) {
                    if ($i0.OpCode.Name -eq "ldstr" -and "$($i0.Operand)" -match "Разрешение экрана \(при полноэкранном") {
                        $i0.Operand = "Разрешение экрана:"
                    }
                }
            }
        }

        # =========================================================================
        # (1) fov_step1 — чтение PlayerPrefs "cw_fov" (фолбэк 90) вместо nowCamFov=60
        # =========================================================================
        $m1 = ($mod.Find("ClientAmmunitions",$true).Methods | Where-Object { $_.Name -eq "CallLateUpdate" })
        if (-not $m1) { return @{ ok=$false; msg="FOV/Screen: ClientAmmunitions.CallLateUpdate не найден." } }
        $inst = $m1.Body.Instructions

        $idx = -1
        for ($i=0;$i -lt $inst.Count-1;$i++){
            if ($inst[$i].OpCode.Name -eq "ldc.r4" -and $inst[$i+1].OpCode.Name -eq "stfld" -and "$($inst[$i+1].Operand)" -match "nowCamFov") { $idx=$i; break }
        }
        if ($idx -lt 0) { return @{ ok=$false; msg="FOV/Screen: nowCamFov присвоение не найдено." } }

        $lblElse = $Instruction::Create($OpCodes::Ldc_R4, [float]90.0)
        $lblEnd  = $Instruction::Create($OpCodes::Nop)
        $newSeq = New-Object System.Collections.Generic.List[object]
        $newSeq.Add($Instruction::Create($OpCodes::Ldstr, "cw_fov"))
        $newSeq.Add($Instruction::Create($OpCodes::Call, $hasKey))
        $newSeq.Add($Instruction::Create($OpCodes::Brfalse, $lblElse))
        $newSeq.Add($Instruction::Create($OpCodes::Ldstr, "cw_fov"))
        $newSeq.Add($Instruction::Create($OpCodes::Call, $getInt))
        $newSeq.Add($Instruction::Create($OpCodes::Conv_R4))
        $newSeq.Add($Instruction::Create($OpCodes::Br, $lblEnd))
        $newSeq.Add($lblElse)
        $newSeq.Add($lblEnd)

        for ($j=0; $j -lt $newSeq.Count; $j++) { $inst.Insert($idx + $j, $newSeq[$j]) }
        $inst.RemoveAt($idx + $newSeq.Count)   # старая ldc.r4 60
        $m1.Body.KeepOldMaxStack = $false
        $m1.Body.OptimizeBranches()

        # =========================================================================
        # (2) fov_step2 — FOV-ползунок + подпись + сдвиг блока графики (SettingsGUI.InterfaceGUI)
        # =========================================================================
        $mgType = $mod.Find("MainGUI", $true)
        $floatSlider = $mgType.Methods | Where-Object { $_.Name -eq "FloatSlider" -and $_.Parameters.Count -eq 8 } | Select-Object -First 1
        $textField = $mgType.Methods | Where-Object { $_.Name -eq "TextField" -and "$($_.MethodSig)" -match "System.String,System.Int32,System.String" } | Select-Object -First 1
        $formType = $mod.Find("Form", $true)
        $guiField = $formType.Fields | Where-Object { $_.Name -eq "gui" } | Select-Object -First 1
        $vec2ctor = $null; $rectctor = $null
        foreach($mr in $mod.GetMemberRefs()){
            if($mr.DeclaringType -and $mr.DeclaringType.Name -eq "Vector2" -and $mr.Name -eq ".ctor"){ $vec2ctor=$mr }
            if($mr.DeclaringType -and $mr.DeclaringType.Name -eq "Rect" -and $mr.Name -eq ".ctor" -and $mr.MethodSig.Params.Count -eq 4){ $rectctor=$mr }
        }

        $m2 = ($mod.Find("SettingsGUI",$true).Methods | Where-Object { $_.Name -eq "InterfaceGUI" })
        if (-not $m2) { return @{ ok=$false; msg="FOV/Screen: SettingsGUI.InterfaceGUI не найден." } }
        $inst = $m2.Body.Instructions

        $shiftY = @{
            115.0=92.0; 117.0=94.0; 124.0=101.0
            104.0=82.0                                 # текст значения качества («Пользовательские») — выровнять с ползунком
            152.0=124.0
            182.0=150.0; 184.0=152.0; 212.0=178.0
            242.0=210.0; 248.0=216.0; 272.0=240.0; 278.0=246.0
            305.0=308.0; 340.0=338.0
        }
        for ($i=0; $i -lt $inst.Count-2; $i++) {
            if ($inst[$i].OpCode.Name -eq "ldc.r4" -and $inst[$i+1].OpCode.Name -eq "ldc.r4" -and
                $inst[$i+2].OpCode.Name -eq "newobj" -and "$($inst[$i+2].Operand)" -match "Vector2::.ctor") {
                $y=[float]$inst[$i+1].Operand; if ($shiftY.ContainsKey([double]$y)) { $inst[$i+1].Operand=[float]$shiftY[[double]$y] }
            }
            if ($i -lt $inst.Count-4 -and $inst[$i].OpCode.Name -eq "ldc.r4" -and $inst[$i+1].OpCode.Name -eq "ldc.r4" -and
                $inst[$i+2].OpCode.Name -eq "ldc.r4" -and $inst[$i+3].OpCode.Name -eq "ldc.r4" -and
                $inst[$i+4].OpCode.Name -eq "newobj" -and "$($inst[$i+4].Operand)" -match "Rect::.ctor") {
                $y=[float]$inst[$i+1].Operand; if ($shiftY.ContainsKey([double]$y)) { $inst[$i+1].Operand=[float]$shiftY[[double]$y] }
            }
        }

        # якорь: видимая ветка set_ShadowDistance (showText=1, hide=0, showMax=0)
        $anchor = -1
        for ($i=0;$i -lt $inst.Count;$i++){
            if ($inst[$i].OpCode.Name -eq "callvirt" -and "$($inst[$i].Operand)" -match "set_ShadowDistance") {
                $flags = @()
                for ($k=$i-1; $k -ge $i-8 -and $k -ge 0; $k--) { if ($inst[$k].OpCode.Name -match "^ldc\.i4") { $flags = @($inst[$k].OpCode.Name) + $flags } }
                if ($flags.Count -ge 3 -and $flags[-3] -eq "ldc.i4.1" -and $flags[-2] -eq "ldc.i4.0" -and $flags[-1] -eq "ldc.i4.0") { $anchor=$i; break }
            }
        }
        if ($anchor -lt 0) { return @{ ok=$false; msg="FOV/Screen: якорь ShadowDistance (FOV) не найден." } }

        $seq = New-Object System.Collections.Generic.List[object]
        # подпись FOV
        $seq.Add($Instruction::Create($OpCodes::Ldarg_0))
        $seq.Add($Instruction::Create($OpCodes::Ldfld, $guiField))
        $seq.Add($Instruction::Create($OpCodes::Ldc_R4, [float]30))
        $seq.Add($Instruction::Create($OpCodes::Ldc_R4, [float]272))
        $seq.Add($Instruction::Create($OpCodes::Ldc_R4, [float]600))
        $seq.Add($Instruction::Create($OpCodes::Ldc_R4, [float]50))
        $seq.Add($Instruction::Create($OpCodes::Newobj, $rectctor))
        $seq.Add($Instruction::Create($OpCodes::Ldstr, "FOV (угол обзора)"))
        $seq.Add($Instruction::Create($OpCodes::Ldc_I4, [int]16))
        $seq.Add($Instruction::Create($OpCodes::Ldstr, "#dfdfdf"))
        $seq.Add($Instruction::Create($OpCodes::Ldc_I4_0))
        $seq.Add($Instruction::Create($OpCodes::Ldc_I4_0))
        $seq.Add($Instruction::Create($OpCodes::Ldc_I4_0))
        $seq.Add($Instruction::Create($OpCodes::Callvirt, $textField))
        $seq.Add($Instruction::Create($OpCodes::Pop))
        # слайдер FOV
        $seq.Add($Instruction::Create($OpCodes::Ldstr, "cw_fov"))
        $seq.Add($Instruction::Create($OpCodes::Ldarg_0))
        $seq.Add($Instruction::Create($OpCodes::Ldfld, $guiField))
        $seq.Add($Instruction::Create($OpCodes::Ldc_R4, [float]265))
        $seq.Add($Instruction::Create($OpCodes::Ldc_R4, [float]278))
        $seq.Add($Instruction::Create($OpCodes::Newobj, $vec2ctor))
        $seq.Add($Instruction::Create($OpCodes::Ldstr, "cw_fov"))
        $seq.Add($Instruction::Create($OpCodes::Call, $getInt))
        $seq.Add($Instruction::Create($OpCodes::Conv_R4))
        $seq.Add($Instruction::Create($OpCodes::Ldc_R4, [float]60))
        $seq.Add($Instruction::Create($OpCodes::Ldc_R4, [float]110))
        $seq.Add($Instruction::Create($OpCodes::Ldc_I4_1))
        $seq.Add($Instruction::Create($OpCodes::Ldc_I4_0))
        $seq.Add($Instruction::Create($OpCodes::Ldc_I4_0))
        $seq.Add($Instruction::Create($OpCodes::Callvirt, $floatSlider))
        $seq.Add($Instruction::Create($OpCodes::Conv_I4))
        $seq.Add($Instruction::Create($OpCodes::Call, $setInt))

        for ($j=0;$j -lt $seq.Count;$j++){ $inst.Insert($anchor+1+$j, $seq[$j]) }
        $m2.Body.KeepOldMaxStack = $false
        $m2.Body.OptimizeBranches()

        # =========================================================================
        # (3) screen_patch — тумблеры экрана -> CWScreen.Toggle + Apply в Main
        # =========================================================================
        $patched=@()
        $mg=$mod.Find("MainGUI",$true)
        foreach($mn in "OnUpdate","InterfaceGUI"){
            $m=$mg.Methods | Where-Object {$_.Name -eq $mn -and $_.HasBody}
            if($m -and (CW-PatchToggle $m $Op $toggleRef)){ $m.Body.KeepOldMaxStack=$false; $patched+="MainGUI.$mn" }
        }
        # SettingsGUI кнопки OK/Применить: НЕ Toggle (иначе каждый клик инвертирует режим),
        # а Apply — просто применить текущий сохранённый выбор (выбор делается чекбоксом/F12).
        $sg=($mod.Find("SettingsGUI",$true).Methods | Where-Object {$_.Name -eq "InterfaceGUI" -and $_.HasBody})
        $n=0; while((CW-PatchToggle $sg $Op $applyRef) -and $n -lt 4){ $n++; $patched+="SettingsGUI.InterfaceGUI#$n" }
        if($n -gt 0){ $sg.Body.KeepOldMaxStack=$false }

        # Apply() ТОЛЬКО в Init (применить режим один раз при старте). НЕ в OnApplicationFocus —
        # он срабатывает при каждом alt-tab, и SetResolution внутри Apply перебивал переключение окна.
        $main=$mod.Find("Main",$true)
        foreach($mn in "Init"){
            $m=$main.Methods | Where-Object {$_.Name -eq $mn -and $_.HasBody} | Select-Object -First 1
            if(-not $m){ continue }
            $ii=$m.Body.Instructions
            $lr=-1; for($i=$ii.Count-1;$i -ge 0;$i--){ if($ii[$i].OpCode.Name -eq "ret"){$lr=$i;break} }
            if($lr -ge 0){ $ii.Insert($lr,$Instr::Create($Op::Call,$applyRef)); $m.Body.KeepOldMaxStack=$false; $patched+="Main.$mn(Apply)" }
        }

        # =========================================================================
        # (4) dropdown — выпадающий список выбора режима экрана (3 режима) в SettingsGUI.InterfaceGUI
        #     IL собирается инлайн (операнды из штатного SimpleQualityDropDown этой сборки),
        #     блок stack-нейтрален, затем ПЕРЕНОСИТСЯ в конец группы окна (перед первым из двух
        #     закрывающих EndGroup окна) — чтобы список рисовался поверх остальных элементов.
        # =========================================================================
        $m4=($mod.Find("SettingsGUI",$true).Methods | Where-Object {$_.Name -eq "InterfaceGUI"})
        $sqdd=($mod.Find("SettingsGUI",$true).Methods | Where-Object {$_.Name -eq "SimpleQualityDropDown"})
        if(-not $sqdd){ return @{ ok=$false; msg="FOV/Screen: SettingsGUI.SimpleQualityDropDown (эталон операндов) не найден." } }
        $sq=$sqdd.Body.Instructions

        # --- операнды-ссылки из штатного дропдауна (валидные токены этой сборки) ---
        $fld_gui      = $sq[1].Operand      # Form::gui
        $fld_mmb      = $sq[5].Operand      # MainGUI::mainMenuButtons
        $m_Button     = $sq[31].Operand     # MainGUI::Button(...)
        $fld_Clicked  = $sq[34].Operand     # ButtonState::Clicked
        $ctor_Vector2 = $sq[55].Operand     # Vector2::.ctor
        $fld_v2x      = $sq[48].Operand     # Vector2::x
        $fld_v2y      = $sq[52].Operand     # Vector2::y
        $fld_sw       = $sq[58].Operand     # MainGUI::settings_window
        $m_Picture    = $sq[61].Operand     # MainGUI::Picture
        $m_getheight  = $sq[78].Operand     # Texture::get_height
        $m_getwidth   = $sq[111].Operand    # Texture::get_width
        $ctor_Rect    = $sq[124].Operand    # Rect::.ctor
        $m_BeginGroup = $sq[125].Operand    # MainGUI::BeginGroup
        $m_EndGroup   = $sq[264].Operand    # MainGUI::EndGroup
        $fld_upper    = $sq[304].Operand    # MainGUI::upper
        $m_getcursor  = $sq[307].Operand    # MainGUI::get_cursorPosition
        $m_inRect     = $sq[308].Operand    # MainGUI::inRect
        $m_GetMouseDn = $sq[315].Operand    # Input::GetMouseButtonDown
        $ty_nbutton   = $sq[24].Operand     # Nullable<ButtonState>
        $ty_nvector   = $sq[27].Operand     # Nullable<Vector2>

        # --- локальные переменные (типы берём из штатных методов) ---
        $sig_nbutton = $sqdd.Body.Variables[0].Type   # Nullable<ButtonState>
        $sig_button  = $sqdd.Body.Variables[2].Type   # ButtonState
        $sig_rect    = $m4.Body.Variables[0].Type      # Rect
        $sig_vector2 = $m4.Body.Variables[3].Type      # Vector2
        $sig_nvector = $m4.Body.Variables[28].Type     # Nullable<Vector2>
        $Local = [dnlib.DotNet.Emit.Local]
        $L_pos  = $m4.Body.Variables.Add((New-Object $Local($sig_vector2)))
        $L_nbA  = $m4.Body.Variables.Add((New-Object $Local($sig_nbutton)))
        $L_nvA  = $m4.Body.Variables.Add((New-Object $Local($sig_nvector)))
        $L_bsA  = $m4.Body.Variables.Add((New-Object $Local($sig_button)))
        $L_nbB  = $m4.Body.Variables.Add((New-Object $Local($sig_nbutton)))
        $L_nvB  = $m4.Body.Variables.Add((New-Object $Local($sig_nvector)))
        $L_bsB  = $m4.Body.Variables.Add((New-Object $Local($sig_button)))
        $L_rect = $m4.Body.Variables.Add((New-Object $Local($sig_rect)))

        $NEW = New-Object System.Collections.Generic.List[object]
        $L_afterMain = $Instr::Create($Op::Nop)
        $L_elseOpen  = $Instr::Create($Op::Nop)
        $L_end       = $Instr::Create($Op::Nop)

        # pos = new Vector2(235,64)  (главная кнопка списка, X=235 у строки разрешения)
        $NEW.Add($Instr::Create($Op::Ldc_R4,[float]235))
        $NEW.Add($Instr::Create($Op::Ldc_R4,[float]64))
        $NEW.Add($Instr::Create($Op::Newobj,$ctor_Vector2))
        $NEW.Add($Instr::Create($Op::Stloc,$L_pos))

        # главная кнопка: gui.Button(pos, mmb[0], mmb[1], mmb[1], CWScreen.CurName(), 15, "#FFFFFF", 4, null?, null?, null, null)
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui))
        $NEW.Add($Instr::Create($Op::Ldloc,$L_pos))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_mmb)); $NEW.Add($Instr::Create($Op::Ldc_I4_0)); $NEW.Add($Instr::Create($Op::Ldelem_Ref))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_mmb)); $NEW.Add($Instr::Create($Op::Ldc_I4_1)); $NEW.Add($Instr::Create($Op::Ldelem_Ref))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_mmb)); $NEW.Add($Instr::Create($Op::Ldc_I4_1)); $NEW.Add($Instr::Create($Op::Ldelem_Ref))
        $NEW.Add($Instr::Create($Op::Call,$curNameRef))
        $NEW.Add($Instr::Create($Op::Ldc_I4_S,[sbyte]15))
        $NEW.Add($Instr::Create($Op::Ldstr,"#FFFFFF"))
        $NEW.Add($Instr::Create($Op::Ldc_I4_4))
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_nbA)); $NEW.Add($Instr::Create($Op::Initobj,$ty_nbutton)); $NEW.Add($Instr::Create($Op::Ldloc,$L_nbA))
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_nvA)); $NEW.Add($Instr::Create($Op::Initobj,$ty_nvector)); $NEW.Add($Instr::Create($Op::Ldloc,$L_nvA))
        $NEW.Add($Instr::Create($Op::Ldnull)); $NEW.Add($Instr::Create($Op::Ldnull))
        $NEW.Add($Instr::Create($Op::Callvirt,$m_Button))
        $NEW.Add($Instr::Create($Op::Stloc,$L_bsA))
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_bsA))
        $NEW.Add($Instr::Create($Op::Ldfld,$fld_Clicked))
        $NEW.Add($Instr::Create($Op::Brfalse,$L_afterMain))
        # клик по главной кнопке -> dropOpen = !dropOpen
        $NEW.Add($Instr::Create($Op::Ldsfld,$dropOpenRef))
        $NEW.Add($Instr::Create($Op::Ldc_I4_0))
        $NEW.Add($Instr::Create($Op::Ceq))
        $NEW.Add($Instr::Create($Op::Stsfld,$dropOpenRef))
        $NEW.Add($L_afterMain)

        # if(!dropOpen) picture(collapsed sw[2]); else открыть список
        $NEW.Add($Instr::Create($Op::Ldsfld,$dropOpenRef))
        $NEW.Add($Instr::Create($Op::Brtrue,$L_elseOpen))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui))
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_pos)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_v2x)); $NEW.Add($Instr::Create($Op::Ldc_R4,[float]165)); $NEW.Add($Instr::Create($Op::Add))
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_pos)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_v2y)); $NEW.Add($Instr::Create($Op::Ldc_R4,[float]8)); $NEW.Add($Instr::Create($Op::Add))
        $NEW.Add($Instr::Create($Op::Newobj,$ctor_Vector2))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_sw)); $NEW.Add($Instr::Create($Op::Ldc_I4_2)); $NEW.Add($Instr::Create($Op::Ldelem_Ref))
        $NEW.Add($Instr::Create($Op::Callvirt,$m_Picture))
        $NEW.Add($Instr::Create($Op::Br,$L_end))

        # else: раскрытый список
        $NEW.Add($L_elseOpen)
        # gui.Picture(new Vector2(pos.x-5, pos.y+mmb[0].height), sw[4])
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui))
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_pos)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_v2x)); $NEW.Add($Instr::Create($Op::Ldc_R4,[float]5)); $NEW.Add($Instr::Create($Op::Sub))
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_pos)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_v2y))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_mmb)); $NEW.Add($Instr::Create($Op::Ldc_I4_0)); $NEW.Add($Instr::Create($Op::Ldelem_Ref)); $NEW.Add($Instr::Create($Op::Callvirt,$m_getheight)); $NEW.Add($Instr::Create($Op::Conv_R4)); $NEW.Add($Instr::Create($Op::Add))
        $NEW.Add($Instr::Create($Op::Newobj,$ctor_Vector2))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_sw)); $NEW.Add($Instr::Create($Op::Ldc_I4_4)); $NEW.Add($Instr::Create($Op::Ldelem_Ref))
        $NEW.Add($Instr::Create($Op::Callvirt,$m_Picture))

        # gui.BeginGroup(new Rect(pos.x-5, pos.y+mmb[0].height+4, sw[4].width-5, sw[4].height))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui))
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_pos)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_v2x)); $NEW.Add($Instr::Create($Op::Ldc_R4,[float]5)); $NEW.Add($Instr::Create($Op::Sub))
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_pos)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_v2y))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_mmb)); $NEW.Add($Instr::Create($Op::Ldc_I4_0)); $NEW.Add($Instr::Create($Op::Ldelem_Ref)); $NEW.Add($Instr::Create($Op::Callvirt,$m_getheight)); $NEW.Add($Instr::Create($Op::Conv_R4)); $NEW.Add($Instr::Create($Op::Add))
        $NEW.Add($Instr::Create($Op::Ldc_R4,[float]4)); $NEW.Add($Instr::Create($Op::Add))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_sw)); $NEW.Add($Instr::Create($Op::Ldc_I4_4)); $NEW.Add($Instr::Create($Op::Ldelem_Ref)); $NEW.Add($Instr::Create($Op::Callvirt,$m_getwidth)); $NEW.Add($Instr::Create($Op::Ldc_I4_5)); $NEW.Add($Instr::Create($Op::Sub)); $NEW.Add($Instr::Create($Op::Conv_R4))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_sw)); $NEW.Add($Instr::Create($Op::Ldc_I4_4)); $NEW.Add($Instr::Create($Op::Ldelem_Ref)); $NEW.Add($Instr::Create($Op::Callvirt,$m_getheight)); $NEW.Add($Instr::Create($Op::Conv_R4))
        $NEW.Add($Instr::Create($Op::Newobj,$ctor_Rect))
        $NEW.Add($Instr::Create($Op::Callvirt,$m_BeginGroup))

        # три пункта: ModeName(i) -> при клике dropOpen=0; SetMode(i). Y_i = 3 + (mmb[1].height+5)*i
        $optButton = {
            param([int]$mIdx, [scriptblock]$emitY)
            $lbl_after = $Instr::Create($Op::Nop)
            $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui))
            $NEW.Add($Instr::Create($Op::Ldc_R4,[float]4))
            & $emitY
            $NEW.Add($Instr::Create($Op::Newobj,$ctor_Vector2))
            $NEW.Add($Instr::Create($Op::Ldnull))
            $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_mmb)); $NEW.Add($Instr::Create($Op::Ldc_I4_1)); $NEW.Add($Instr::Create($Op::Ldelem_Ref))
            $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_mmb)); $NEW.Add($Instr::Create($Op::Ldc_I4_1)); $NEW.Add($Instr::Create($Op::Ldelem_Ref))
            $NEW.Add($Instr::Create($Op::Ldc_I4,[int]$mIdx)); $NEW.Add($Instr::Create($Op::Call,$modeNameRef))
            $NEW.Add($Instr::Create($Op::Ldc_I4_S,[sbyte]15))
            $NEW.Add($Instr::Create($Op::Ldstr,"#ffffff"))
            $NEW.Add($Instr::Create($Op::Ldc_I4_4))
            $NEW.Add($Instr::Create($Op::Ldloca_S,$L_nbB)); $NEW.Add($Instr::Create($Op::Initobj,$ty_nbutton)); $NEW.Add($Instr::Create($Op::Ldloc,$L_nbB))
            $NEW.Add($Instr::Create($Op::Ldloca_S,$L_nvB)); $NEW.Add($Instr::Create($Op::Initobj,$ty_nvector)); $NEW.Add($Instr::Create($Op::Ldloc,$L_nvB))
            $NEW.Add($Instr::Create($Op::Ldnull)); $NEW.Add($Instr::Create($Op::Ldnull))
            $NEW.Add($Instr::Create($Op::Callvirt,$m_Button))
            $NEW.Add($Instr::Create($Op::Stloc,$L_bsB))
            $NEW.Add($Instr::Create($Op::Ldloca_S,$L_bsB))
            $NEW.Add($Instr::Create($Op::Ldfld,$fld_Clicked))
            $NEW.Add($Instr::Create($Op::Brfalse,$lbl_after))
            $NEW.Add($Instr::Create($Op::Ldc_I4_0)); $NEW.Add($Instr::Create($Op::Stsfld,$dropOpenRef))
            $NEW.Add($Instr::Create($Op::Ldc_I4,[int]$mIdx)); $NEW.Add($Instr::Create($Op::Call,$setModeRef))
            $NEW.Add($lbl_after)
        }
        & $optButton 0 { $NEW.Add($Instr::Create($Op::Ldc_R4,[float]3)) }
        & $optButton 1 {
            $NEW.Add($Instr::Create($Op::Ldc_R4,[float]3))
            $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_mmb)); $NEW.Add($Instr::Create($Op::Ldc_I4_1)); $NEW.Add($Instr::Create($Op::Ldelem_Ref)); $NEW.Add($Instr::Create($Op::Callvirt,$m_getheight))
            $NEW.Add($Instr::Create($Op::Ldc_I4_5)); $NEW.Add($Instr::Create($Op::Add)); $NEW.Add($Instr::Create($Op::Conv_R4)); $NEW.Add($Instr::Create($Op::Add))
        }
        & $optButton 2 {
            $NEW.Add($Instr::Create($Op::Ldc_R4,[float]3))
            $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_mmb)); $NEW.Add($Instr::Create($Op::Ldc_I4_1)); $NEW.Add($Instr::Create($Op::Ldelem_Ref)); $NEW.Add($Instr::Create($Op::Callvirt,$m_getheight))
            $NEW.Add($Instr::Create($Op::Ldc_I4_5)); $NEW.Add($Instr::Create($Op::Add)); $NEW.Add($Instr::Create($Op::Ldc_I4_2)); $NEW.Add($Instr::Create($Op::Mul)); $NEW.Add($Instr::Create($Op::Conv_R4)); $NEW.Add($Instr::Create($Op::Add))
        }

        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Callvirt,$m_EndGroup))

        # закрытие списка по клику вне его области
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_pos)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_v2x)); $NEW.Add($Instr::Create($Op::Ldc_R4,[float]5)); $NEW.Add($Instr::Create($Op::Sub))
        $NEW.Add($Instr::Create($Op::Ldloca_S,$L_pos)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_v2y))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_mmb)); $NEW.Add($Instr::Create($Op::Ldc_I4_0)); $NEW.Add($Instr::Create($Op::Ldelem_Ref)); $NEW.Add($Instr::Create($Op::Callvirt,$m_getheight)); $NEW.Add($Instr::Create($Op::Conv_R4)); $NEW.Add($Instr::Create($Op::Add)); $NEW.Add($Instr::Create($Op::Ldc_R4,[float]4)); $NEW.Add($Instr::Create($Op::Add))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_sw)); $NEW.Add($Instr::Create($Op::Ldc_I4_4)); $NEW.Add($Instr::Create($Op::Ldelem_Ref)); $NEW.Add($Instr::Create($Op::Callvirt,$m_getwidth)); $NEW.Add($Instr::Create($Op::Ldc_I4_5)); $NEW.Add($Instr::Create($Op::Sub)); $NEW.Add($Instr::Create($Op::Conv_R4))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_sw)); $NEW.Add($Instr::Create($Op::Ldc_I4_4)); $NEW.Add($Instr::Create($Op::Ldelem_Ref)); $NEW.Add($Instr::Create($Op::Callvirt,$m_getheight)); $NEW.Add($Instr::Create($Op::Conv_R4))
        $NEW.Add($Instr::Create($Op::Newobj,$ctor_Rect))
        $NEW.Add($Instr::Create($Op::Stloc,$L_rect))
        $L_afterClose = $Instr::Create($Op::Nop)
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui))
        $NEW.Add($Instr::Create($Op::Ldloc,$L_rect))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_upper))
        $NEW.Add($Instr::Create($Op::Ldarg_0)); $NEW.Add($Instr::Create($Op::Ldfld,$fld_gui)); $NEW.Add($Instr::Create($Op::Callvirt,$m_getcursor))
        $NEW.Add($Instr::Create($Op::Callvirt,$m_inRect))
        $NEW.Add($Instr::Create($Op::Brtrue,$L_afterClose))
        $NEW.Add($Instr::Create($Op::Ldc_I4_0)); $NEW.Add($Instr::Create($Op::Call,$m_GetMouseDn))
        $NEW.Add($Instr::Create($Op::Brfalse,$L_afterClose))
        $NEW.Add($Instr::Create($Op::Ldc_I4_0)); $NEW.Add($Instr::Create($Op::Stsfld,$dropOpenRef))
        $NEW.Add($L_afterClose)
        $NEW.Add($L_end)

        # --- вставка dropdown ТОЛЬКО во вкладку ВИДЕО/АУДИО (settingsState==1). ---
        # ВАЖНО: enum SettingsState: GAME=0, VIDEO_AUDIO=1, CONTROLS=2, NETWORK=3, BONUSES=4.
        # Тело блока VIDEO_AUDIO заканчивается вызовом ResolutionDropDown(...) и безусловным
        # переходом `br` в общий футер окна. Вставляем наш stack-нейтральный блок ПЕРЕД этим `br`:
        # тогда при settingsState==1 тело проваливается в dropdown → br в футер; при ≠1 условный
        # переход блока вкладки перепрыгивает и тело, и dropdown. Так список виден лишь в Видео/Аудио,
        # но по-прежнему внутри группы окна (координаты относительно панели).
        $inst=$m4.Body.Instructions
        # маркер конца тела VIDEO_AUDIO — последний вызов ResolutionDropDown до конца метода.
        $resDD=-1
        for($k=0;$k -lt $inst.Count;$k++){ if("$($inst[$k].Operand)" -match "SettingsGUI::ResolutionDropDown"){ $resDD=$k } }
        if($resDD -lt 0){ return @{ ok=$false; msg="FOV/Screen: конец блока Видео/Аудио (ResolutionDropDown) не найден." } }
        # первый br/br.s сразу после ResolutionDropDown — терминатор тела вкладки
        $brTerm=-1
        for($k=$resDD+1;$k -le [Math]::Min($resDD+4,$inst.Count-1);$k++){ if($inst[$k].OpCode.Name -eq "br" -or $inst[$k].OpCode.Name -eq "br.s"){ $brTerm=$k; break } }
        if($brTerm -lt 0){ return @{ ok=$false; msg="FOV/Screen: терминатор (br) блока Видео/Аудио не найден." } }
        $targetObj=$inst[$brTerm]     # вставляем ПЕРЕД этим br
        $ti=$inst.IndexOf($targetObj)
        for($j=0;$j -lt $NEW.Count;$j++){ $inst.Insert($ti+$j,$NEW[$j]) }
        $m4.Body.SimplifyBranches()
        $m4.Body.OptimizeBranches()
        $m4.Body.KeepOldMaxStack=$false
        $patched+="SettingsGUI.InterfaceGUI(dropdown)"

        # ===== запись модуля один раз =====
        $opts = New-Object dnlib.DotNet.Writer.ModuleWriterOptions($mod)
        $opts.MetadataOptions.Flags = [dnlib.DotNet.Writer.MetadataFlags]::PreserveAll
        $ms = New-Object System.IO.MemoryStream
        $mod.Write($ms, $opts)
        $outBytes = $ms.ToArray()

        # Установка ключа fov по умолчанию не требуется здесь — ползунок читает GetInt,
        # а fov_step1 применяет фолбэк 90 при отсутствии ключа. $Fov сохраняем как дефолт слайдера.
        return @{ ok=$true; msg="FOV-ползунок и выбор режима экрана добавлены в настройки игры."; bytes=$outBytes }
    }
    finally {
        $mod.Dispose(); $scr.Dispose()
    }
}

# Хелпер screen_patch: заменяет if/else тумблера (get_fullScreen..второй SetResolution) на call Toggle.
function CW-PatchToggle($method, $Op, $toggleRef) {
    $inst=$method.Body.Instructions
    for($i=0;$i -lt $inst.Count-2;$i++){
        if($inst[$i].OpCode.Name -eq "call" -and "$($inst[$i].Operand)" -match "get_fullScreen" -and
           $inst[$i+1].OpCode.Name -match "brfalse"){
            $setCount=0; $endIdx=-1
            for($k=$i+2;$k -lt [Math]::Min($i+40,$inst.Count);$k++){
                if("$($inst[$k].Operand)" -match "Utility::SetResolution"){ $setCount++; if($setCount -eq 2){ $endIdx=$k; break } }
            }
            if($endIdx -lt 0){ continue }
            $has800=$false; for($k=$i;$k -le $endIdx;$k++){ if($inst[$k].OpCode.Name -match "ldc.i4" -and "$($inst[$k].Operand)" -eq "800"){$has800=$true} }
            if(-not $has800){ continue }
            $inst[$i].OpCode=$Op::Call; $inst[$i].Operand=$toggleRef
            for($k=$i+1;$k -le $endIdx;$k++){ $inst[$k].OpCode=$Op::Nop; $inst[$k].Operand=$null }
            return $true
        }
    }
    return $false
}
