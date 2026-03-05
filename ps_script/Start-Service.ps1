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
$webServers  = @($webServer1, $webServer2)

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

$StartScriptBlock = {
    param(
        [string]$Tenant,
        [string[]]$ServicePatterns,
        [int]$MaxRetries = 2,
        [int]$WaitSeconds = 20,
        [int]$RetryDelaySeconds = 5
    )

    function Get-MatchingServices {
        param([string]$Pattern, [string]$Tenant)

        # Match on DisplayName OR Name, allow tenant variants (Tenant_98, Tenant_App1, etc.)
        Get-Service | Where-Object {
            ($_.DisplayName -like "*$Pattern*$Tenant*") -or
            ($_.Name        -like "*$Pattern*$Tenant*")
        }
    }

    function Start-ServiceWithRetry {
        param([System.ServiceProcess.ServiceController]$Svc)

        if ($Svc.Status -eq 'Running') {
            Write-Host "Already running: $($Svc.DisplayName)"
            return
        }

        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                Write-Host "Starting: $($Svc.DisplayName) (attempt $attempt)"
                Start-Service -InputObject $Svc -ErrorAction Stop

                $Svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($WaitSeconds))
                $Svc.Refresh()

                if ($Svc.Status -eq 'Running') {
                    Write-Host "Started successfully: $($Svc.DisplayName)"
                    return
                }
            }
            catch {
                Write-Warning "Start attempt $attempt failed for '$($Svc.DisplayName)': $($_.Exception.Message)"
            }

            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds $RetryDelaySeconds
                $Svc.Refresh()
            }
        }

        $Svc.Refresh()
        throw "FAILED: Could not start service '$($Svc.DisplayName)' after $MaxRetries attempts."
    }

    Write-Host "`n[$env:COMPUTERNAME] Starting services for tenant: $Tenant"

    foreach ($pattern in $ServicePatterns) {

        $matches = Get-MatchingServices -Pattern $pattern -Tenant $Tenant

        if (-not $matches) {
            Write-Warning "No services found for pattern '$pattern' + tenant '$Tenant' on $env:COMPUTERNAME"
            continue
        }

        # If multiple match, start all (rare, but possible with tenant variants)
        foreach ($svc in $matches) {
            Start-ServiceWithRetry -Svc $svc
        }
    }
}

# ----------------------------
# Start per tenant
# ----------------------------
foreach ($tenant in $tenants) {

    Write-Host "`n=============================="
    Write-Host "Starting services for Tenant: $tenant"
    Write-Host "=============================="

    # Web order: Naming -> Application -> Tomcat -> API -> WF
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
            -ArgumentList $tenant, $webPatterns, 2, 20, 5 `
            -ErrorAction Stop `
            -ScriptBlock $StartScriptBlock
    }

    # Batch (Schedulers)
    $batchPatterns = @(
        "Frontier"
    )

    Invoke-Command -ComputerName $batServer `
        -Credential $Credentials `
        -UseSSL `
        -ArgumentList $tenant, $batchPatterns, 2, 20, 5 `
        -ErrorAction Stop `
        -ScriptBlock $StartScriptBlock
}