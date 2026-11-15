' Double-click on a PC in the home LAN: adds Instagram and Cursor to the
' Keenetic VPN DNS route at 192.168.3.1 (admin). Enter the router password.
Option Explicit

Dim sh, fso, psExe, ps1, result, code, text, ts, pwd, folder
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

folder = fso.GetParentFolderName(WScript.ScriptFullName)
psExe = sh.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
ps1 = folder & "\vpn-routes.ps1"
result = sh.ExpandEnvironmentStrings("%TEMP%\vpn-routes-result.txt")

If Not fso.FileExists(ps1) Then
  MsgBox "vpn-routes.ps1 is missing next to vpn-routes.vbs.", vbCritical, "VPN"
  WScript.Quit 1
End If

pwd = InputBox(U("\041F\0430\0440\043E\043B\044C \0430\0434\043C\0438\043D\0438\0441\0442\0440\0430\0442\043E\0440\0430 \0440\043E\0443\0442\0435\0440\0430 (admin @ 192.168.3.1):"), "VPN", "")
If pwd = "" Then WScript.Quit 0

If fso.FileExists(result) Then fso.DeleteFile result, True

sh.Environment("Process").Item("KEENETIC_PASSWORD") = pwd

On Error Resume Next
code = sh.Run("""" & psExe & """ -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """ -Router 192.168.3.1 -User admin -ResultPath """ & result & """", 0, True)
If Err.Number <> 0 Then
  MsgBox Err.Description, vbCritical, "VPN"
  WScript.Quit 1
End If
On Error GoTo 0

sh.Environment("Process").Item("KEENETIC_PASSWORD") = ""

If fso.FileExists(result) Then
  Set ts = fso.OpenTextFile(result, 1, False, -1)
  text = ts.ReadAll
  ts.Close
  fso.DeleteFile result, True
  If Len(text) > 1200 Then text = Left(text, 1200)
  If code = 0 Then
    MsgBox text, vbInformation, "VPN"
  Else
    MsgBox text, vbCritical, "VPN"
  End If
  WScript.Quit code
End If

MsgBox "PowerShell exited with code " & code & ".", vbCritical, "VPN"
WScript.Quit code

Function U(s)
  Dim sb, i, hex
  sb = ""
  i = 1
  Do While i <= Len(s)
    If Mid(s, i, 1) = "\" And i + 4 <= Len(s) Then
      hex = Mid(s, i + 1, 4)
      If IsHex4(hex) Then
        sb = sb & ChrW(CLng("&H" & hex))
        i = i + 5
      Else
        sb = sb & Mid(s, i, 1)
        i = i + 1
      End If
    Else
      sb = sb & Mid(s, i, 1)
      i = i + 1
    End If
  Loop
  U = sb
End Function

Function IsHex4(s)
  Dim j, c
  If Len(s) <> 4 Then
    IsHex4 = False
    Exit Function
  End If
  For j = 1 To 4
    c = UCase(Mid(s, j, 1))
    If InStr("0123456789ABCDEF", c) = 0 Then
      IsHex4 = False
      Exit Function
    End If
  Next
  IsHex4 = True
End Function
