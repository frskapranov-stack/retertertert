# Adds Instagram + Cursor FQDN lists to the Keenetic VPN DNS route at 192.168.3.1.
# Password: $env:KEENETIC_PASSWORD or -Password. Never stored.
param(
    [string]$Router = '192.168.3.1',
    [string]$User = 'admin',
    [string]$Password = $env:KEENETIC_PASSWORD,
    [string]$ResultPath = $(Join-Path $env:TEMP 'vpn-routes-result.txt'),
    [switch]$PrintDomains
)

$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function U([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $s.Length) {
        if ($s[$i] -eq [char]92 -and ($i + 4) -lt $s.Length) {
            [void]$sb.Append([char][Convert]::ToInt32($s.Substring($i + 1, 4), 16))
            $i += 5
        } else {
            [void]$sb.Append($s[$i])
            $i += 1
        }
    }
    $sb.ToString()
}

function Save-Result([string]$text) {
    $enc = New-Object System.Text.UnicodeEncoding $false, $true
    [System.IO.File]::WriteAllText($ResultPath, $text, $enc)
}

function Get-Md5Hex([string]$text) {
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $md5.Dispose()
    }
}

function Get-Sha256Hex([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
}

function Read-DomainFile([string]$path, [string[]]$fallback) {
    if (Test-Path -LiteralPath $path) {
        return Get-Content -LiteralPath $path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and ($_ -notmatch '^\s*#') }
    }
    return $fallback
}

function Normalize-Domain([string]$d) {
    $d = $d.Trim().ToLowerInvariant()
    $d = $d -replace '^https?://', ''
    $d = $d -replace '/.*$', ''
    $d = $d -replace '^\*\.', ''
    return $d
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$instagram = @(Read-DomainFile (Join-Path $scriptDir 'vpn\instagram-domains.txt') @(
    'instagram.com', 'ig.me', 'cdninstagram.com', 'facebook.com', 'facebook.net',
    'fbcdn.net', 'fbsbx.com', 'fb.com', 'meta.com', 'internalfb.com'
)) | ForEach-Object { Normalize-Domain $_ } | Where-Object { $_ } | Select-Object -Unique

$cursor = @(Read-DomainFile (Join-Path $scriptDir 'vpn\cursor-domains.txt') @(
    'cursor.com', 'cursor.sh', 'cursor-cdn.com', 'cursorapi.com', 'cursorvm.com',
    'accounts.spacex.ai', 'accounts.x.ai',
    'anysphere-binaries.s3.us-east-1.amazonaws.com',
    'agent-stores.s3.us-east-1.amazonaws.com',
    'agent-stores.s3.amazonaws.com',
    'cursor.blob.core.windows.net'
)) | ForEach-Object { Normalize-Domain $_ } | Where-Object { $_ } | Select-Object -Unique

if ($PrintDomains) {
    Write-Output 'Instagram:'
    $instagram | ForEach-Object { Write-Output $_ }
    Write-Output 'Cursor:'
    $cursor | ForEach-Object { Write-Output $_ }
    exit 0
}

$script:Cookies = New-Object Net.CookieContainer
$script:BaseUrl = $null

function Send-Http {
    param(
        [string]$Method,
        [string]$Path,
        [string]$Body
    )
    $url = "$script:BaseUrl$Path"
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Method = $Method
    $req.CookieContainer = $script:Cookies
    $req.Timeout = 12000
    $req.ReadWriteTimeout = 20000
    $req.KeepAlive = $true
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'vpn-routes'
    $req.Accept = 'application/json, */*'
    if ($Method -ne 'GET' -and $null -ne $Body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/json; charset=utf-8'
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }
    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [Net.WebException] {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
    }
    try {
        $code = [int]$resp.StatusCode
        $headers = @{}
        foreach ($h in $resp.Headers.AllKeys) { $headers[$h] = $resp.Headers[$h] }
        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        $text = $reader.ReadToEnd()
        $reader.Close()
        return @{ Status = $code; Body = $text; Headers = $headers }
    } finally {
        if ($resp) { $resp.Close() }
    }
}

function Get-Header([hashtable]$headers, [string]$name) {
    foreach ($k in $headers.Keys) {
        if ([string]::Equals($k, $name, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]$headers[$k]
        }
    }
    return $null
}

function Connect-Keenetic {
    param([string[]]$candidates)

    $last = $null
    foreach ($base in $candidates) {
        $script:BaseUrl = $base.TrimEnd('/')
        $script:Cookies = New-Object Net.CookieContainer
        try {
            return Send-Http GET '/auth'
        } catch {
            $last = $_
        }
    }
    if ($last) { throw $last.Exception }
    throw U('\041D\0435 \0443\0434\0430\043B\043E\0441\044C \043F\043E\0434\043A\043B\044E\0447\0438\0442\044C\0441\044F \043A \0440\043E\0443\0442\0435\0440\0443.')
}

function Find-RciErrors($node, [System.Collections.Generic.List[string]]$sink) {
    if ($null -eq $node) { return }
    if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
        foreach ($item in $node) { Find-RciErrors $item $sink }
        return
    }
    $props = $node.PSObject.Properties
    if ($props['status'] -and $props['status'].Value) {
        $st = $props['status'].Value
        if ($st -is [string] -and $st -eq 'error') {
            $msg = ''
            if ($props['message']) { $msg = [string]$props['message'].Value }
            if (-not $msg) { $msg = 'RCI error' }
            $sink.Add($msg)
        } else {
            Find-RciErrors $st $sink
        }
    }
    foreach ($p in $props) {
        if ($p.Name -eq 'status') { continue }
        Find-RciErrors $p.Value $sink
    }
}

