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

$batServer = $Region + $EnvPrefix + 'TBAT-' + $PodId + '01' + $domain
Write-Host "`nBatch Server: $batServer"

$TargetExePath = "D:\apps\Frontier\Rpswin\recolect.exe"
$BackupDir     = "D:\apps\Backup_exe"
$NewExeSource  = Join-Path $packageShare "recolect.exe"

if (-not (Test-Path -LiteralPath $NewExeSource)) {
    throw "Source exe not found on share: $NewExeSource"
}

Write-Host "Source EXE: $NewExeSource"
Write-Host "Dest   EXE: $TargetExePath"
Write-Host "Backup Dir: $BackupDir"

try {
    Invoke-Command -ComputerName $batServer `
        -Credential $Credentials `
        -Authentication CredSSP `
        -UseSSL `
        -ArgumentList $NewExeSource, $TargetExePath, $BackupDir `
        -ErrorAction Stop `
        -ScriptBlock {

            param(
                [string]$SourceExe,
                [string]$DestExe,
                [string]$BackupDir
            )

            function Write-Log($msg) {
                $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Write-Host "[$env:COMPUTERNAME][$ts] $msg"
            }

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

            Write-Log "Backing up current EXE to: $backupPath"
            Copy-Item -LiteralPath $DestExe -Destination $backupPath -Force -ErrorAction Stop

            $srcHash = (Get-FileHash -LiteralPath $SourceExe -Algorithm SHA256).Hash
            Write-Log "SHA256 source: $srcHash"

            Write-Log "Copying new EXE..."
            Copy-Item -LiteralPath $SourceExe -Destination $DestExe -Force -ErrorAction Stop

            $dstHash = (Get-FileHash -LiteralPath $DestExe -Algorithm SHA256).Hash
            Write-Log "SHA256 dest:   $dstHash"

            if ($dstHash -ne $srcHash) {
                throw "Hash verification failed: destination does not match source."
            }

            Write-Log "recolect.exe replacement successful."
        }

    Write-Host "Done on $batServer"
}
catch {
    Write-Host "Failed on $batServer : $($_.Exception.Message)"
}