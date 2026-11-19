' Double-click on a Windows PC in the home LAN.
' Runs vpn_fix.py (Python 3). Prompts for the Keenetic admin password.
Option Explicit

Dim sh, fso, folder, py, result, code, pwd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)

If Not fso.FileExists(folder & "\vpn_fix.py") Then
  MsgBox "vpn_fix.py лежит рядом с этим файлом. Скачайте его из той же папки.", vbCritical, "Роутер"
  WScript.Quit 1
End If

pwd = InputBox("Пароль администратора роутера (admin @ 192.168.3.1):", "Роутер", "")
If pwd = "" Then WScript.Quit 0

sh.Environment("Process").Item("KEENETIC_PASSWORD") = pwd

py = FindPython()
If py = "" Then
  MsgBox "Нужен Python 3: https://www.python.org/downloads/windows/", vbCritical, "Роутер"
  WScript.Quit 1
End If

code = sh.Run("cmd /c """ & py & """ -u """ & folder & "\vpn_fix.py"" --host 192.168.3.1 --user admin > ""%TEMP%\vpn-fix-out.txt"" 2>&1", 1, True)
sh.Environment("Process").Item("KEENETIC_PASSWORD") = ""

result = ""
If fso.FileExists(sh.ExpandEnvironmentStrings("%TEMP%\vpn-fix-out.txt")) Then
  result = fso.OpenTextFile(sh.ExpandEnvironmentStrings("%TEMP%\vpn-fix-out.txt"), 1, False).ReadAll
End If
If Len(result) > 1500 Then result = Left(result, 1500)
If code = 0 Then
  MsgBox result, vbInformation, "Роутер"
Else
  If result = "" Then result = "Python exited with code " & code
  MsgBox result, vbCritical, "Роутер"
End If
WScript.Quit code

Function FindPython()
  Dim c, n
  For Each c In Array("python3", "py -3", "python")
    n = sh.Run("cmd /c " & c & " -c ""import sys; sys.exit(0 if sys.version_info[0]>=3 else 1)""", 0, True)
    If n = 0 Then
      FindPython = c
      Exit Function
    End If
  Next
  FindPython = ""
End Function
