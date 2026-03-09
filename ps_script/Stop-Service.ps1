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
    Write-Host 'No web/batch service management requested. Skipping stop-services.'
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
    throw 'No tenants detected. Cannot continue service stop operation.'
}

Write-Host "Detected Tenants: $($tenants -join ', ')"

$StopScriptBlock = {
    param($Tenant, $ServicePatterns)

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
                return $true
            }
            catch { Write-Warning "Service did not stop within $waitTime" }

            if ($attempt -lt $maxRetries) {
                Start-Sleep -Seconds $retryDelay
                $ServiceObject.Refresh()
            }
        }

        $ServiceObject.Refresh()
        if ($ServiceObject.Status -eq 'Stopped') { return $true }

        $svcCim = Get-CimInstance Win32_Service -Filter "Name='$($ServiceObject.Name)'"
        if ($svcCim -and $svcCim.ProcessId -ne 0) {
            try {
                Stop-Process -Id $svcCim.ProcessId -Force -ErrorAction Stop
                Start-Sleep -Seconds 3
                $ServiceObject.Refresh()
                if ($ServiceObject.Status -eq 'Stopped') { return $true }
            }
            catch { Write-Warning "PID kill failed: $($_.Exception.Message)" }
        }

        return $false
    }

    foreach ($pattern in $ServicePatterns) {
        $services = Get-Service | Where-Object {
            ($_.DisplayName -like "$pattern*$Tenant*") -or
            ($_.Name -like "$pattern*$Tenant*")
        }

        if (-not $services) { continue }

        foreach ($svc in $services) {
            $success = Stop-ServiceWithRetry -ServiceObject $svc
            if (-not $success) {
                throw "FAILED: Could not stop service '$($svc.DisplayName)'"
            }
        }
    }
}

foreach ($tenant in $tenants) {
    Write-Host "Stopping services for Tenant: $tenant"

    if ($ManageWebServices) {
        $webPatterns = @('FrontierNaming','Frontier Naming','FrontierApplication','Frontier Application','Frontier Tomcat','FrontierAPI','FrontierWF')
        foreach ($webServer in $webServers) {
            Invoke-Command -ComputerName $webServer -Credential $Credentials -UseSSL -ArgumentList $tenant, $webPatterns -ScriptBlock $StopScriptBlock
        }
    }

    if ($ManageBatchServices) {
        $batchPatterns = @('Frontier')
        Invoke-Command -ComputerName $batServer -Credential $Credentials -UseSSL -ArgumentList $tenant, $batchPatterns -ScriptBlock $StopScriptBlock
    }
}
