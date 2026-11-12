' Double-click: installs the LS_CORP Wi-Fi profile (PEAP / EAP-MSCHAPv2).
' UseWinLogonCredentials is off. Accept the UAC prompt.
Option Explicit

Dim sh, fso, psExe, ps1, result, code, text, ts
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If Not WScript.Arguments.Named.Exists("elevated") Then
  If Not IsElevated() Then
    CreateObject("Shell.Application").ShellExecute "wscript.exe", """" & WScript.ScriptFullName & """ /elevated", "", "runas", 1
    WScript.Quit 0
  End If
End If

psExe = sh.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
ps1 = sh.ExpandEnvironmentStrings("%TEMP%\LS_CORP-setup.ps1")
result = sh.ExpandEnvironmentStrings("%TEMP%\LS_CORP-result.txt")

If fso.FileExists(result) Then fso.DeleteFile result, True

Set ts = fso.CreateTextFile(ps1, True, False)
ts.Write PowerShellSource()
ts.Close

On Error Resume Next
code = sh.Run("""" & psExe & """ -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """", 0, True)
If Err.Number <> 0 Then
  MsgBox Err.Description, vbCritical, "LS_CORP"
  WScript.Quit 1
End If
On Error GoTo 0

If fso.FileExists(ps1) Then fso.DeleteFile ps1, True

If fso.FileExists(result) Then
  Set ts = fso.OpenTextFile(result, 1, False, -1)
  text = ts.ReadAll
  ts.Close
  fso.DeleteFile result, True
  If Len(text) > 900 Then text = Left(text, 900)
  If code = 0 Then
    MsgBox text, vbInformation, "LS_CORP"
  Else
    MsgBox text, vbCritical, "LS_CORP"
  End If
  WScript.Quit code
End If

MsgBox "PowerShell exited with code " & code & ".", vbCritical, "LS_CORP"
WScript.Quit code

Function IsElevated()
  On Error Resume Next
  sh.RegRead "HKEY_USERS\S-1-5-19\Environment\TEMP"
  IsElevated = (Err.Number = 0)
  Err.Clear
  On Error GoTo 0
End Function

Function PowerShellSource()
  Dim s
  s = ""
  s = s & "$ErrorActionPreference = 'Stop'" & vbCrLf
  s = s & "if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {" & vbCrLf
  s = s & "    $PSNativeCommandUseErrorActionPreference = $false" & vbCrLf
  s = s & "}" & vbCrLf
  s = s & "$resultPath = Join-Path $env:TEMP 'LS_CORP-result.txt'" & vbCrLf
  s = s & "" & vbCrLf
  s = s & "function U([string]$s) {" & vbCrLf
  s = s & "    $sb = New-Object System.Text.StringBuilder" & vbCrLf
  s = s & "    $i = 0" & vbCrLf
  s = s & "    while ($i -lt $s.Length) {" & vbCrLf
  s = s & "        if ($s[$i] -eq [char]92 -and ($i + 4) -lt $s.Length) {" & vbCrLf
  s = s & "            [void]$sb.Append([char][Convert]::ToInt32($s.Substring($i + 1, 4), 16))" & vbCrLf
  s = s & "            $i += 5" & vbCrLf
  s = s & "        } else {" & vbCrLf
  s = s & "            [void]$sb.Append($s[$i])" & vbCrLf
  s = s & "            $i += 1" & vbCrLf
  s = s & "        }" & vbCrLf
  s = s & "    }" & vbCrLf
  s = s & "    $sb.ToString()" & vbCrLf
  s = s & "}" & vbCrLf
  s = s & "" & vbCrLf
  s = s & "function Save-Result([string]$text) {" & vbCrLf
  s = s & "    $enc = New-Object System.Text.UnicodeEncoding $false, $true" & vbCrLf
  s = s & "    [System.IO.File]::WriteAllText($resultPath, $text, $enc)" & vbCrLf
  s = s & "}" & vbCrLf
  s = s & "" & vbCrLf
  s = s & "try {" & vbCrLf
  s = s & "    $ProfileName = 'LS_CORP'" & vbCrLf
  s = s & "    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()" & vbCrLf
  s = s & "    $principal = New-Object Security.Principal.WindowsPrincipal($identity)" & vbCrLf
  s = s & "    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {" & vbCrLf
  s = s & "        throw (U '\0417\0430\043F\0443\0441\0442\0438\0442\0435 PowerShell \043E\0442 \0438\043C\0435\043D\0438 \0430\0434\043C\0438\043D\0438\0441\0442\0440\0430\0442\043E\0440\0430.')" & vbCrLf
  s = s & "    }" & vbCrLf
  s = s & "" & vbCrLf
  s = s & "    $info = & netsh wlan show profile (""name=`""$ProfileName`"""") | Out-String" & vbCrLf
  s = s & "    $gp = U '\0433\0440\0443\043F\043F\043E\0432'" & vbCrLf
  s = s & "    if ($LASTEXITCODE -eq 0 -and $info -match ('Group Policy|' + $gp)) {" & vbCrLf
  s = s & "        throw (U 'LS_CORP \0432\044B\0434\0430\043D \0433\0440\0443\043F\043F\043E\0432\043E\0439 \043F\043E\043B\0438\0442\0438\043A\043E\0439. \041B\043E\043A\0430\043B\044C\043D\044B\0439 \043F\0440\043E\0444\0438\043B\044C \0435\0433\043E \043D\0435 \0437\0430\043C\0435\043D\0438\0442: \0432 GPO \0443 \043F\043E\043B\0438\0442\0438\043A\0438 IEEE 802.11 \043F\043E\0441\0442\0430\0432\044C\0442\0435 \0440\0435\0436\0438\043C \00AB\041F\0440\043E\0432\0435\0440\043A\0430 \043F\043E\0434\043B\0438\043D\043D\043E\0441\0442\0438 \043F\043E\043B\044C\0437\043E\0432\0430\0442\0435\043B\044F\00BB \0438 \0441\043D\0438\043C\0438\0442\0435 \0433\0430\043B\043A\0443 EAP-MSCHAPv2.')" & vbCrLf
  s = s & "    }" & vbCrLf
  s = s & "" & vbCrLf
  s = s & "    if ($LASTEXITCODE -eq 0) {" & vbCrLf
  s = s & "        $del = & netsh wlan delete profile (""name=`""$ProfileName`"""") | Out-String" & vbCrLf
  s = s & "        if ($LASTEXITCODE -ne 0) {" & vbCrLf
  s = s & "            $msg = $del.Trim()" & vbCrLf
  s = s & "            if (-not $msg) { $msg = ""netsh wlan delete profile failed with exit code $LASTEXITCODE"" }" & vbCrLf
  s = s & "            throw $msg" & vbCrLf
  s = s & "        }" & vbCrLf
  s = s & "    }" & vbCrLf
  s = s & "" & vbCrLf
  s = s & "    $ssidHex = (([Text.Encoding]::UTF8.GetBytes($ProfileName) | ForEach-Object { '{0:X2}' -f $_ }) -join '')" & vbCrLf
  s = s & "    $path = Join-Path $env:TEMP 'LS_CORP-user.xml'" & vbCrLf
  s = s & "    $xml = @'" & vbCrLf
  s = s & "<?xml version=""1.0""?>" & vbCrLf
  s = s & "<WLANProfile xmlns=""http://www.microsoft.com/networking/WLAN/profile/v1"">" & vbCrLf
  s = s & "  <name>__NAME__</name>" & vbCrLf
  s = s & "  <SSIDConfig>" & vbCrLf
  s = s & "    <SSID>" & vbCrLf
  s = s & "      <hex>__HEX__</hex>" & vbCrLf
  s = s & "      <name>__NAME__</name>" & vbCrLf
  s = s & "    </SSID>" & vbCrLf
  s = s & "  </SSIDConfig>" & vbCrLf
  s = s & "  <connectionType>ESS</connectionType>" & vbCrLf
  s = s & "  <connectionMode>auto</connectionMode>" & vbCrLf
  s = s & "  <MSM>" & vbCrLf
  s = s & "    <security>" & vbCrLf
  s = s & "      <authEncryption>" & vbCrLf
  s = s & "        <authentication>WPA2</authentication>" & vbCrLf
  s = s & "        <encryption>AES</encryption>" & vbCrLf
  s = s & "        <useOneX>true</useOneX>" & vbCrLf
  s = s & "      </authEncryption>" & vbCrLf
  s = s & "      <OneX xmlns=""http://www.microsoft.com/networking/OneX/v1"">" & vbCrLf
  s = s & "        <cacheUserData>true</cacheUserData>" & vbCrLf
  s = s & "        <authMode>user</authMode>" & vbCrLf
  s = s & "        <EAPConfig>" & vbCrLf
  s = s & "          <EapHostConfig xmlns=""http://www.microsoft.com/provisioning/EapHostConfig"">" & vbCrLf
  s = s & "            <EapMethod>" & vbCrLf
  s = s & "              <Type xmlns=""http://www.microsoft.com/provisioning/EapCommon"">25</Type>" & vbCrLf
  s = s & "              <VendorId xmlns=""http://www.microsoft.com/provisioning/EapCommon"">0</VendorId>" & vbCrLf
  s = s & "              <VendorType xmlns=""http://www.microsoft.com/provisioning/EapCommon"">0</VendorType>" & vbCrLf
  s = s & "              <AuthorId xmlns=""http://www.microsoft.com/provisioning/EapCommon"">0</AuthorId>" & vbCrLf
  s = s & "            </EapMethod>" & vbCrLf
  s = s & "            <Config xmlns=""http://www.microsoft.com/provisioning/EapHostConfig"">" & vbCrLf
  s = s & "              <Eap xmlns=""http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1"">" & vbCrLf
  s = s & "                <Type>25</Type>" & vbCrLf
  s = s & "                <EapType xmlns=""http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV1"">" & vbCrLf
  s = s & "                  <ServerValidation>" & vbCrLf
  s = s & "                    <DisableUserPromptForServerValidation>false</DisableUserPromptForServerValidation>" & vbCrLf
  s = s & "                    <ServerNames></ServerNames>" & vbCrLf
  s = s & "                  </ServerValidation>" & vbCrLf
  s = s & "                  <FastReconnect>true</FastReconnect>" & vbCrLf
  s = s & "                  <InnerEapOptional>false</InnerEapOptional>" & vbCrLf
  s = s & "                  <Eap xmlns=""http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1"">" & vbCrLf
  s = s & "                    <Type>26</Type>" & vbCrLf
  s = s & "                    <EapType xmlns=""http://www.microsoft.com/provisioning/MsChapV2ConnectionPropertiesV1"">" & vbCrLf
  s = s & "                      <UseWinLogonCredentials>false</UseWinLogonCredentials>" & vbCrLf
  s = s & "                    </EapType>" & vbCrLf
  s = s & "                  </Eap>" & vbCrLf
  s = s & "                  <EnableQuarantineChecks>false</EnableQuarantineChecks>" & vbCrLf
  s = s & "                  <RequireCryptoBinding>false</RequireCryptoBinding>" & vbCrLf
  s = s & "                  <PeapExtensions>" & vbCrLf
  s = s & "                    <PerformServerValidation xmlns=""http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV2"">true</PerformServerValidation>" & vbCrLf
  s = s & "                    <AcceptServerName xmlns=""http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV2"">false</AcceptServerName>" & vbCrLf
  s = s & "                    <PeapExtensionsV2 xmlns=""http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV2"">" & vbCrLf
  s = s & "                      <AllowPromptingWhenServerCANotFound xmlns=""http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV3"">true</AllowPromptingWhenServerCANotFound>" & vbCrLf
  s = s & "                    </PeapExtensionsV2>" & vbCrLf
  s = s & "                  </PeapExtensions>" & vbCrLf
  s = s & "                </EapType>" & vbCrLf
  s = s & "              </Eap>" & vbCrLf
  s = s & "            </Config>" & vbCrLf
  s = s & "          </EapHostConfig>" & vbCrLf
  s = s & "        </EAPConfig>" & vbCrLf
  s = s & "      </OneX>" & vbCrLf
  s = s & "    </security>" & vbCrLf
  s = s & "  </MSM>" & vbCrLf
  s = s & "</WLANProfile>" & vbCrLf
  s = s & "'@" & vbCrLf
  s = s & "    $xml = $xml.Replace('__NAME__', $ProfileName).Replace('__HEX__', $ssidHex)" & vbCrLf
  s = s & "    $utf8 = New-Object System.Text.UTF8Encoding $false" & vbCrLf
  s = s & "    [System.IO.File]::WriteAllText($path, $xml, $utf8)" & vbCrLf
  s = s & "" & vbCrLf
  s = s & "    try {" & vbCrLf
  s = s & "        $import = & netsh wlan add profile (""filename=`""$path`"""") 'user=all' | Out-String" & vbCrLf
  s = s & "        if ($LASTEXITCODE -ne 0) {" & vbCrLf
  s = s & "            $msg = $import.Trim()" & vbCrLf
  s = s & "            if (-not $msg) { $msg = ""netsh wlan add profile failed with exit code $LASTEXITCODE"" }" & vbCrLf
  s = s & "            throw $msg" & vbCrLf
  s = s & "        }" & vbCrLf
  s = s & "    } finally {" & vbCrLf
  s = s & "        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue" & vbCrLf
  s = s & "    }" & vbCrLf
  s = s & "" & vbCrLf
  s = s & "    $done = (U '\041F\0440\043E\0444\0438\043B\044C \0441\043E\0437\0434\0430\043D. \0412\043E\0439\0434\0438\0442\0435 \0432 Windows \0438 \043F\043E\0434\043A\043B\044E\0447\0438\0442\0435\0441\044C \043A __NAME__ \0447\0435\0440\0435\0437 \0437\043D\0430\0447\043E\043A Wi-Fi.').Replace('__NAME__', $ProfileName)" & vbCrLf
  s = s & "    Save-Result ($import.Trim() + [Environment]::NewLine + $done)" & vbCrLf
  s = s & "    exit 0" & vbCrLf
  s = s & "} catch {" & vbCrLf
  s = s & "    Save-Result $_.Exception.Message" & vbCrLf
  s = s & "    exit 1" & vbCrLf
  s = s & "}" & vbCrLf
  PowerShellSource = s
End Function