function Send-Rci([string]$json) {
    $r = Send-Http POST '/rci/' $json
    if ($r.Status -eq 401) {
        throw U('\041D\0435\0432\0435\0440\043D\044B\0439 \043B\043E\0433\0438\043D \0438\043B\0438 \043F\0430\0440\043E\043B\044C.')
    }
    if ($r.Status -ne 200) {
        $snippet = $r.Body
        if ($snippet.Length -gt 240) { $snippet = $snippet.Substring(0, 240) }
        throw "RCI HTTP $($r.Status): $snippet"
    }
    if ([string]::IsNullOrWhiteSpace($r.Body)) { return $null }
    $parsed = $r.Body | ConvertFrom-Json
    $errs = New-Object 'System.Collections.Generic.List[string]'
    Find-RciErrors $parsed $errs
    if ($errs.Count -gt 0) {
        throw (($errs | Select-Object -Unique) -join '; ')
    }
    return $parsed
}

function Send-Parse([string[]]$lines) {
    $parts = foreach ($line in $lines) {
        '{"parse":' + (ConvertTo-Json $line -Compress) + '}'
    }
    return Send-Rci ('[' + ($parts -join ',') + ']')
}

function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    foreach ($x in $obj.PSObject.Properties) {
        if ([string]::Equals($x.Name, $name, [StringComparison]::OrdinalIgnoreCase)) { return $x.Value }
    }
    return $null
}

function Get-IncludeAddresses($include) {
    $out = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $include) { return @() }
    if ($include -is [string]) { return @(Normalize-Domain $include) }
    foreach ($item in @($include)) {
        if ($item -is [string]) {
            $n = Normalize-Domain $item
            if ($n) { [void]$out.Add($n) }
        } else {
            $a = Get-Prop $item 'address'
            if (-not $a) { $a = Get-Prop $item 'Address' }
            if ($a) {
                $n = Normalize-Domain ([string]$a)
                if ($n) { [void]$out.Add($n) }
            }
        }
    }
    return @($out)
}

function Convert-ToMap($obj) {
    $map = @{}
    if ($null -eq $obj) { return $map }
    if ($obj -is [System.Collections.IDictionary]) {
        foreach ($k in $obj.Keys) { $map[[string]$k] = $obj[$k] }
        return $map
    }
    foreach ($p in $obj.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $map[$p.Name] = $p.Value
    }
    return $map
}

