' Запуск патчера Contract Wars без мелькающих чёрных окон.
' Снимает блокировку "скачано из интернета" и открывает окно патчера.
Dim sh, fso, dir
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)

' 1) Снять метку зоны со всех файлов папки (иначе dnlib.dll не грузится).
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -Command ""Get-ChildItem -LiteralPath '" & dir & "' -File | Unblock-File""", 0, True

' 2) Запустить окно патчера скрыто (0 = без консольного окна).
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\Patch-CWResolution.ps1"" -GUI", 0, False
