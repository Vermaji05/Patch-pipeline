param(
    [string]$Region,
    [string]$EnvPrefix,
    [ValidateSet('Dev','Test','Prod')][string]$Env,
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

$SecurePassword = $Password | ConvertTo-SecureString -AsPlainText -Force
$Credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $User, $SecurePassword

switch ($Env) {
    'Prod' { 
        $domain = '.cloud.trintech.host'
        $packageShare = "\\cloud\NETLOGON\cloud_files\Frontier\Frontier_Release\2025_1\Frontier Install Packages\RDP\"
    }
    'Test' {
        $domain = '.cloud.trintech.host'
        $packageShare = "\\cloud\NETLOGON\cloud_files\Frontier\Frontier_Release\2025_1\Frontier Install Packages\RDP\"
    }
    'Dev' {
        $domain = '.lower.trintech.host'
        $packageShare = "\\Lower\NETLOGON\cloud_files\Frontier\Frontier_Release\2025_1\Frontier Install Packages\RDP\"
    }
    default { throw "Selected environment type doesn't exist!" }
}

$webServer1 = $Region + $EnvPrefix + 'DWEB-' + $PodId + '01' + $domain
$webServer2 = $Region + $EnvPrefix + 'DWEB-' + $PodId + '02' + $domain
$servers = @($webServer1, $webServer2)

Write-Host "`nServers:"
$servers | ForEach-Object { Write-Host $_ }

$BackupDir = "D:\apps\Backup_exe"

# Destinations
$DestRecolectExe = "D:\apps\Frontier\Rpswin\recolect.exe"
$DestMidTierExe  = "D:\apps\Frontier\midtier\updatereportdefs.exe"

# Sources
$SourceRecolectExe = Join-Path $packageShare "recolect.exe"
$SourceMidTierExe  = Join-Path $packageShare "updatereportdefs.exe"

# Validate sources locally
if (-not (Test-Path -LiteralPath $SourceRecolectExe)) { throw "Source exe not found on share: $SourceRecolectExe" }
if (-not (Test-Path -LiteralPath $SourceMidTierExe))  { throw "Source exe not found on share: $SourceMidTierExe" }

foreach ($server in $servers) {
    Write-Host "`n==== Updating EXEs on $server ===="

    try {
        Invoke-Command -ComputerName $server `
            -Credential $Credentials `
            -Authentication CredSSP `
            -UseSSL `
            -ArgumentList $SourceRecolectExe, $DestRecolectExe, $SourceMidTierExe, $DestMidTierExe, $BackupDir `
            -ErrorAction Stop `
            -ScriptBlock {

                param(
                    [string]$SourceRecolectExe,
                    [string]$DestRecolectExe,
                    [string]$SourceMidTierExe,
                    [string]$DestMidTierExe,
                    [string]$BackupDir
                )

                function Write-Log($msg) {
                    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Write-Host "[$env:COMPUTERNAME][$ts] $msg"
                }

                function ReplaceExeWithBackupAndHash {
                    param(
                        [string]$SourceExe,
                        [string]$DestExe,
                        [string]$BackupDir
                    )

                    Write-Log "Source: $SourceExe"
                    Write-Log "Dest:   $DestExe"

                    if (-not (Test-Path -LiteralPath $SourceExe)) { throw "Source not accessible: $SourceExe" }
                    if (-not (Test-Path -LiteralPath $DestExe))   { throw "Destination not found: $DestExe" }

                    # Stop process if running (best-effort)
                    $procName = [IO.Path]::GetFileNameWithoutExtension($DestExe)
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

                    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
                    $destName   = [IO.Path]::GetFileName($DestExe)
                    $backupPath = Join-Path $BackupDir "$destName.$timestamp.bak"

                    Write-Log "Backing up -> $backupPath"
                    Copy-Item -LiteralPath $DestExe -Destination $backupPath -Force -ErrorAction Stop

                    $srcHash = (Get-FileHash -LiteralPath $SourceExe -Algorithm SHA256).Hash
                    Write-Log "SHA256 source: $srcHash"

                    Write-Log "Copying new EXE..."
                    Copy-Item -LiteralPath $SourceExe -Destination $DestExe -Force -ErrorAction Stop

                    $dstHash = (Get-FileHash -LiteralPath $DestExe -Algorithm SHA256).Hash
                    Write-Log "SHA256 dest:   $dstHash"

                    if ($dstHash -ne $srcHash) {
                        throw "Hash verification failed for $DestExe"
                    }

                    Write-Log "Updated successfully: $DestExe"
                }

                # Replace recolect.exe
                #ReplaceExeWithBackupAndHash -SourceExe $SourceRecolectExe -DestExe $DestRecolectExe -BackupDir $BackupDir

                # Replace MidTier updatereportdefs.exe
                ReplaceExeWithBackupAndHash -SourceExe $SourceMidTierExe -DestExe $DestMidTierExe -BackupDir $BackupDir
            }

        Write-Host "Done on $server"
    }
    catch {
        Write-Host "Failed on $server : $($_.Exception.Message)"
        continue
    }
}