try {
    if ([string]::IsNullOrWhiteSpace($Password)) {
        throw U('\041F\0430\0440\043E\043B\044C \043D\0435 \0437\0430\0434\0430\043D.')
    }

    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }

    $probe = Connect-Keenetic @(
        ("http://{0}" -f $Router),
        ("https://{0}" -f $Router)
    )

    $realm = Get-Header $probe.Headers 'X-NDM-Realm'
    $challenge = Get-Header $probe.Headers 'X-NDM-Challenge'
    if (-not $challenge) {
        $www = Get-Header $probe.Headers 'WWW-Authenticate'
        if ($www -match 'realm="([^"]+)"') { $realm = $Matches[1] }
        if ($www -match 'challenge="([^"]+)"') { $challenge = $Matches[1] }
    }
    if (-not $challenge -or -not $realm) {
        throw U('\042D\0442\043E \043D\0435 Keenetic RCI (\043D\0435\0442 X-NDM-Challenge). \041E\0442\043A\0440\043E\0439\0442\0435 \0432\0435\0431-\0438\043D\0442\0435\0440\0444\0435\0439\0441 \0440\043E\0443\0442\0435\0440\0430 \0438 \0434\043E\0431\0430\0432\044C\0442\0435 \0434\043E\043C\0435\043D\044B \0432\0440\0443\0447\043D\0443\044E \0432 \043C\0430\0440\0448\0440\0443\0442\044B DNS.')
    }

    $md5 = Get-Md5Hex ("{0}:{1}:{2}" -f $User, $realm, $Password)
    $authBody = { param($key) '{"login":' + (ConvertTo-Json $User -Compress) + ',"password":' + (ConvertTo-Json $key -Compress) + '}' }
    $login = Send-Http POST '/auth' (& $authBody (Get-Sha256Hex ($challenge + $md5)))
    if ($login.Status -ne 200) {
        $login = Send-Http POST '/auth' (& $authBody (Get-Md5Hex ($challenge + $md5)))
    }
    if ($login.Status -ne 200) {
        throw U('\041D\0435\0432\0435\0440\043D\044B\0439 \043B\043E\0433\0438\043D \0438\043B\0438 \043F\0430\0440\043E\043B\044C.')
    }

    $ver = $null
    try { $ver = Send-Rci '{"show":{"version":{}}}' } catch { }
    if ($ver -is [System.Collections.IEnumerable] -and -not ($ver -is [string])) {
        $ver = @($ver) | Select-Object -First 1
    }
    $model = ''
    $title = ''
    if ($ver) {
        $model = [string](Get-Prop $ver 'model')
        $title = [string](Get-Prop $ver 'title')
    }

    $ifsRaw = Send-Rci '{"show":{"interface":{}}}'
    $ifs = Convert-ToMap $ifsRaw
    $vpnTypes = @(
        'Wireguard', 'OpenVPN', 'SSTP', 'PPTP', 'L2TP', 'IPsec',
        'OpenConnect', 'CTun', 'WireguardPeer'
    )

    $groupsRaw = $null
    $routesRaw = $null
    try { $groupsRaw = Send-Rci '{"show":{"sc":{"object-group":{"fqdn":{}}}}}' } catch { }
    try { $routesRaw = Send-Rci '{"show":{"sc":{"dns-proxy":{"route":{}}}}}' } catch { }

    $groups = Convert-ToMap $groupsRaw
    $routes = @()
    if ($routesRaw) {
        if ($routesRaw -is [System.Collections.IEnumerable] -and -not ($routesRaw -is [string]) -and -not ($routesRaw.PSObject.Properties['group'] -or $routesRaw.PSObject.Properties['Group'])) {
            $routes = @($routesRaw)
        } else {
            $routeMap = Convert-ToMap $routesRaw
            if ($routeMap.ContainsKey('group') -or $routeMap.ContainsKey('interface')) {
                $routes = @($routesRaw)
            } else {
                $routes = @($routeMap.Values)
            }
        }
    }

    $preferredIface = $null
    foreach ($rt in $routes) {
        $ifaceName = Get-Prop $rt 'interface'
        if (-not $ifaceName) { $ifaceName = Get-Prop $rt 'Interface' }
        if ($ifaceName) { $preferredIface = [string]$ifaceName; break }
    }

    $vpnIfaces = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $ifs.Keys) {
        $body = $ifs[$name]
        $typ = [string](Get-Prop $body 'type')
        $id = [string](Get-Prop $body 'id')
        if (-not $id) { $id = $name }
        $desc = [string](Get-Prop $body 'description')
        $connected = [string](Get-Prop $body 'connected')
        $state = [string](Get-Prop $body 'state')
        $link = [string](Get-Prop $body 'link')
        $isVpn = $false
        foreach ($t in $vpnTypes) {
            if ([string]::Equals($typ, $t, [StringComparison]::OrdinalIgnoreCase)) { $isVpn = $true; break }
        }
        if (-not $isVpn) {
            $blob = ($id + ' ' + $desc + ' ' + $typ)
            if ($blob -match '(?i)wireguard|amnezia|openvpn|sstp|pptp|l2tp|ipsec|outline|vpn') { $isVpn = $true }
        }
        if ($isVpn) {
            $up = ($connected -eq 'yes' -or $state -eq 'up' -or $link -eq 'up')
            [void]$vpnIfaces.Add(@{ Id = $id; Description = $desc; Type = $typ; Up = $up })
        }
    }

    $vpn = $null
    if ($preferredIface) {
        foreach ($v in $vpnIfaces) {
            if ([string]::Equals($v.Id, $preferredIface, [StringComparison]::OrdinalIgnoreCase)) { $vpn = $v; break }
        }
        if (-not $vpn) { $vpn = @{ Id = $preferredIface; Description = ''; Type = ''; Up = $true } }
    }
    if (-not $vpn) { $vpn = $vpnIfaces | Where-Object { $_.Up } | Select-Object -First 1 }
    if (-not $vpn) { $vpn = $vpnIfaces | Select-Object -First 1 }
    if (-not $vpn) {
        throw U('\041D\0430 \0440\043E\0443\0442\0435\0440\0435 \043D\0435\0442 VPN-\0438\043D\0442\0435\0440\0444\0435\0439\0441\0430 (WireGuard / Amnezia / OpenVPN). \041F\043E\0434\043D\0438\043C\0438\0442\0435 \0442\0443\043D\043D\0435\043B\044C \0438 \0437\0430\043F\0443\0441\0442\0438\0442\0435 \0441\043A\0440\0438\043F\0442 \0441\043D\043E\0432\0430.')
    }

    $existingByGroup = @{}
    foreach ($gName in $groups.Keys) {
        $existingByGroup[$gName] = @(Get-IncludeAddresses (Get-Prop $groups[$gName] 'include'))
    }

    function Find-GroupByHint([string]$hint) {
        foreach ($gName in $groups.Keys) {
            if ([string]::Equals($gName, $hint, [StringComparison]::OrdinalIgnoreCase)) { return $gName }
            $desc = [string](Get-Prop $groups[$gName] 'description')
            if ([string]::Equals($desc, $hint, [StringComparison]::OrdinalIgnoreCase)) { return $gName }
        }
        return $null
    }

    function Next-ListName {
        $i = 0
        while ($groups.ContainsKey("domain-list$i") -or $existingByGroup.ContainsKey("domain-list$i")) { $i++ }
        return "domain-list$i"
    }

    function Group-HasRoute([string]$groupName) {
        foreach ($rt in $routes) {
            $g = Get-Prop $rt 'group'
            if (-not $g) { $g = Get-Prop $rt 'object-group' }
            if ($g -and [string]::Equals([string]$g, $groupName, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    function Send-FqdnIncludes {
        param(
            [string]$GroupName,
            [string]$Description,
            [string[]]$Domains
        )
        if ($Domains.Count -eq 0 -and -not $Description) { return }
        $includeJson = @($Domains | ForEach-Object { '{"address":' + (ConvertTo-Json $_ -Compress) + '}' }) -join ','
        $inner = ''
        if ($Description) { $inner += '"description":' + (ConvertTo-Json $Description -Compress) + ',' }
        if ($Domains.Count -gt 0) { $inner += '"include":[' + $includeJson + ']' }
        $inner = $inner.TrimEnd(',')
        $json = '[{"object-group":{"fqdn":{' + (ConvertTo-Json $GroupName -Compress) + ':{' + $inner + '}}}}]'
        Send-Rci $json
    }

    function Ensure-Service {
        param(
            [string]$HintName,
            [string]$Description,
            [string[]]$Domains
        )
        $groupName = Find-GroupByHint $HintName
        $created = $false
        if (-not $groupName) {
            $groupName = $HintName
            $created = $true
        }
        $have = @()
        if ($existingByGroup.ContainsKey($groupName)) { $have = @($existingByGroup[$groupName]) }
        $missing = @($Domains | Where-Object { $have -notcontains $_ })

        $apply = {
            param($name, $newOnly)
            if ($created) {
                Send-FqdnIncludes -GroupName $name -Description $Description -Domains $newOnly
            } elseif ($newOnly.Count -gt 0) {
                Send-FqdnIncludes -GroupName $name -Description '' -Domains $newOnly
            }
            if (-not (Group-HasRoute $name)) {
                Send-Parse @("dns-proxy route object-group $name $($vpn.Id) auto")
            }
        }

        try {
            & $apply $groupName $missing
        } catch {
            if (-not $created) { throw }
            $groupName = Next-ListName
            $missing = $Domains
            $created = $true
            & $apply $groupName $missing
        }
        $existingByGroup[$groupName] = @($have + $missing | Select-Object -Unique)
        $groups[$groupName] = $true
        return @{ Name = $groupName; Added = $missing.Count; Total = $Domains.Count }
    }

    $ig = Ensure-Service -HintName 'Instagram' -Description 'Instagram' -Domains $instagram
    $cu = Ensure-Service -HintName 'Cursor' -Description 'Cursor' -Domains $cursor
    try { Send-Parse @('system configuration save') } catch { Send-Rci '{"system":{"configuration":{"save":{}}}}' }

    $head = @()
    if ($model -or $title) { $head += ("{0} {1}" -f $model, $title).Trim() }
    $head += ("VPN: {0}" -f $vpn.Id)
    if ($vpn.Description) { $head[-1] = $head[-1] + (" ({0})" -f $vpn.Description) }
    $head += ("Instagram ({0}): +{1} {2}" -f $ig.Name, $ig.Added, (U '\0434\043E\043C\0435\043D\043E\0432'))
    $head += ("Cursor ({0}): +{1} {2}" -f $cu.Name, $cu.Added, (U '\0434\043E\043C\0435\043D\043E\0432'))
    $head += U('\041A\043E\043D\0444\0438\0433\0443\0440\0430\0446\0438\044F \0441\043E\0445\0440\0430\043D\0435\043D\0430. DNS \043D\0430 \0443\0441\0442\0440\043E\0439\0441\0442\0432\0430\0445 \2014 \0440\043E\0443\0442\0435\0440, \043D\0435 Private DNS.')
    Save-Result ($head -join [Environment]::NewLine)
    exit 0
} catch {
    $msg = $_.Exception.Message
    if ($msg -match 'timed out|Unable to connect|actively refused|No such host|The remote name') {
        $msg = U('\0420\043E\0443\0442\0435\0440 192.168.3.1 \043D\0435\0434\043E\0441\0442\0443\043F\0435\043D. \0417\0430\043F\0443\0441\0442\0438\0442\0435 vpn-routes.vbs \0441 \043A\043E\043C\043F\044C\044E\0442\0435\0440\0430 \0432 \0434\043E\043C\0430\0448\043D\0435\0439 \0441\0435\0442\0438.')
    }
    Save-Result $msg
    exit 1
}
