<#
.SYNOPSIS
    Makes a .bak of a remote SQL Server database using only a connection string with read access.

.DESCRIPTION
    Hosted servers (site4now etc.) usually won't let you BACKUP to a file you can download.
    This script works around that:
      1. Exports the remote database to a .bacpac with SqlPackage (needs only read access).
      2. Fixes database users whose login is missing, and creates matching placeholder
         logins locally (random passwords) so the import doesn't fail.
      3. Imports the .bacpac into the local SQL Server.
      4. Compares row counts between the remote and the local copy.
      5. Backs the local copy up to a .bak (via Backup-FromConnectionString.ps1) and verifies it.
      6. Drops the local copy and the .bacpac (unless -KeepLocalCopy / -KeepBacpac).

    The .bak is in the local server's version (SQL Server 2022 here): it restores on 2022 or newer.

.EXAMPLE
    .\Backup-RemoteDatabase.ps1 -BacpacFile "C:\dumps\MyDb.bacpac" -Zip        # convert a .bacpac to .bak

.EXAMPLE
    .\Backup-RemoteDatabase.ps1 -ConnectionString "Data Source=sql6033.site4now.net;Initial Catalog=MyDb;User Id=...;Password=...;Encrypt=True;TrustServerCertificate=True" -Zip
#>
param(
    [string]$ConnectionString,
    # Use an existing .bacpac instead of exporting from -ConnectionString (the file is not modified).
    [string]$BacpacFile,
    # Name of the local database to import into (default: the source database name).
    [string]$DatabaseName,
    # Only import (use with -KeepLocalCopy to restore a .bacpac into a local database).
    [switch]$SkipBackup,
    # Defaults to the folder this script is in.
    [string]$OutputDir,
    [string]$LocalServer = "localhost\SQLEXPRESS",
    [string]$SqlPackagePath = "$env:USERPROFILE\sqlpackage\SqlPackage.exe",
    [switch]$Zip,
    # Keep the imported database on the local server after the backup.
    [switch]$KeepLocalCopy,
    # Keep the intermediate .bacpac file.
    [switch]$KeepBacpac,
    # Overwrite a local database that already has the same name.
    [switch]$ReplaceLocal
)
$ErrorActionPreference = "Stop"
$started = Get-Date
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutputDir) { $OutputDir = $scriptDir }

if (-not $ConnectionString -and -not $BacpacFile) { throw "Pass -ConnectionString or -BacpacFile." }
if ($ConnectionString) {
    $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $ConnectionString
    $db = $csb.InitialCatalog
    if (-not $db) { throw "The connection string has no 'Initial Catalog' / 'Database'." }
} else {
    if (-not (Test-Path -LiteralPath $BacpacFile)) { throw "File not found: $BacpacFile" }
    $db = [IO.Path]::GetFileNameWithoutExtension($BacpacFile) -replace '_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$', ''
}
if ($DatabaseName) { $db = $DatabaseName }
$localCs = "Data Source=$LocalServer;Initial Catalog=$db;Integrated Security=True;TrustServerCertificate=True"
$masterCs = "Data Source=$LocalServer;Initial Catalog=master;Integrated Security=True;TrustServerCertificate=True"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
$work = Join-Path $env:TEMP ("sqlbackup_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$bacpac = Join-Path $work "$($db -replace '[\\/:*?"<>|]', '_').bacpac"

function Step($msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }
function Exec($cs, $sql) {
    $c = New-Object System.Data.SqlClient.SqlConnection $cs; $c.Open()
    try { $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 0; [void]$cmd.ExecuteNonQuery() } finally { $c.Close() }
}
function Query($cs, $sql) {
    $c = New-Object System.Data.SqlClient.SqlConnection $cs; $c.Open()
    try {
        $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 300
        $dt = New-Object System.Data.DataTable; [void](New-Object System.Data.SqlClient.SqlDataAdapter $cmd).Fill($dt); return ,$dt
    } finally { $c.Close() }
}
function Quote($name) { "[" + $name.Replace("]", "]]") + "]" }
function SqlPackage([string[]]$arguments) {
    & $SqlPackagePath @arguments | Where-Object { $_ -notmatch '^(Processing|Enabling|Disabling|Creating|Analyzing|Extracting|Validating|Resolving) ' } | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "SqlPackage failed (exit code $LASTEXITCODE)." }
}

