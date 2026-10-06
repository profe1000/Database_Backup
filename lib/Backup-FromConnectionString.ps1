<#
.SYNOPSIS
    Creates a .bak backup of the database named in a SQL Server connection string
    and downloads it to this machine.

.DESCRIPTION
    1. Runs BACKUP DATABASE ... WITH COPY_ONLY on the server (does not disturb the
       server's normal backup chain).
    2. Brings the .bak file back to this machine:
         - copies it directly if the server is local or the backup folder is reachable,
         - otherwise streams it over the SQL connection with OPENROWSET(BULK ...).
    3. Deletes the temporary copy on the server (unless -KeepOnServer).
    4. Optionally zips it (-Zip).

    Requirements on the SQL login:
      - BACKUP DATABASE permission (db_owner or db_backupoperator).
      - To download over the SQL connection: ADMINISTER BULK OPERATIONS (sysadmin has it).
    Shared hosts (e.g. site4now) often block BACKUP TO DISK; use the host's control
    panel backup instead if this script reports "permission denied".

.EXAMPLE
    .\Backup-FromConnectionString.ps1 -ConnectionString "Data Source=myserver;Initial Catalog=MyDb;User Id=sa;Password=...;TrustServerCertificate=True" -Zip

.EXAMPLE
    .\Backup-FromConnectionString.ps1 -ConnectionString $cs -OutputDir "D:\Backups" -ServerBackupDir "D:\SQLBackups"
#>
param(
    [Parameter(Mandatory = $true)][string]$ConnectionString,
    # Local folder where the .bak ends up.
    [string]$OutputDir = (Get-Location).Path,
    # Folder ON THE SQL SERVER where BACKUP writes. Defaults to the instance's default backup folder.
    [string]$ServerBackupDir,
    # Also create a .zip next to the .bak.
    [switch]$Zip,
    # Leave the backup file on the server after downloading it.
    [switch]$KeepOnServer
)
$ErrorActionPreference = "Stop"

$csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $ConnectionString
$db = $csb.InitialCatalog
if (-not $db) { throw "The connection string has no 'Initial Catalog' / 'Database'." }

$conn = New-Object System.Data.SqlClient.SqlConnection $csb.ConnectionString
$conn.FireInfoMessageEventOnUserErrors = $false
$conn.add_InfoMessage({ param($s, $e) Write-Host "  $($e.Message)" })
$conn.Open()

function Scalar($sql) {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 60
    $v = $cmd.ExecuteScalar(); if ($v -is [DBNull]) { $null } else { $v }
}

$version = Scalar "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50))"
$edition = Scalar "SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(200))"
$machine = Scalar "SELECT CAST(SERVERPROPERTY('MachineName') AS nvarchar(200))"
Write-Host "Server : $($csb.DataSource)  (SQL Server $version, $edition)"
Write-Host "Database: $db"

# --- where to write on the server ---
$isLocalServer = $machine -ieq $env:COMPUTERNAME
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
$staging = $null
if (-not $ServerBackupDir -and $isLocalServer) {
    # The default backup folder is readable only by the SQL service account, so back up into a
    # staging folder next to the output and give the service account write access to it.
    $svc = Scalar "SELECT TOP 1 service_account FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%'"
    $staging = Join-Path $OutputDir (".sqlbak_staging_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $staging | Out-Null
    & icacls.exe $staging /grant "${svc}:(OI)(CI)M" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not grant '$svc' access to '$staging'." }
    $ServerBackupDir = $staging
}
elseif (-not $ServerBackupDir) {
    $ServerBackupDir = Scalar "SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(4000))"  # 2016+
    if (-not $ServerBackupDir) {
        try {
            $ServerBackupDir = Scalar @"
DECLARE @d nvarchar(4000);
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @d OUTPUT;
SELECT @d;
"@
        } catch { }
    }
    if (-not $ServerBackupDir) { throw "Could not find the server's default backup folder. Pass -ServerBackupDir with a folder on the SQL Server machine." }
}
$sep = if ($ServerBackupDir.StartsWith('/')) { '/' } else { '\' }
$safeDb = ($db -replace '[\\/:*?"<>|]', '_')
$fileName = "{0}_{1}.bak" -f $safeDb, (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")
$serverPath = $ServerBackupDir.TrimEnd('\', '/') + $sep + $fileName
Write-Host "Server file: $serverPath"

# --- backup ---
function Run-Backup([bool]$compress) {
    $opts = "COPY_ONLY, INIT, FORMAT, CHECKSUM, STATS = 10" + $(if ($compress) { ", COMPRESSION" } else { "" })
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "BACKUP DATABASE [$($db.Replace(']', ']]'))] TO DISK = @path WITH $opts;"
    [void]$cmd.Parameters.AddWithValue("@path", $serverPath)
    $cmd.CommandTimeout = 0
    [void]$cmd.ExecuteNonQuery()
}
Write-Host "Backing up..."
try {
    Run-Backup ($edition -notlike "*Express*")
} catch [System.Data.SqlClient.SqlException] {
    if ($_.Exception.Number -eq 1844) { Write-Host "Compression not supported, retrying without it..."; Run-Backup $false }
    elseif ($_.Exception.Number -eq 262 -or $_.Exception.Number -eq 3201 -or $_.Exception.Number -eq 3013) {
        throw "Backup failed: $($_.Exception.Message)`nThe login may lack BACKUP permission, or the server cannot write to '$ServerBackupDir'. Try -ServerBackupDir, or use your host's control-panel backup."
    }
    else { throw }
}

# --- bring the file here ---
$localPath = Join-Path $OutputDir $fileName

$directPath = if ($isLocalServer) { $serverPath }
              elseif ($serverPath -match '^[A-Za-z]:\\') { "\\$machine\" + $serverPath.Substring(0, 1) + '$' + $serverPath.Substring(2) }  # admin share
              else { $serverPath }  # already a UNC path

$copied = $false
if ($staging) {
    Move-Item -LiteralPath $serverPath -Destination $localPath -Force
    Remove-Item -LiteralPath $staging -Recurse -Force
    $copied = $true
}
else { try {
    if (Test-Path -LiteralPath $directPath) {
        Write-Host "Copying from $directPath ..."
        Copy-Item -LiteralPath $directPath -Destination $localPath -Force
        $copied = $true
    }
} catch { } }

if (-not $copied) {
    Write-Host "Downloading over the SQL connection..."
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT BulkColumn FROM OPENROWSET(BULK N'$($serverPath.Replace("'", "''"))', SINGLE_BLOB) AS f;"
    $cmd.CommandTimeout = 0
    try {
        $reader = $cmd.ExecuteReader([System.Data.CommandBehavior]::SequentialAccess)
        [void]$reader.Read()
        $src = $reader.GetStream(0)
        $dst = [System.IO.File]::Create($localPath)
        try { $src.CopyTo($dst, 4MB) } finally { $dst.Close(); $src.Close(); $reader.Close() }
    } catch {
        Remove-Item -LiteralPath $localPath -ErrorAction SilentlyContinue
        throw "The backup was created on the server at '$serverPath' but could not be downloaded: $($_.Exception.Message)`nThe login needs ADMINISTER BULK OPERATIONS, or copy the file from the server manually."
    }
}

# --- clean up server copy ---
if (-not $KeepOnServer -and -not $isLocalServer) {
    try {
        $cmd = $conn.CreateCommand(); $cmd.CommandText = "EXEC master.sys.xp_delete_file 0, @path;"
        [void]$cmd.Parameters.AddWithValue("@path", $serverPath); [void]$cmd.ExecuteNonQuery()
        Write-Host "Removed temporary file from server."
    } catch { Write-Warning "Could not delete '$serverPath' on the server: $($_.Exception.Message)" }
}
$conn.Close()

$sizeMb = [Math]::Round((Get-Item -LiteralPath $localPath).Length / 1MB, 1)
Write-Host "Backup saved: $localPath ($sizeMb MB)"

if ($Zip) {
    $zipPath = [System.IO.Path]::ChangeExtension($localPath, ".zip")
    Compress-Archive -LiteralPath $localPath -DestinationPath $zipPath -Force
    Write-Host "Zipped    : $zipPath"
}
