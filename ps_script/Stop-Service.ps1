param(
    [string]$Region,
    [string]$EnvPrefix,
    [ValidateSet('Dev','Test','Prod')][string]$env,
    [string]$PodId,
    [string]$User,
    [String]$Password
)

$ScriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
try {
    write-host "$ScriptDirectory\shared_functions.ps1"
    . ("$ScriptDirectory\shared_functions.ps1")
    
}catch{
    write-host "Import of shared_functions.ps1 failed!"
}

$SecurePassword = $password | ConvertTo-SecureString -AsPlainText -Force
$Credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $User, $SecurePassword

switch ($Env) {
    'Prod' { $domain = ".cloud.trintech.host" }
    'Test' { $domain = ".cloud.trintech.host" }
    'Dev'  { $domain = ".lower.trintech.host" }
    default { throw "Environment doesn't exist!" }
}

$webServer1 = $region + $envprefix + "DWEB-" + $PodId + "01" + $domain
$webServer2 = $region + $envprefix + "DWEB-" + $PodId + "02" + $domain
$batServer = $region + $envprefix + "TBAT-" + $PodId + "01" + $domain
$webServers = @($webServer1, $webServer2)

Write-Host "`nWeb Servers: $($webServers -join ', ')"
Write-Host "Batch Server: $batServer"

$tenants = Invoke-Command -ComputerName $webServer1 -Credential $Credentials -UseSSL -ScriptBlock {

    # Pull API Services from this server
    $tomcatServices = Get-CimInstance Win32_Service | Where-Object {
        $_.DisplayName -like 'Frontier Tomcat (*'
    }

    $tenantList = foreach ($svc in $tomcatServices) {
        # Extract tenant from service name
        if ($svc.Name -match '^(.+)_Frontier$') {
            $matches[1]
        }
    }

    # Return unique tenants
    $tenantList | Sort-Object -Unique
}

# Print results
Write-Host "`nWebServers: $webServers"
Write-Host "Detected Tenants: $tenants"
Write-Host ""


$StopScriptBlock = {

    param(
        $Tenant,
        $ServicePatterns
    )

    function Stop-ServiceWithRetry {
        param($ServiceObject)

        $maxRetries = 2
        $waitTime   = '00:00:20'
        $retryDelay = 5

        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {

            Write-Host "Attempt $attempt to stop service: $($ServiceObject.DisplayName)"

            if ($ServiceObject.Status -ne 'Stopped') {
                Stop-Service -InputObject $ServiceObject -Force -ErrorAction SilentlyContinue
            }

            try {
                $ServiceObject.Refresh()
                $ServiceObject.WaitForStatus('Stopped', $waitTime)

                Write-Host "Service stopped successfully"
                return $true
            }
            catch {
                Write-Warning "Service did not stop within $waitTime"
            }

            if ($attempt -lt $maxRetries) {
                Start-Sleep -Seconds $retryDelay
                $ServiceObject.Refresh()
            }
        }

        $ServiceObject.Refresh()

        if ($ServiceObject.Status -eq 'Stopped') {
            return $true
        }

        # ----- Last Resort: Kill underlying process -----
        Write-Warning "Service '$($ServiceObject.DisplayName)' did not stop gracefully. Attempting PID kill..."

        $svcCim = Get-CimInstance Win32_Service -Filter "Name='$($ServiceObject.Name)'"

        if ($svcCim -and $svcCim.ProcessId -ne 0) {
            try {
                Stop-Process -Id $svcCim.ProcessId -Force -ErrorAction Stop
                Start-Sleep -Seconds 3
                $ServiceObject.Refresh()

                if ($ServiceObject.Status -eq 'Stopped') {
                    Write-Host "Service forcefully terminated via PID."
                    return $true
                }
            }
            catch {
                Write-Warning "PID kill failed: $($_.Exception.Message)"
            }
        }

        return $false

    }

    Write-Host "`n[$env:COMPUTERNAME] Processing tenant: $Tenant"

    foreach ($pattern in $ServicePatterns) {

        $services = Get-Service | Where-Object {
            ($_.DisplayName -like "$pattern*$Tenant*") -or
            ($_.Name -like "$pattern*$Tenant*")
        }

        if (-not $services) {
            Write-Warning "No services found matching '$pattern' for tenant '$Tenant'"
            continue
        }

        foreach ($svc in $services) {

            $success = Stop-ServiceWithRetry -ServiceObject $svc

            if (-not $success) {
                throw "FAILED: Could not stop service '$($svc.DisplayName)'"
            }
        }
    }
}

# --------------------------------------------------
# Stop Services Per Tenant
# --------------------------------------------------
foreach ($tenant in $tenants) {

    Write-Host "`n=============================="
    Write-Host "Stopping services for Tenant: $tenant"
    Write-Host "=============================="

    # --- Web Servers ---
    $webPatterns = @(
        "FrontierNaming",
        "Frontier Naming",
        "FrontierApplication",
        "Frontier Application",
        "Frontier Tomcat",
        "FrontierAPI",
        "FrontierWF"
    )

    foreach ($webServer in $webServers) {
        Invoke-Command -ComputerName $webServer `
            -Credential $Credentials `
            -UseSSL `
            -ArgumentList $tenant, $webPatterns `
            -ScriptBlock $StopScriptBlock
    }

    # --- Batch Server ---
    $batchPatterns = @(
        "Frontier"
    )

    Invoke-Command -ComputerName $batServer `
        -Credential $Credentials `
        -UseSSL `
        -ArgumentList $tenant, $batchPatterns `
        -ScriptBlock $StopScriptBlock
}