# --- 0. checks ---
Step "Checking prerequisites"
if (-not (Test-Path $SqlPackagePath)) {
    Write-Host "  SqlPackage not found - downloading it from Microsoft..."
    $zipFile = Join-Path $work "sqlpackage.zip"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest "https://aka.ms/sqlpackage-windows" -OutFile $zipFile -UseBasicParsing
    $dir = Split-Path $SqlPackagePath
    Expand-Archive $zipFile -DestinationPath $dir -Force
    if ((Get-AuthenticodeSignature $SqlPackagePath).Status -ne 'Valid') { throw "Downloaded SqlPackage has no valid signature." }
}
$exists = (Query $masterCs "SELECT DB_ID(N'$($db.Replace("'", "''"))') AS id").Rows[0].id
if ($exists -isnot [DBNull]) {
    if (-not $ReplaceLocal) { throw "A database named '$db' already exists on $LocalServer. Re-run with -ReplaceLocal to overwrite it, or drop it first." }
    Write-Host "  Dropping existing local database '$db' (-ReplaceLocal)"
    Exec $masterCs "ALTER DATABASE $(Quote $db) SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE $(Quote $db);"
}
if ($ConnectionString) { Write-Host "  Source : $($csb.DataSource) / $($csb.InitialCatalog)" } else { Write-Host "  Source : $BacpacFile" }
Write-Host "  Local  : $LocalServer"

