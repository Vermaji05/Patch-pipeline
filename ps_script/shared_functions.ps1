function ConnectToAzure{

    $clientid = "$Env:KEYVAULT_CLIENTID"
    $clientsecret = "$Env:KEYVAULT_CLIENTSECRET"
    if (!(Get-Module Az.KeyVault -ListAvailable))
    {
        Install-Module Az.KeyVault -Force
        Install-Module Az.resources -Force
    }

    switch ($env:USERDOMAIN)
    {
        "Lower" {$subscription = "005b6d44-1494-420c-9424-3094db5568b8"}
        "Cloud" {$subscription = "ed21a5bf-85f3-47a3-a063-229994914491"}
        "Cadency" {$subscription = "ed21a5bf-85f3-47a3-a063-229994914491"}
        default {$subscription = "ed21a5bf-85f3-47a3-a063-229994914491"}
    }

    $TenantId  = 'a6990654-25eb-4d90-9f25-a558d2bf582f'

    $pw = convertto-securestring -string "$clientsecret" -asplaintext -force

    $azureAppCred = (New-Object System.Management.Automation.PSCredential "$clientid", $pw)

    Connect-AzAccount -ServicePrincipal -SubscriptionId $subscription -TenantId $tenantId -Credential $azureAppCred
    write-host "Connected to Azure successfully!"
    return 0
}

function GetSecret {

Param(
        [Parameter(Mandatory=$true)]
        [string[]]
        $secretname
    )
    
    ConnectToAzure | Out-Null

    $vaultname = "$Env:KV"
    try{
        $secretkey = Get-AzKeyVaultSecret -VaultName "$vaultname" -Name "$secretname" -erroraction stop
    }catch{
        write-host "Error getting secret $secretname - Issue with Get-AzKeyVaultSecret"
        return -1
    }
    try{
        $secretvalue = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretkey.SecretValue))
        return $secretvalue
    }catch{
        write-host "Error getting secret $secretname - Secret probably doesn't exist so this can be ignored!"
        return 1
    }
}

function SetSecret {

Param(
        [Parameter(Mandatory=$true)]
        [string[]]
        $secretname,
        [Parameter(Mandatory=$true)]
        [string[]]
        $secretvalue
    )
    
    ConnectToAzure | Out-Null
    $vaultname = "$Env:KV"        
    try{
        set-azkeyvaultsecret -VaultName "$vaultname" -Name "$secretname" -SecretValue $(convertto-securestring -string "$secretvalue" -asplaintext -force)
        return 0
    }catch{
        write-host "Error setting secret $secretname"
        return 1
    }
}

function Get-RandomCharacters($length, $characters) { 
    $random = 1..$length | ForEach-Object { Get-Random -Maximum $characters.length } 
    $private:ofs="" 
    return [String]$characters[$random]
}

function GeneratePassword {

    try{
        $password = Get-RandomCharacters -length 4 -characters 'abcdefghiklmnoprstuvwxyz'
        $password += Get-RandomCharacters -length 4 -characters 'ABCDEFGHKLMNOPRSTUVWXYZ'
        $password += Get-RandomCharacters -length 1 -characters '1234567890'
        $password += Get-RandomCharacters -length 1 -characters '!%/()?}][{*'   
        $characterArray = $password.ToCharArray()   
        $scrambledStringArray = $characterArray | Get-Random -Count $characterArray.Length     
        $outputString = -join $scrambledStringArray
        return $outputString 
    }catch{
        write-host "Error generating service account password!"
        return 1
    }
}

function GenerateEncryptionKey {

    try{
        $password = Get-RandomCharacters -length 10 -characters 'abcdefghiklmnoprstuvwxyz'
        $password += Get-RandomCharacters -length 10 -characters 'ABCDEFGHKLMNOPRSTUVWXYZ'
        $password += Get-RandomCharacters -length 10 -characters '1234567890'
        $characterArray = $password.ToCharArray()   
        $scrambledStringArray = $characterArray | Get-Random -Count $characterArray.Length     
        $outputString = -join $scrambledStringArray
        return $outputString 
    }catch{
        write-host "Error generating encryption key!"
        return 1
    }
}



