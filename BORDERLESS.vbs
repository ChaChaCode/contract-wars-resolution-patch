' Запуск Contract Wars в режиме ОКНА БЕЗ РАМКИ (borderless) на весь монитор.
' Окно не сворачивается при клике на другой экран — удобно для нескольких мониторов.
' Не модифицирует код игры — только способ запуска (флаг движка Unity -popupwindow).
Dim sh, fso, dir, eng
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
eng = dir & "\engine"

If Not fso.FolderExists(eng) Then
    MsgBox "Не найдена папка engine рядом с BORDERLESS.vbs." & vbCrLf & _
           "Распакуйте архив целиком.", 48, "Contract Wars Borderless"
    WScript.Quit
End If

sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -Command ""Get-ChildItem -LiteralPath '" & eng & "' -File | Unblock-File""", 0, True
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & eng & "\Launch-Borderless.ps1""", 0, False