try {
    # --- 1. export ---
    if ($BacpacFile) {
        Copy-Item -LiteralPath $BacpacFile -Destination $bacpac   # work on a copy, the original is never changed
    } else {
        Step "Exporting remote database (read-only)"
        SqlPackage @("/Action:Export", "/SourceConnectionString:$ConnectionString", "/TargetFile:$bacpac", "/p:VerifyExtraction=False")
    }

    # --- 2. fix users + create placeholder logins ---
    Step "Preparing database users"
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($bacpac, 'Update')
    try {
        function ReadEntry($name) { $e = $archive.GetEntry($name); $ms = New-Object IO.MemoryStream; $s = $e.Open(); $s.CopyTo($ms); $s.Close(); ,$ms.ToArray() }
        function WriteEntry($name, [byte[]]$bytes) { $archive.GetEntry($name).Delete(); $s = $archive.CreateEntry($name).Open(); $s.Write($bytes, 0, $bytes.Length); $s.Close() }
        function DecodeUtf8([byte[]]$b) { $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF; @{ Bom = $bom; Text = [Text.Encoding]::UTF8.GetString($b, $(if ($bom) { 3 } else { 0 }), $b.Length - $(if ($bom) { 3 } else { 0 })) } }
        function EncodeUtf8($text, $bom) { $enc = New-Object Text.UTF8Encoding($bom); [byte[]]($enc.GetPreamble() + $enc.GetBytes($text)) }

        $m = DecodeUtf8 (ReadEntry "model.xml")
        $logins = New-Object System.Collections.Generic.HashSet[string]
        $fixed = @()
        $userRx = New-Object Text.RegularExpressions.Regex('<Element Type="SqlUser" Name="\[(?<name>[^\]]+)\]">(?<body>.*?)</Element>', 'Singleline')
        $model = $userRx.Replace($m.Text, {
            param($match)
            $name = $match.Groups['name'].Value; $body = $match.Groups['body'].Value
            if ($body -notmatch 'Name="AuthenticationType" Value="1"') { return $match.Value }   # only SQL users mapped to logins
            if ($body -match 'Relationship Name="Login">\s*<Entry>\s*<(?:References|Annotation)[^>]*Name="\[(?<login>[^\]]+)\]"') {
                [void]$logins.Add($Matches['login']); return $match.Value
            }
            if ($body -match 'UndeployableElementAnnotation') {
                [void]$logins.Add($name); $script:fixed += $name
                $login = '<Relationship Name="Login"><Entry><Annotation Type="PersistedResolvableAnnotation" Name="[' + $name + ']"><Property Name="TargetTypeStorage" Value="SqlLogin" /></Annotation></Entry></Relationship>'
                return $match.Value.Replace('<Annotation Type="UndeployableElementAnnotation" />', $login)
            }
            return $match.Value
        })
        if ($fixed.Count) {
            $newModel = EncodeUtf8 $model $m.Bom
            WriteEntry "model.xml" $newModel
            $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($newModel)).Replace("-", "")
            $o = DecodeUtf8 (ReadEntry "Origin.xml")
            $origin = [regex]::Replace($o.Text, '(<Checksum Uri="/model.xml">)[0-9A-Fa-f]+(</Checksum>)', "`${1}$hash`${2}")
            WriteEntry "Origin.xml" (EncodeUtf8 $origin $o.Bom)
            Write-Host "  Re-linked users with a missing login: $($fixed -join ', ')"
        }
    } finally { $archive.Dispose() }

    foreach ($l in $logins) {
        if ($l -match '\\') { continue }   # Windows logins can't be created as SQL logins
        $lq = $l.Replace("'", "''")
        Exec $masterCs @"
IF SUSER_ID(N'$lq') IS NULL
BEGIN
    DECLARE @p nvarchar(100) = CONVERT(nvarchar(36), NEWID()) + N'aA1!';
    EXEC(N'CREATE LOGIN $((Quote $l).Replace("'", "''")) WITH PASSWORD = ''' + @p + N''', CHECK_POLICY = OFF');
    PRINT 'created';
END
"@
        Write-Host "  Local login ready: $l"
    }

    # --- 3. import ---
    Step "Importing into $LocalServer"
    SqlPackage @("/Action:Import", "/SourceFile:$bacpac", "/TargetConnectionString:$localCs")

    # --- 4. compare row counts ---
    if ($ConnectionString) {
    Step "Comparing row counts (remote vs local)"
    $countSql = "SELECT s.name + '.' + t.name AS T, SUM(p.rows) AS N FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) GROUP BY s.name, t.name"
    $remote = @{}; foreach ($r in (Query $ConnectionString $countSql)) { $remote[$r.T] = [long]$r.N }
    $local = @{};  foreach ($r in (Query $localCs $countSql))         { $local[$r.T]  = [long]$r.N }
    $diff = @($remote.Keys | Where-Object { $local[$_] -ne $remote[$_] })
    if ($diff.Count) {
        Write-Warning "Row counts differ in $($diff.Count) table(s) - the remote data may have changed during the export:"
        $diff | ForEach-Object { Write-Warning ("  {0}: remote {1}, local {2}" -f $_, $remote[$_], $local[$_]) }
    } else {
        Write-Host "  All $($remote.Count) tables match ($(($remote.Values | Measure-Object -Sum).Sum) rows)."
    }
    }

    # --- 5. backup + verify ---
    if (-not $SkipBackup) {
    Step "Creating .bak"
    $before = @(Get-ChildItem $OutputDir -Filter "*.bak" | ForEach-Object FullName)
    & (Join-Path $scriptDir "Backup-FromConnectionString.ps1") -ConnectionString $localCs -OutputDir $OutputDir -Zip:$Zip
    $bak = Get-ChildItem $OutputDir -Filter "*.bak" | Where-Object { $before -notcontains $_.FullName } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $bak) { throw "Backup file was not created." }
    Exec $masterCs "RESTORE VERIFYONLY FROM DISK = N'$($bak.FullName.Replace("'", "''"))' WITH CHECKSUM;"
    Write-Host "  Verified: backup is readable and checksums are valid."
    }
}
finally {
    # --- 6. clean up ---
    if (-not $KeepLocalCopy) {
        try { Exec $masterCs "IF DB_ID(N'$($db.Replace("'", "''"))') IS NOT NULL BEGIN ALTER DATABASE $(Quote $db) SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE $(Quote $db); END" } catch { Write-Warning "Could not drop local copy: $($_.Exception.Message)" }
    }
    if ($KeepBacpac -and (Test-Path $bacpac)) { Move-Item $bacpac $OutputDir -Force; Write-Host "  Kept .bacpac in $OutputDir" }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Step "Done in $([int]((Get-Date) - $started).TotalSeconds)s"
if ($bak) { Write-Host "  $($bak.FullName)  ($([Math]::Round($bak.Length / 1MB, 1)) MB)" -ForegroundColor Green }
if ($KeepLocalCopy) { Write-Host "  Local copy kept: $LocalServer / $db" }
