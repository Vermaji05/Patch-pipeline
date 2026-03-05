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
        $AppServerCount = 5
        $packageShare = "\\cloud\NETLOGON\cloud_files\Frontier\Frontier_Release\2025_1\Frontier Install Packages\RDP\" # Adjust as needed
    }
    'Test' {
        $domain = '.cloud.trintech.host'
        $AppServerCount = 3
        $packageShare = "\\cloud\NETLOGON\cloud_files\Frontier\Frontier_Release\2025_1\Frontier Install Packages\RDP\" # Adjust as needed
    }
    'Dev' {
        $domain = '.lower.trintech.host'
        $AppServerCount = 2
        $packageShare = "\\Lower\NETLOGON\cloud_files\Frontier\Frontier_Release\2025_1\Frontier Install Packages\RDP\"
    }
    default { throw "Selected environment type doesn't exist!" }
}
$suffix = "ZZ"
$appServers = foreach ($i in 1..$AppServerCount) {

    if ($Region -eq 'USR2') {
        "{0}{1}TAPP-{2}01{3}" -f $Region, $EnvPrefix, ("{0:D2}" -f $i), $domain
    }
    else {
        "{0}{1}TAPP-{2}{3:D2}{4}" -f $Region, $EnvPrefix, $suffix, $i, $domain
    }
}

Write-Host "App Servers: $($appServers -join ', ')`n"

$TargetExePath = 'D:\Apps\Frontier\RpsWin2\recolect.exe'   
$BackupDir     = 'D:\Apps\Backup_exe'        
$NewExeSource  = Join-Path $packageShare 'recolect.exe' 

Write-Host "New EXE source: $NewExeSource"
Write-Host "Target EXE path: $TargetExePath"
Write-Host "Backup dir:      $BackupDir`n"

# validation before remoting
if (-not (Test-Path -LiteralPath $NewExeSource)) {
    throw "New EXE not found on share: $NewExeSource"
}

foreach ($server in $appServers) {
    Write-Host "`n==== Installing Binaries and PreReqs on $server ===="
    try {
        Invoke-Command -ComputerName $server -Credential $Credentials -Authentication CredSSP -UseSSL -ArgumentList $NewExeSource, $TargetExePath, $BackupDir -ErrorAction Stop -ScriptBlock {

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

                if (-not (Test-Path -LiteralPath $SourceExe)) {
                    throw "Source EXE not found (share/path not accessible from this server): $SourceExe"
                }
                if (-not (Test-Path -LiteralPath $DestExe)) {
                    throw "Destination EXE not found: $DestExe"
                }

                # stop process if it locks the exe
                $procName = [IO.Path]::GetFileNameWithoutExtension($DestExe)
                $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
                if ($procs) {
                    Write-Log "Stopping process: $procName"
                    $procs | Stop-Process -Force
                    Start-Sleep -Seconds 2
                } else {
                    Write-Log "Process not running: $procName"
                }

                if (-not (Test-Path -LiteralPath $BackupDir)) {
                    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
                    Write-Log "Created backup dir: $BackupDir"
                }

                $timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
                $destName    = [IO.Path]::GetFileName($DestExe)
                $backupPath  = Join-Path $BackupDir "$destName.$timestamp.bak"

                Write-Log "Backing up current EXE to: $backupPath"
                Copy-Item -LiteralPath $DestExe -Destination $backupPath -Force -ErrorAction Stop

                $srcHash  = (Get-FileHash -LiteralPath $SourceExe -Algorithm SHA256).Hash
                
                Write-Log "SHA256 source: $srcHash"
                Write-Log "SHA256 dest (before): $dstHash0"

                Write-Log "Copying new EXE into place..."
                Copy-Item -LiteralPath $SourceExe -Destination $DestExe -Force -ErrorAction Stop

                $dstHash1 = (Get-FileHash -LiteralPath $DestExe -Algorithm SHA256).Hash
                Write-Log "SHA256 dest (after):  $dstHash1"

                if ($dstHash1 -ne $srcHash) {
                    throw "Hash verification failed: destination does not match source."
                }

                Write-Log "Replacement successful."
            }

        Write-Host "Done on $server"
    }
    catch {
        Write-Host "Failed on $server : $($_.Exception.Message)"
        continue
    }
}
