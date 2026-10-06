# Restore / convert menu. Started by "Restore Database.bat".
#   1. Restore a backup (.bak, .sql, .bacpac, or a .zip of one) into a local database or a database from connections.txt
#   2. Convert a dump (.sql or .bacpac) into a .bak file
param(
    [string]$ConfigPath,
    # Always restore into connections by running a .sql script, even when a direct RESTORE would be possible.
    [switch]$ViaScript
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common.ps1")
$host.UI.RawUI.WindowTitle = "Restore Database"

function Get-Kind([string]$path) { return [IO.Path]::GetExtension($path).TrimStart('.').ToLower() }
function New-TempName { return "__restore_tmp_" + [guid]::NewGuid().ToString("N").Substring(0, 8) }

function Show-DbSummary([string]$cs, [string]$label) {
    $r = (Invoke-Query $cs "SELECT (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) AS T, (SELECT ISNULL(SUM(p.rows), 0) FROM sys.partitions p JOIN sys.tables t ON t.object_id = p.object_id WHERE t.is_ms_shipped = 0 AND p.index_id IN (0, 1)) AS R").Rows[0]
    Write-Host ("  {0}: {1} tables, {2} rows." -f $label, $r.T, $r.R) -ForegroundColor Green
}

# Turns a .bak or .bacpac into a temporary .sql dump (via a temporary local database). Returns the .sql path.
function ConvertTo-SqlDump($cfg, [string]$path, [string]$workDir) {
    $master = Get-MasterCs $cfg.localServer
    $tmp = New-TempName
    try {
        if ((Get-Kind $path) -eq "bak") { Restore-BakLocal $master $path $tmp $false }
        else { & (Join-Path $ToolDir "Backup-RemoteDatabase.ps1") -BacpacFile $path -DatabaseName $tmp -SkipBackup -KeepLocalCopy -LocalServer $cfg.localServer | Out-Host }
        Write-Host "  Turning it into a .sql script..."
        $out = Join-Path $workDir ((Get-SafeName (Get-DbNameFromFile $path)) + ".sql")
        & (Join-Path $ToolDir "Export-SqlDump.ps1") -ConnectionString (Get-LocalDbCs $cfg.localServer $tmp) -OutputFile $out | Out-Null
        return $out
    }
    finally { Remove-LocalDatabase $master $tmp }
}

function Invoke-SqlImport([string]$cs, [string]$sqlFile) {
    $ok = @(& (Join-Path $ToolDir "Import-SqlDump.ps1") -ConnectionString $cs -File $sqlFile)[-1]
    if (-not $ok) { Write-Host "  Finished with warnings - see the messages above." -ForegroundColor Yellow }
}

# ---------------------------------------------------------------- restore

function Invoke-Restore($cfg) {
    $file = Select-BackupFile $cfg @(".bak", ".sql", ".bacpac", ".zip") "Choose the backup to restore:"
    if (-not $file) { return }
    $x = Expand-BackupFile $file
    $work = Join-Path ([IO.Path]::GetTempPath()) ("sqlwork_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $path = $x.Path; $kind = Get-Kind $path
        Write-Host ""
        Write-Host "Restore $([IO.Path]::GetFileName($file)) into:" -ForegroundColor Yellow
        Write-Host "  1. A database on this PC ($($cfg.localServer))"
        Write-Host "  2. A database from connections.txt  (everything in it gets REPLACED)"
        $t = Ask ">"
        $master = Get-MasterCs $cfg.localServer

        if ($t -eq "1") {
            $default = Get-DbNameFromFile $file
            $name = Ask "Database name (Enter = $default)"
            if (-not $name) { $name = $default }
            $replace = $false
            if (Test-LocalDbExists $master $name) {
                Write-Host "A database named '$name' already exists on this PC." -ForegroundColor Yellow
                if ((Ask "Type the name '$name' to REPLACE it (anything else cancels)") -cne $name) { Write-Host "Cancelled."; return }
                $replace = $true
            }
            if ($kind -eq "bak") { Restore-BakLocal $master $path $name $replace }
            elseif ($kind -eq "sql") {
                if ($replace) { Remove-LocalDatabase $master $name }
                Invoke-NonQuery $master ("CREATE DATABASE " + (QN $name)) | Out-Null
                Invoke-SqlImport (Get-LocalDbCs $cfg.localServer $name) $path
            }
            else {
                if ($replace) { Remove-LocalDatabase $master $name }
                & (Join-Path $ToolDir "Backup-RemoteDatabase.ps1") -BacpacFile $path -DatabaseName $name -SkipBackup -KeepLocalCopy -LocalServer $cfg.localServer | Out-Host
            }
            Show-DbSummary (Get-LocalDbCs $cfg.localServer $name) "Restored [$name] on $($cfg.localServer)"
            Write-Host "  Connection string: Data Source=$($cfg.localServer);Initial Catalog=$name;Integrated Security=True;TrustServerCertificate=True;"
            return
        }
        if ($t -ne "2") { Write-Host "Cancelled."; return }

        $conn = Select-Connections "Restore into which SQL Server database?" -Single -Engine mssql
        if (-not $conn) { return }
        $b = Get-Builder $conn.ConnectionString
        $err = Test-DbConnection $conn.ConnectionString
        if ($err) { throw "Can't connect to $($conn.Name): $err" }
        $objects = Get-UserObjectCount $conn.ConnectionString
        Write-Host ""
        Write-Host "Target: $($conn.Name)  ($($b.DataSource) / $($b.InitialCatalog))" -ForegroundColor Yellow
        if ($objects -gt 0) { Write-Host "  It has $objects tables/views/procedures/functions - they will ALL be deleted and replaced by the backup." -ForegroundColor Red }
        else { Write-Host "  It's empty." }

        $direct = ($kind -eq "bak") -and (Test-IsLocalServer $b.DataSource $cfg.localServer) -and -not $ViaScript
        if ($objects -gt 0) {
            Write-Host "Back up $($conn.Name) first?" -ForegroundColor Yellow
            Write-Host "  1. Yes, as .sql  (recommended)"
            Write-Host "  2. Yes, as .bak"
            Write-Host "  3. No"
            $f = Ask ">"
            if ($f -eq "1" -or $f -eq "2") {
                try { $bk = Invoke-Backup $cfg $conn $(if ($f -eq "1") { "sql" } else { "bak" }); Write-Host "  Backup: $($bk.FullName)" -ForegroundColor Green }
                catch {
                    Write-Host "  Backup failed: $($_.Exception.Message)" -ForegroundColor Red
                    if (-not (Confirm-Yes "Continue WITHOUT a backup?")) { Write-Host "Cancelled - nothing changed."; return }
                }
            }
        }
        if ((Ask "Type the database name '$($b.InitialCatalog)' to restore into it (anything else cancels)") -cne $b.InitialCatalog) { Write-Host "Cancelled - nothing changed."; return }

        if ($direct) {
            Restore-BakLocal $master $path $b.InitialCatalog $true
        }
        else {
            $sqlFile = if ($kind -eq "sql") { $path } else { ConvertTo-SqlDump $cfg $path $work }
            if ($objects -gt 0) { Write-Host "  Clearing $($conn.Name)..."; Clear-Database $conn.ConnectionString }
            Invoke-SqlImport $conn.ConnectionString $sqlFile
        }
        Show-DbSummary $conn.ConnectionString "Restored into $($conn.Name)"
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        if ($x -and $x.Temp) { Remove-Item -LiteralPath $x.Temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- convert

function Invoke-Convert($cfg) {
    $file = Select-BackupFile $cfg @(".sql", ".bacpac", ".sql.zip") "Choose the dump to convert to .bak:"
    if (-not $file) { return }
    $x = Expand-BackupFile $file
    try {
        $path = $x.Path; $kind = Get-Kind $path
        if ($kind -notin "sql", "bacpac") { throw "Pick a .sql or .bacpac file (or a zip of one)." }
        $master = Get-MasterCs $cfg.localServer
        $outDir = Split-Path -Parent $file
        $name = Get-DbNameFromFile $file
        if (Test-LocalDbExists $master $name) { $name = $name + "_convert" }
        if (Test-LocalDbExists $master $name) { throw "Local databases '$(Get-DbNameFromFile $file)' and '$name' both exist - remove one first." }
        Write-Host ""
        Write-Host "Converting $([IO.Path]::GetFileName($file)) to .bak (saved in $outDir)..." -ForegroundColor Yellow
        if ($kind -eq "bacpac") {
            & (Join-Path $ToolDir "Backup-RemoteDatabase.ps1") -BacpacFile $path -DatabaseName $name -OutputDir $outDir -LocalServer $cfg.localServer -Zip | Out-Host
            return
        }
        try {
            Invoke-NonQuery $master ("CREATE DATABASE " + (QN $name)) | Out-Null
            $cs = Get-LocalDbCs $cfg.localServer $name
            Invoke-SqlImport $cs $path
            & (Join-Path $ToolDir "Backup-FromConnectionString.ps1") -ConnectionString $cs -OutputDir $outDir -Zip | Out-Host
        }
        finally { Remove-LocalDatabase $master $name }
    }
    finally { if ($x -and $x.Temp) { Remove-Item -LiteralPath $x.Temp -Recurse -Force -ErrorAction SilentlyContinue } }
}

# ---------------------------------------------------------------- PostgreSQL

function Invoke-PgRestore($cfg) {
    $file = Select-BackupFile $cfg @(".dump", ".sql", ".zip") "Choose the PostgreSQL backup to restore:"
    if (-not $file) { return }
    $x = Expand-BackupFile $file
    try {
        $path = $x.Path; $kind = Get-Kind $path
        if ($kind -notin "dump", "sql") { throw "Pick a PostgreSQL .dump or .sql file (or a zip of one)." }
        if ($kind -eq "sql" -and -not (Test-PgSqlFile $path)) {
            Write-Host "This .sql file doesn't look like a PostgreSQL dump (it may be a SQL Server one)." -ForegroundColor Yellow
            if (-not (Confirm-Yes "Restore it anyway?")) { return }
        }
        Write-Host ""
        Write-Host "Restore $([IO.Path]::GetFileName($file)) into:" -ForegroundColor Yellow
        Write-Host "  1. A database on this PC  (private PostgreSQL server, port $PgLocalPort)"
        Write-Host "  2. A PostgreSQL database from connections.txt  (everything in it gets REPLACED)"
        $t = Ask ">"
        if ($t -eq "1") {
            [void](Start-PgLocal)
            $default = (Get-DbNameFromFile $file).ToLower()
            $name = Ask "Database name (Enter = $default)"
            if (-not $name) { $name = $default }
            if (Test-PgLocalDbExists $name) {
                Write-Host "A database named '$name' already exists on this PC." -ForegroundColor Yellow
                if ((Ask "Type the name '$name' to REPLACE it (anything else cancels)") -cne $name) { Write-Host "Cancelled."; return }
                Remove-PgLocalDb $name
            }
            New-PgLocalDb $name
            Restore-PgFile (Get-PgLocalConn $name) $path
            Write-Host "  Restored [$name] on this PC: $(Get-PgSummary (Get-PgLocalConn $name))." -ForegroundColor Green
            Write-Host "  Connection string: Host=localhost;Port=$PgLocalPort;Database=$name;Username=postgres"
            Write-Host "  (The private server keeps running until the PC restarts; this menu starts it again when needed.)" -ForegroundColor DarkGray
            return
        }
        if ($t -ne "2") { Write-Host "Cancelled."; return }

        $conn = Select-Connections "Restore into which PostgreSQL database?" -Single -Engine pg
        if (-not $conn) { return }
        $pg = Get-PgConn $conn.ConnectionString
        $err = Test-PgConnection $pg
        if ($err) { throw "Can't connect to $($conn.Name): $err" }
        $objects = Get-PgObjectCount $pg
        Write-Host ""
        Write-Host "Target: $($conn.Name)  ($($pg.Host):$($pg.Port) / $($pg.Database))" -ForegroundColor Yellow
        if ($objects -gt 0) {
            Write-Host "  It has $objects tables/views/sequences/functions - they will ALL be deleted and replaced by the backup." -ForegroundColor Red
            Write-Host "Back up $($conn.Name) first?" -ForegroundColor Yellow
            Write-Host "  1. Yes, as .dump  (recommended)"
            Write-Host "  2. Yes, as .sql"
            Write-Host "  3. No"
            $f = Ask ">"
            if ($f -eq "1" -or $f -eq "2") {
                try { $bk = Invoke-Backup $cfg $conn $(if ($f -eq "1") { "dump" } else { "sql" }); Write-Host "  Backup: $($bk.FullName)" -ForegroundColor Green }
                catch {
                    Write-Host "  Backup failed: $($_.Exception.Message)" -ForegroundColor Red
                    if (-not (Confirm-Yes "Continue WITHOUT a backup?")) { Write-Host "Cancelled - nothing changed."; return }
                }
            }
        }
        else { Write-Host "  It's empty." }
        if ((Ask "Type the database name '$($pg.Database)' to restore into it (anything else cancels)") -cne $pg.Database) { Write-Host "Cancelled - nothing changed."; return }
        if ($objects -gt 0) { Write-Host "  Clearing $($conn.Name)..."; Clear-PgDatabase $pg }
        Restore-PgFile $pg $path
        Write-Host "  Restored into $($conn.Name): $(Get-PgSummary $pg)." -ForegroundColor Green
    }
    finally { if ($x -and $x.Temp) { Remove-Item -LiteralPath $x.Temp -Recurse -Force -ErrorAction SilentlyContinue } }
}

function Invoke-PgConvert($cfg) {
    $file = Select-BackupFile $cfg @(".dump", ".sql", ".zip") "Choose the PostgreSQL file to convert (.dump -> .sql or .sql -> .dump):"
    if (-not $file) { return }
    $x = Expand-BackupFile $file
    try {
        $path = $x.Path; $kind = Get-Kind $path
        if ($kind -notin "dump", "sql") { throw "Pick a PostgreSQL .dump or .sql file (or a zip of one)." }
        $toExt = if ($kind -eq "dump") { "sql" } else { "dump" }
        $base = [IO.Path]::GetFileName($file) -replace '\.zip$', '' -replace '\.(dump|sql)$', ''
        $out = Join-Path (Split-Path -Parent $file) "$base.$toExt"
        if (Test-Path -LiteralPath $out) { $out = Join-Path (Split-Path -Parent $file) "${base}_converted.$toExt" }
        Write-Host ""
        Write-Host "Converting $([IO.Path]::GetFileName($file)) to .$toExt ..." -ForegroundColor Yellow
        if ($kind -eq "dump") { Convert-PgDumpToSql $path $out } else { Convert-PgSqlToDump $path $out }
        Write-Host ("  Saved: {0} ({1} MB)" -f $out, [Math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 1)) -ForegroundColor Green
    }
    finally { if ($x -and $x.Temp) { Remove-Item -LiteralPath $x.Temp -Recurse -Force -ErrorAction SilentlyContinue } }
}

# ---------------------------------------------------------------- menu

try {
    do {
        Clear-Host
        Write-Banner "RESTORE / CONVERT DATABASE BACKUPS  (SQL Server / PostgreSQL)"
        $cfg = Read-Config
        $engine = Select-Engine
        if (-not $engine) { break }
        Write-Host ""
        Write-Host "What do you want to do?" -ForegroundColor Yellow
        if ($engine -eq "pg") {
            Write-Host "  1. Restore a backup (.dump / .sql / .zip) into a PostgreSQL database"
            Write-Host "  2. Convert .dump <-> .sql"
        } else {
            Write-Host "  1. Restore a backup (.bak / .sql / .bacpac / .zip) into a database"
            Write-Host "  2. Convert a dump (.sql / .bacpac) to a .bak file"
        }
        Write-Host "  Q. Quit"
        $a = Ask ">"
        if ($a -match '^[Qq]$') { break }
        try {
            if ($engine -eq "pg") {
                if ($a -eq "1") { Invoke-PgRestore $cfg }
                elseif ($a -eq "2") { Invoke-PgConvert $cfg }
            }
            elseif ($a -eq "1") { Invoke-Restore $cfg }
            elseif ($a -eq "2") { Invoke-Convert $cfg }
        }
        catch {
            if ($_.Exception.Message -eq "No more input - stopping.") { throw }
            Write-Host ""
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host ""
    } while (Confirm-Yes "Do something else?")
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to close" | Out-Null
}
