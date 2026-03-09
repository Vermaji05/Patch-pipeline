param(
    [string]$Region,
    [string]$EnvPrefix,
    [ValidateSet('Dev','Test','Prod')][string]$Env,
    [string]$PodId,
    [string]$User,
    [String]$Password,
    [object]$ManageWebServices = $true,
    [object]$ManageBatchServices = $true
)

$ScriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
try {
    . ("$ScriptDirectory\shared_functions.ps1")
}catch{
    Write-Host "Import of shared_functions.ps1 failed!"
}


function ConvertTo-Bool {
    param([object]$Value, [bool]$Default = $false)

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }

    $text = $Value.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    switch -Regex ($text.ToLowerInvariant()) {
        '^(true|1|yes|y)$' { return $true }
        '^(false|0|no|n)$' { return $false }
        default { throw "Invalid boolean value '$Value'. Use True/False or 1/0." }
    }
}

$ManageWebServices = ConvertTo-Bool -Value $ManageWebServices -Default $true
$ManageBatchServices = ConvertTo-Bool -Value $ManageBatchServices -Default $true

if (-not $ManageWebServices -and -not $ManageBatchServices) {
    Write-Host 'No web/batch service management requested. Skipping start-services.'
    exit 0
}

$SecurePassword = $Password | ConvertTo-SecureString -AsPlainText -Force
$Credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $User, $SecurePassword

switch ($Env) {
    'Prod' { $domain = '.cloud.trintech.host' }
    'Test' { $domain = '.cloud.trintech.host' }
    'Dev'  { $domain = '.lower.trintech.host' }
    default { throw "Environment doesn't exist!" }
}

$webServers = @(
    ($Region + $EnvPrefix + 'DWEB-' + $PodId + '01' + $domain),
    ($Region + $EnvPrefix + 'DWEB-' + $PodId + '02' + $domain)
)
$batServer = $Region + $EnvPrefix + 'TBAT-' + $PodId + '01' + $domain

$webServer1 = $Region + $EnvPrefix + 'DWEB-' + $PodId + '01' + $domain

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

if (-not $tenants -or $tenants.Count -eq 0) {
    throw 'No tenants detected. Cannot continue service start operation.'
}

Write-Host "Detected Tenants: $($tenants -join ', ')"

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
        Get-Service | Where-Object {
            ($_.DisplayName -like "*$Pattern*$Tenant*") -or
            ($_.Name -like "*$Pattern*$Tenant*")
        }
    }

    function Start-ServiceWithRetry {
        param([System.ServiceProcess.ServiceController]$Svc)

        if ($Svc.Status -eq 'Running') { return }

        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                Start-Service -InputObject $Svc -ErrorAction Stop
                $Svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($WaitSeconds))
                $Svc.Refresh()
                if ($Svc.Status -eq 'Running') { return }
            }
            catch {
                Write-Warning "Start attempt $attempt failed for '$($Svc.DisplayName)': $($_.Exception.Message)"
            }

            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds $RetryDelaySeconds
                $Svc.Refresh()
            }
        }

        throw "FAILED: Could not start service '$($Svc.DisplayName)' after $MaxRetries attempts."
    }

    foreach ($pattern in $ServicePatterns) {
        $matches = Get-MatchingServices -Pattern $pattern -Tenant $Tenant
        if (-not $matches) { continue }

        foreach ($svc in $matches) {
            Start-ServiceWithRetry -Svc $svc
        }
    }
}

foreach ($tenant in $tenants) {
    Write-Host "Starting services for Tenant: $tenant"

    if ($ManageWebServices) {
        $webPatterns = @('FrontierNaming','Frontier Naming','FrontierApplication','Frontier Application','Frontier Tomcat','FrontierAPI','FrontierWF')
        foreach ($webServer in $webServers) {
            Invoke-Command -ComputerName $webServer -Credential $Credentials -UseSSL -ArgumentList $tenant, $webPatterns, 2, 20, 5 -ErrorAction Stop -ScriptBlock $StartScriptBlock
        }
    }

    if ($ManageBatchServices) {
        $batchPatterns = @('Frontier')
        Invoke-Command -ComputerName $batServer -Credential $Credentials -UseSSL -ArgumentList $tenant, $batchPatterns, 2, 20, 5 -ErrorAction Stop -ScriptBlock $StartScriptBlock
    }
}
