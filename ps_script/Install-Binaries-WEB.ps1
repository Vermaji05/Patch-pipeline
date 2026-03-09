param(
    [string]$Region,
    [string]$EnvPrefix,
    [ValidateSet('Dev','Test','Prod')][string]$Env,
    [string]$PodId,
    [string]$User,
    [String]$Password,
    [string]$PackageSubPath,
    [string]$FileMappings,
    [string]$BackupDir = 'D:\Apps\Backup_exe'
)

$ScriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
try {
    . ("$ScriptDirectory\shared_functions.ps1")
}catch{
    Write-Host "Import of shared_functions.ps1 failed!"
}

function Parse-FileMappings {
    param([string]$Mappings)

    if ([string]::IsNullOrWhiteSpace($Mappings)) { return @() }

    if ($Mappings.Trim().ToUpperInvariant() -in @('SKIP','NONE','N/A','NA')) { return @() }

    $parsed = @()
    foreach ($entry in ($Mappings -split ';')) {
        $trimmed = $entry.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        $parts = $trimmed -split '\|', 2
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
            throw "Invalid mapping format '$trimmed'. Use: sourceFileName|fullDestinationPath"
        }

        $parsed += [PSCustomObject]@{
            SourceFileName = $parts[0].Trim()
            DestinationPath = $parts[1].Trim()
        }
    }

    return $parsed
}

$SecurePassword = $Password | ConvertTo-SecureString -AsPlainText -Force
$Credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $User, $SecurePassword

switch ($Env) {
    'Prod' {
        $domain = '.cloud.trintech.host'
        $packageShareBase = '\\cloud\NETLOGON\cloud_files'
    }
    'Test' {
        $domain = '.cloud.trintech.host'
        $packageShareBase = '\\cloud\NETLOGON\cloud_files'
    }
    'Dev' {
        $domain = '.lower.trintech.host'
        $packageShareBase = '\\Lower\NETLOGON\cloud_files'
    }
    default { throw "Selected environment type doesn't exist!" }
}

if ([string]::IsNullOrWhiteSpace($PackageSubPath)) {
    throw 'PackageSubPath is required.'
}

$packageShare = Join-Path $packageShareBase $PackageSubPath
$fileMap = Parse-FileMappings -Mappings $FileMappings

if (-not $fileMap -or $fileMap.Count -eq 0) {
    Write-Warning 'No file mappings provided for WEB. Skipping deployment.'
    exit 0
}

$servers = @(
    ($Region + $EnvPrefix + 'DWEB-' + $PodId + '01' + $domain),
    ($Region + $EnvPrefix + 'DWEB-' + $PodId + '02' + $domain)
)

Write-Host "Servers: $($servers -join ', ')"
Write-Host "Package Share: $packageShare"

$resolvedMap = @()
foreach ($item in $fileMap) {
    $sourceFile = Join-Path $packageShare $item.SourceFileName
    if (-not (Test-Path -LiteralPath $sourceFile)) {
        throw "Source file not found on share: $sourceFile"
    }

    $resolvedMap += [PSCustomObject]@{
        SourcePath = $sourceFile
        DestinationPath = $item.DestinationPath
    }
}

foreach ($server in $servers) {
    Write-Host "`n==== Deploying files on $server ===="

    try {
        Invoke-Command -ComputerName $server -Credential $Credentials -Authentication CredSSP -UseSSL -ArgumentList $resolvedMap, $BackupDir -ErrorAction Stop -ScriptBlock {
            param(
                [object[]]$ResolvedMap,
                [string]$BackupDir
            )

            function Write-Log($msg) {
                $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                Write-Host "[$env:COMPUTERNAME][$ts] $msg"
            }

            foreach ($file in $ResolvedMap) {
                $source = $file.SourcePath
                $dest = $file.DestinationPath

                Write-Log "Source: $source"
                Write-Log "Dest:   $dest"

                if (-not (Test-Path -LiteralPath $source)) { throw "Source not accessible: $source" }
                if (-not (Test-Path -LiteralPath $dest))   { throw "Destination not found: $dest" }

                $procName = [IO.Path]::GetFileNameWithoutExtension($dest)
                $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
                if ($procs) {
                    Write-Log "Stopping process: $procName"
                    $procs | Stop-Process -Force
                    Start-Sleep -Seconds 2
                }

                if (-not (Test-Path -LiteralPath $BackupDir)) {
                    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
                    Write-Log "Created backup dir: $BackupDir"
                }

                $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                $destName = [IO.Path]::GetFileName($dest)
                $backupPath = Join-Path $BackupDir "$destName.$timestamp.bak"

                Copy-Item -LiteralPath $dest -Destination $backupPath -Force -ErrorAction Stop

                $srcHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
                Copy-Item -LiteralPath $source -Destination $dest -Force -ErrorAction Stop
                $dstHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash

                if ($dstHash -ne $srcHash) {
                    throw "Hash verification failed for $dest"
                }

                Write-Log "Updated successfully: $dest"
            }
        }

        Write-Host "Done on $server"
    }
    catch {
        Write-Host "Failed on $server : $($_.Exception.Message)"
    }
}
