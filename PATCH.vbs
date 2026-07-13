' Запуск патчера Contract Wars без мелькающих чёрных окон.
' Снимает блокировку "скачано из интернета" и открывает окно патчера.
' Всё «рабочее» лежит в подпапке engine — трогать её не нужно.
Dim sh, fso, dir, eng
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
eng = dir & "\engine"

If Not fso.FolderExists(eng) Then
    MsgBox "Не найдена папка engine рядом с PATCH.vbs." & vbCrLf & _
           "Распакуйте архив целиком и запускайте PATCH.vbs из распакованной папки.", 48, "Contract Wars Tweaks"
    WScript.Quit
End If

' 1) Снять метку зоны со всех файлов engine (иначе dnlib.dll не грузится).
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -Command ""Get-ChildItem -LiteralPath '" & eng & "' -File | Unblock-File""", 0, True

' 2) Запустить окно патчера скрыто (0 = без консольного окна).
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & eng & "\Patch-CWResolution.ps1"" -GUI", 0, False
