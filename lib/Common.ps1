# Shared helpers for "Backup Database.bat" and "Compare and Sync.bat".
# Dot-sourced by Backup-Launcher.ps1 and Compare-Sync.ps1 - not meant to be run on its own.

$ToolDir = $PSScriptRoot
# Every tool needs a valid yearly licence (..\licence.key). $Unattended is set by Auto-Backup.ps1 for scheduled runs.
. (Join-Path $ToolDir "Licence.ps1")
Assert-Licence ([IO.Path]::GetFullPath((Join-Path $ToolDir "..\licence.key"))) -NoPause:([bool]$Unattended)
# Connections and settings live in ..\conn (kept out of git - only connections.sample.txt is committed).
$ConnDir = [IO.Path]::GetFullPath((Join-Path $ToolDir "..\conn"))
if (-not (Test-Path -LiteralPath $ConnDir)) { [void](New-Item -ItemType Directory -Path $ConnDir -Force) }
# Moves files left in lib by older versions into conn.
foreach ($old in @("connections.txt", "connections-history")) {
    $from = Join-Path $ToolDir $old
    $to = Join-Path $ConnDir $(if ($old -eq "connections-history") { "history" } else { $old })
    if ((Test-Path -LiteralPath $from) -and -not (Test-Path -LiteralPath $to)) { Move-Item -LiteralPath $from $to }
}
if (-not $ConfigPath) { $ConfigPath = Join-Path $ConnDir "connections.txt" }

# ---------------------------------------------------------------- console

function Write-Banner($title) {
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
}
function Write-Step($msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }

# Read-Host that stops cleanly if input ends (e.g. window closed) instead of looping forever.
function Ask([string]$prompt) {
    $r = Read-Host $prompt
    if ($null -eq $r) { throw "No more input - stopping." }
    return $r.Trim()
}
function Confirm-Yes([string]$prompt) { return (Ask "$prompt (Y/N)") -match '^[Yy]' }

# ---------------------------------------------------------------- settings file

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $sample = Join-Path $ConnDir "connections.sample.txt"
        if (-not (Test-Path -LiteralPath $sample)) { throw "Settings file not found: $ConfigPath" }
        Copy-Item -LiteralPath $sample $ConfigPath
        Write-Host "connections.txt was missing - a new one was made from connections.sample.txt. Add your connections with Edit Connections.bat." -ForegroundColor Yellow
    }
    $full = (Resolve-Path -LiteralPath $ConfigPath).Path
    $baseDir = Split-Path -Parent $full
    $cfg = @{ outputFolder = "..\Backups"; schemaFile = ""; localServer = "localhost\SQLEXPRESS"; autoBackupKeep = "7"; Connections = @(); AutoBackup = @(); Warnings = @() }
    $section = ""; $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($full)) {
        $n++
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        if ($line -match '^\[(.+)\]$') { $section = $Matches[1].Trim().ToLower(); continue }
        $i = $line.IndexOf("=")
        if ($i -lt 1) { $cfg.Warnings += "line ${n} ignored (expected: name = value)"; continue }
        $key = $line.Substring(0, $i).Trim()
        $val = $line.Substring($i + 1).Trim()
        if ($val.Length -ge 2 -and $val.StartsWith('"') -and $val.EndsWith('"')) { $val = $val.Substring(1, $val.Length - 2) }
        if ($section -eq "connections") {
            if (@($cfg.Connections | Where-Object { $_.Name -eq $key }).Count) { $cfg.Warnings += "line ${n}: duplicate name '$key' ignored"; continue }
            $cfg.Connections += [pscustomobject]@{ Name = $key; ConnectionString = $val }
        }
        elseif ($section -eq "autobackup") {
            # connection name = format(s), e.g.  cocacola = sql   /   Hotel_db = dump, sql   /   other = both
            $cfg.AutoBackup += [pscustomobject]@{ Name = $key; Formats = @($val.ToLower() -split '[,;+\s]+' | Where-Object { $_ }) }
        }
        else { $cfg[$key] = $val }
    }
    foreach ($k in @("outputFolder", "schemaFile")) {
        $p = [Environment]::ExpandEnvironmentVariables([string]$cfg[$k])
        if ($p -and -not [IO.Path]::IsPathRooted($p)) { $p = [IO.Path]::GetFullPath((Join-Path $baseDir $p)) }
        $cfg[$k] = $p
    }
    # Default: the Backups folder in the main folder (next to the .bat files), one level above lib.
    if (-not $cfg.outputFolder) { $cfg.outputFolder = [IO.Path]::GetFullPath((Join-Path $baseDir "..\Backups")) }
    return $cfg
}

function Get-Builder([string]$cs) {
    try {
        $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $cs
        if ($b.DataSource -and $b.InitialCatalog) { return $b }
    } catch { }
    return $null
}

function Get-SafeName([string]$name) { return ($name -replace '[\\/:*?"<>|]', '_').Trim() }

# Engine-neutral summary of a connection string: @{ Engine; Server; Database }, or $null if it's not valid.
function Get-ConnInfo([string]$cs) {
    if ((Get-DbEngine $cs) -eq "pg") {
        $p = Get-PgConn $cs
        if (-not $p) { return $null }
        return [pscustomobject]@{ Engine = "pg"; Server = "$($p.Host):$($p.Port)"; Database = $p.Database }
    }
    $b = Get-Builder $cs
    if (-not $b) { return $null }
    return [pscustomobject]@{ Engine = "mssql"; Server = $b.DataSource; Database = $b.InitialCatalog }
}

# Asks SQL Server or PostgreSQL. Returns "mssql" or "pg", or $null to quit.
function Select-Engine {
    Write-Host ""
    Write-Host "Database type:" -ForegroundColor Yellow
    Write-Host "  1. SQL Server"
    Write-Host "  2. PostgreSQL"
    Write-Host "  Q. Quit"
    while ($true) {
        $a = Ask ">"
        if ($a -eq "1") { return "mssql" }
        if ($a -eq "2") { return "pg" }
        if ($a -match '^[Qq]$') { return $null }
        Write-Host "Type 1 or 2." -ForegroundColor Red
    }
}

# Lets the user pick connections from connections.txt (or paste one), optionally only of one -Engine ("mssql"/"pg").
# Returns one connection (-Single) or an array, or $null when the user quits.
function Select-Connections([string]$prompt, [switch]$Single, [string]$Engine) {
    while ($true) {
        $cfg = Read-Config
        foreach ($w in $cfg.Warnings) { Write-Host "  connections.txt: $w" -ForegroundColor Yellow }
        $list = @($cfg.Connections | Where-Object { -not $Engine -or (Get-DbEngine $_.ConnectionString) -eq $Engine })
        Write-Host ""
        Write-Host $prompt -ForegroundColor Yellow
        for ($i = 0; $i -lt $list.Count; $i++) {
            $ci = Get-ConnInfo $list[$i].ConnectionString
            $where = if ($ci) { "$($ci.Server) / $($ci.Database)" } else { "(invalid connection string)" }
            $tag = if ($Engine) { "" } elseif ($ci) { "[$(Get-EngineLabel $ci.Engine)] " } else { "" }
            Write-Host ("  {0,2}. {1,-22} {2}{3}" -f ($i + 1), $list[$i].Name, $tag, $where)
        }
        if ($list.Count -eq 0) { Write-Host "  (no $(if ($Engine) { Get-EngineLabel $Engine } else { '' }) connections yet - press E to add some)" -ForegroundColor DarkGray }
        if (-not $Single -and $list.Count -gt 1) { Write-Host "   A. All of them" }
        Write-Host "   P. Paste a connection string that isn't in the list"
        Write-Host "   E. Add / change connections"
        Write-Host "   Q. Quit"
        if ($Single) { Write-Host "  Type a number." -ForegroundColor DarkGray }
        else { Write-Host "  Type a number, several numbers (e.g. 1,3), or A." -ForegroundColor DarkGray }
        $ans = Ask ">"

        if ($ans -match '^[Qq]$') { return $null }
        if ($ans -match '^[Ee]$') {
            & (Join-Path $ToolDir "Edit-Connections.ps1") -ConfigPath $ConfigPath
            continue
        }
        if ($ans -match '^[Pp]$') {
            $cs = (Ask "Paste the connection string").Trim('"')
            $ci = Get-ConnInfo $cs
            if (-not $ci) { Write-Host "That isn't a valid connection string." -ForegroundColor Red; continue }
            if ($Engine -and $ci.Engine -ne $Engine) { Write-Host "That's a $(Get-EngineLabel $ci.Engine) connection string, not $(Get-EngineLabel $Engine)." -ForegroundColor Red; continue }
            $c = [pscustomobject]@{ Name = $ci.Database; ConnectionString = $cs }
            if ($Single) { return $c } else { return , @($c) }
        }
        if (-not $Single -and $ans -match '^[Aa]$' -and $list.Count) { return , $list }

        $nums = @($ans -split '[,\s]+' | Where-Object { $_ })
        $ok = $nums.Count -gt 0
        foreach ($x in $nums) { if ($x -notmatch '^\d+$' -or [int]$x -lt 1 -or [int]$x -gt $list.Count) { $ok = $false } }
        if (-not $ok) { Write-Host "Not a valid choice." -ForegroundColor Red; continue }
        $picked = @($nums | ForEach-Object { [int]$_ } | Select-Object -Unique | ForEach-Object { $list[$_ - 1] })
        foreach ($p in $picked) {
            if (-not (Get-ConnInfo $p.ConnectionString)) { Write-Host "'$($p.Name)' has an invalid connection string - fix it in connections.txt (E)." -ForegroundColor Red; $ok = $false }
        }
        if (-not $ok) { continue }
        if ($Single) {
            if ($picked.Count -ne 1) { Write-Host "Pick just one." -ForegroundColor Red; continue }
            return $picked[0]
        }
        return , $picked
    }
}

# ---------------------------------------------------------------- database helpers

function Invoke-Query([string]$cs, [string]$sql, [int]$timeout = 300) {
    $c = New-Object System.Data.SqlClient.SqlConnection $cs
    $c.Open()
    try {
        $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = $timeout
        $dt = New-Object System.Data.DataTable
        [void](New-Object System.Data.SqlClient.SqlDataAdapter $cmd).Fill($dt)
        return , $dt
    } finally { $c.Close() }
}

function Invoke-NonQuery([string]$cs, [string]$sql) {
    $c = New-Object System.Data.SqlClient.SqlConnection $cs
    $c.Open()
    try { $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 0; return $cmd.ExecuteNonQuery() } finally { $c.Close() }
}

# Returns $null when the connection works, otherwise the error message.
function Test-DbConnection([string]$cs) {
    if ((Get-DbEngine $cs) -eq "pg") { return Test-PgConnection (Get-PgConn $cs) }
    try { $c = New-Object System.Data.SqlClient.SqlConnection $cs; $c.Open(); $c.Close(); return $null }
    catch { return $_.Exception.InnerException.Message, $_.Exception.Message | Where-Object { $_ } | Select-Object -First 1 }
}

function NZ($v) { if ($v -is [DBNull]) { return $null } else { return $v } }

function Test-IsLocalServer([string]$dataSource, [string]$localServer) {
    function Norm([string]$s) {
        $s = $s.Trim().ToLower() -replace '^(tcp|np|lpc):', ''
        $parts = $s.Split('\'); $h = $parts[0].Split(',')[0]
        if ($h -in @('.', '(local)', 'localhost', '127.0.0.1', $env:COMPUTERNAME.ToLower())) { $h = 'localhost' }
        if ($parts.Count -gt 1) { return "$h\$($parts[1])" } else { return $h }
    }
    return (Norm $dataSource) -eq (Norm $localServer)
}

# ---------------------------------------------------------------- database structure (used by dump + compare)

$NonComparable = @('xml', 'text', 'ntext', 'image', 'sql_variant', 'geography', 'geometry', 'hierarchyid', 'timestamp')
$DateTypes = @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset', 'time')

function QN([string]$n) { return "[" + $n.Replace("]", "]]") + "]" }
function Q($t) { return (QN $t.Schema) + "." + (QN $t.Name) }
function SqlStr([string]$s) { return "N'" + $s.Replace("'", "''") + "'" }

function Get-DbMeta([string]$cs) {
    $m = @{ Tables = @{}; Fks = @(); Schemas = @{}; DbCollation = $null }
    $m.DbCollation = [string](Invoke-Query $cs "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(200)) AS C").Rows[0].C
    $cols = Invoke-Query $cs @"
SELECT s.name AS S, t.name AS N, c.name AS C, ty.name AS Ty, c.max_length AS ML, c.precision AS P, c.scale AS Sc,
       c.is_nullable AS Nu, c.is_identity AS Idn, CAST(ic.seed_value AS bigint) AS Seed, CAST(ic.increment_value AS bigint) AS Incr,
       c.is_computed AS Comp, cc.definition AS CompDef, cc.is_persisted AS Pers, dc.definition AS Def,
       dc.name AS DefName, dc.is_system_named AS DefSys, c.collation_name AS Coll
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
LEFT JOIN sys.default_constraints dc ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name, c.column_id
"@
    foreach ($r in $cols.Rows) {
        $full = "$($r.S).$($r.N)"
        if (-not $m.Tables.ContainsKey($full)) {
            $m.Tables[$full] = [pscustomobject]@{ Full = $full; Schema = $r.S; Name = $r.N; Columns = (New-Object System.Collections.ArrayList); Col = @{}; Pk = @(); PkName = $null; PkType = "CLUSTERED"; Rows = [long]0 }
        }
        $coll = NZ $r.Coll
        $c = [pscustomobject]@{
            Name = $r.C; Type = ([string]$r.Ty).ToLower(); MaxLen = [int]$r.ML; Prec = [int]$r.P; Scale = [int]$r.Sc
            Nullable = [bool]$r.Nu; Identity = [bool]$r.Idn; Seed = (NZ $r.Seed); Incr = (NZ $r.Incr)
            Computed = [bool]$r.Comp; CompDef = (NZ $r.CompDef); Persisted = [bool](NZ $r.Pers); Default = (NZ $r.Def)
            DefName = (NZ $r.DefName); DefSys = [bool](NZ $r.DefSys)
            Collate = $(if ($coll -and $coll -ne $m.DbCollation) { $coll } else { $null })
        }
        [void]$m.Tables[$full].Columns.Add($c)
        $m.Tables[$full].Col[$c.Name] = $c
    }
    $pks = Invoke-Query $cs @"
SELECT s.name AS S, t.name AS N, i.name AS I, i.type_desc AS D, c.name AS C
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.indexes i ON i.object_id = t.object_id AND i.is_primary_key = 1
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = t.object_id AND c.column_id = ic.column_id
WHERE t.is_ms_shipped = 0 ORDER BY s.name, t.name, ic.key_ordinal
"@
    foreach ($r in $pks.Rows) {
        $t = $m.Tables["$($r.S).$($r.N)"]
        if ($t) { $t.Pk += [string]$r.C; $t.PkName = $r.I; $t.PkType = $r.D }
    }
    $counts = Invoke-Query $cs "SELECT s.name AS S, t.name AS N, SUM(p.rows) AS R FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) WHERE t.is_ms_shipped = 0 GROUP BY s.name, t.name"
    foreach ($r in $counts.Rows) { $t = $m.Tables["$($r.S).$($r.N)"]; if ($t) { $t.Rows = [long]$r.R } }
    $fks = Invoke-Query $cs @"
SELECT fk.name AS N, SCHEMA_NAME(pt.schema_id) + '.' + pt.name AS Child, SCHEMA_NAME(rt.schema_id) + '.' + rt.name AS Parent,
       fk.delete_referential_action_desc AS OnDel, fk.update_referential_action_desc AS OnUpd, fk.is_disabled AS Dis, fk.is_not_trusted AS NT,
       STUFF((SELECT ',' + QUOTENAME(c.name) FROM sys.foreign_key_columns k JOIN sys.columns c ON c.object_id = k.parent_object_id AND c.column_id = k.parent_column_id
              WHERE k.constraint_object_id = fk.object_id ORDER BY k.constraint_column_id FOR XML PATH('')), 1, 1, '') AS ChildCols,
       STUFF((SELECT ',' + QUOTENAME(c.name) FROM sys.foreign_key_columns k JOIN sys.columns c ON c.object_id = k.referenced_object_id AND c.column_id = k.referenced_column_id
              WHERE k.constraint_object_id = fk.object_id ORDER BY k.constraint_column_id FOR XML PATH('')), 1, 1, '') AS ParentCols
FROM sys.foreign_keys fk
JOIN sys.tables pt ON pt.object_id = fk.parent_object_id
JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
"@
    $m.Fks = @($fks.Rows | ForEach-Object { [pscustomobject]@{ Name = $_.N; Child = $_.Child; Parent = $_.Parent; OnDel = $_.OnDel; OnUpd = $_.OnUpd; Disabled = [bool]$_.Dis; NotTrusted = [bool]$_.NT; ChildCols = $_.ChildCols; ParentCols = $_.ParentCols } })
    foreach ($r in (Invoke-Query $cs "SELECT name FROM sys.schemas").Rows) { $m.Schemas[[string]$r.name] = $true }
    return $m
}

function Get-TypeSql($c) {
    if ($c.PSObject.Properties["TypeSql"] -and $c.TypeSql) { return $c.TypeSql }
    $t = $c.Type
    if ($t -match '^n(var)?char$') { if ($c.MaxLen -eq -1) { return "$t(max)" } else { return "$t($($c.MaxLen / 2))" } }
    if ($t -match '^(var)?char$|^(var)?binary$') { if ($c.MaxLen -eq -1) { return "$t(max)" } else { return "$t($($c.MaxLen))" } }
    if ($t -match '^(decimal|numeric)$') { return "$t($($c.Prec),$($c.Scale))" }
    if ($t -match '^(datetime2|time|datetimeoffset)$') { return "$t($($c.Scale))" }
    return $t
}

function Get-ZeroValue($c) {
    $t = $c.Type
    if ($t -match 'char|text') { return "(N'')" }
    if ($t -match 'date|time') { return "('19000101')" }
    if ($t -eq 'uniqueidentifier') { return "('00000000-0000-0000-0000-000000000000')" }
    if ($t -match 'binary|image') { return "(0x)" }
    return "((0))"
}

function Get-ColumnSql($c, [bool]$needTempDefault = $false, [string]$tmpName = "") {
    if ($c.Computed) { $x = (QN $c.Name) + " AS " + $c.CompDef; if ($c.Persisted) { $x += " PERSISTED" }; return $x }
    $x = (QN $c.Name) + " " + (Get-TypeSql $c)
    if ($c.Collate) { $x += " COLLATE " + $c.Collate }
    if ($c.Identity) { $x += " IDENTITY($($c.Seed),$($c.Incr))" }
    if ($c.Nullable) { $x += " NULL" } else { $x += " NOT NULL" }
    if ($c.Default) {
        if ($c.DefName -and -not $c.DefSys) { $x += " CONSTRAINT " + (QN $c.DefName) }
        $x += " DEFAULT " + $c.Default
    }
    elseif ($needTempDefault) { $x += " CONSTRAINT " + (QN $tmpName) + " DEFAULT " + (Get-ZeroValue $c) }
    return $x
}

function Get-CreateTableSql($t) {
    $lines = @($t.Columns | ForEach-Object { "    " + (Get-ColumnSql $_) })
    if ($t.Pk.Count) {
        $kind = if ($t.PkType -match 'NONCLUSTERED') { "NONCLUSTERED" } else { "CLUSTERED" }
        $lines += "    CONSTRAINT " + (QN $t.PkName) + " PRIMARY KEY $kind (" + (($t.Pk | ForEach-Object { QN $_ }) -join ", ") + ")"
    }
    return "CREATE TABLE " + (Q $t) + " (`r`n" + ($lines -join ",`r`n") + "`r`n);"
}

function Get-FkSql($fk, $meta) {
    $c = $meta.Tables[$fk.Child]; $p = $meta.Tables[$fk.Parent]
    $check = if ($fk.NotTrusted -or $fk.Disabled) { "WITH NOCHECK" } else { "WITH CHECK" }
    $s = "ALTER TABLE " + (Q $c) + " $check ADD CONSTRAINT " + (QN $fk.Name) + " FOREIGN KEY (" + $fk.ChildCols + ") REFERENCES " + (Q $p) + " (" + $fk.ParentCols + ") ON DELETE " + $fk.OnDel.Replace("_", " ") + " ON UPDATE " + $fk.OnUpd.Replace("_", " ") + ";"
    if ($fk.Disabled) { $s += " ALTER TABLE " + (Q $c) + " NOCHECK CONSTRAINT " + (QN $fk.Name) + ";" }
    return $s
}

# Parent tables first, so inserts satisfy foreign keys (reverse it for deletes).
function Get-TableOrder($meta, $tables) {
    $inSet = @{}; foreach ($t in $tables) { $inSet[$t] = $true }
    $order = New-Object System.Collections.ArrayList
    $state = @{}
    function Visit($t) {
        if ($state[$t]) { return }
        $state[$t] = 1
        foreach ($fk in $meta.Fks) { if ($fk.Child -eq $t -and $fk.Parent -ne $t -and $inSet[$fk.Parent]) { Visit $fk.Parent } }
        [void]$order.Add($t)
    }
    foreach ($t in ($tables | Sort-Object)) { Visit $t }
    return , $order
}

# ---------------------------------------------------------------- backups

$BackupStampRx = '^(?<p>.+)_(?<s>\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})\.(?<e>bak|zip|sql|sql\.zip|dump|dump\.zip)$'

# Backs up one connection into <outputFolder>\<name>\. Returns the new backup file.
#   SQL Server: $format = "bak" or "sql".   PostgreSQL: $format = "dump" or "sql".
function Invoke-Backup($cfg, $conn, [string]$format = "bak") {
    $folder = Join-Path $cfg.outputFolder (Get-SafeName $conn.Name)
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    if ((Get-DbEngine $conn.ConnectionString) -eq "pg") {
        if ($format -eq "bak") { $format = "dump" }
        return (Export-PgBackup (Get-PgConn $conn.ConnectionString) $format $folder -Zip)
    }
    if ($format -eq "sql") {
        $file = & (Join-Path $ToolDir "Export-SqlDump.ps1") -ConnectionString $conn.ConnectionString -OutputDir $folder -Zip
        return (Get-Item -LiteralPath ([string]@($file)[-1]))
    }
    $start = (Get-Date).AddSeconds(-2)
    $b = Get-Builder $conn.ConnectionString
    if (Test-IsLocalServer $b.DataSource $cfg.localServer) {
        & (Join-Path $ToolDir "Backup-FromConnectionString.ps1") -ConnectionString $conn.ConnectionString -OutputDir $folder -Zip | Out-Host
    }
    else {
        & (Join-Path $ToolDir "Backup-RemoteDatabase.ps1") -ConnectionString $conn.ConnectionString -OutputDir $folder -LocalServer $cfg.localServer -Zip | Out-Host
    }
    $bak = Get-ChildItem -LiteralPath $folder -Filter *.bak | Where-Object { $_.LastWriteTime -ge $start } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $bak) { throw "No .bak file was produced." }
    return $bak
}

# Offers to delete older backups (.bak/.sql and their .zip) of the same database in the same folder.
# $newFiles = the backups just made (they and their zips are never offered for deletion).
function Clear-OldBackups($newFiles, [string]$label) {
    $newFiles = @($newFiles)
    $folder = $newFiles[0].DirectoryName
    $m = [regex]::Match($newFiles[0].Name, $BackupStampRx)
    if (-not $m.Success) { return }
    $prefix = $m.Groups['p'].Value
    $newStamps = @($newFiles | ForEach-Object { [regex]::Match($_.Name, $BackupStampRx).Groups['s'].Value })
    $groups = @(Get-ChildItem -LiteralPath $folder -File | ForEach-Object {
            $x = [regex]::Match($_.Name, $BackupStampRx)
            if ($x.Success -and $x.Groups['p'].Value -eq $prefix -and $newStamps -notcontains $x.Groups['s'].Value) {
                [pscustomobject]@{ File = $_; Stamp = $x.Groups['s'].Value; Ext = "." + $x.Groups['e'].Value }
            }
        } | Group-Object Stamp | Sort-Object Name -Descending)   # newest first
    if ($groups.Count -eq 0) { return }

    Write-Host ""
    Write-Host "Older backups of '$label' in ${folder}:" -ForegroundColor Yellow
    $i = 0
    foreach ($g in $groups) {
        $i++
        $mb = [Math]::Round((($g.Group | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum) / 1MB, 1)
        $kinds = ($g.Group | ForEach-Object { $_.Ext } | Sort-Object) -join " + "
        Write-Host ("  {0,2}. {1}_{2}  ({3}, {4} MB)" -f $i, $prefix, $g.Name, $kinds, $mb)
    }
    Write-Host "   D. Delete all of them (keep only the new backup)"
    Write-Host "   K. Keep the newest few, delete the rest"
    Write-Host "   N. Keep everything"
    $ans = Ask ">"
    $toDelete = @()
    if ($ans -match '^[Dd]$') { $toDelete = $groups }
    elseif ($ans -match '^[Kk]$') {
        $keep = Ask "How many older backups to keep?"
        if ($keep -notmatch '^\d+$') { Write-Host "Not a number - nothing deleted." -ForegroundColor Yellow; return }
        $toDelete = @($groups | Select-Object -Skip ([int]$keep))
    }
    if ($toDelete.Count -eq 0) { Write-Host "  Nothing deleted."; return }
    $freed = 0
    foreach ($g in $toDelete) { foreach ($x in $g.Group) { $freed += $x.File.Length; Remove-Item -LiteralPath $x.File.FullName -Force } }
    Write-Host ("  Deleted {0} old backup(s), freed {1} MB." -f $toDelete.Count, [Math]::Round($freed / 1MB, 1)) -ForegroundColor Green
}

# Asks for the backup format. SQL Server: "bak"/"sql"; PostgreSQL: "dump"/"sql". Returns an array.
function Select-BackupFormat([string]$engine = "mssql") {
    Write-Host ""
    Write-Host "Backup format:" -ForegroundColor Yellow
    $first = "bak"
    if ($engine -eq "pg") {
        $first = "dump"
        Write-Host "  1. .dump - PostgreSQL backup file (custom format, restore with pg_restore / Restore Database.bat)"
        Write-Host "  2. .sql  - plain SQL script (restore with psql / Restore Database.bat)"
    } else {
        Write-Host "  1. .bak  - SQL Server backup file (restores on SQL Server 2022 or newer)"
        Write-Host "  2. .sql  - script with structure + data (any SQL Server 2014+, works with read-only logins)"
    }
    Write-Host "  3. Both"
    while ($true) {
        $a = Ask ">"
        if ($a -eq "1") { return , @($first) }
        if ($a -eq "2") { return , @("sql") }
        if ($a -eq "3") { return , @($first, "sql") }
        Write-Host "Type 1, 2 or 3." -ForegroundColor Red
    }
}

# ---------------------------------------------------------------- local server / restore helpers

function Get-MasterCs([string]$localServer) { return "Data Source=$localServer;Initial Catalog=master;Integrated Security=True;TrustServerCertificate=True" }
function Get-LocalDbCs([string]$localServer, [string]$db) { return "Data Source=$localServer;Initial Catalog=$db;Integrated Security=True;TrustServerCertificate=True" }

function Test-LocalDbExists([string]$masterCs, [string]$db) {
    return -not ((Invoke-Query $masterCs ("SELECT DB_ID(" + (SqlStr $db) + ") AS id")).Rows[0].id -is [DBNull])
}

function Remove-LocalDatabase([string]$masterCs, [string]$db) {
    Invoke-NonQuery $masterCs ("IF DB_ID(" + (SqlStr $db) + ") IS NOT NULL BEGIN ALTER DATABASE " + (QN $db) + " SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE " + (QN $db) + "; END") | Out-Null
}

# A temp folder the SQL Server service account can read/write (it can't read your own folders).
function New-SqlServiceFolder([string]$masterCs) {
    $svc = [string](Invoke-Query $masterCs "SELECT TOP 1 service_account AS A FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%'").Rows[0].A
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("sqlrestore_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    & icacls.exe $dir /grant "${svc}:(OI)(CI)M" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not give SQL Server ($svc) access to $dir." }
    return $dir
}

# Restores a .bak into a database on the local server (new or replaced).
function Restore-BakLocal([string]$masterCs, [string]$bakPath, [string]$db, [bool]$replace) {
    $stage = New-SqlServiceFolder $masterCs
    try {
        $copy = Join-Path $stage "restore.bak"
        Copy-Item -LiteralPath $bakPath -Destination $copy
        $hdr = Invoke-Query $masterCs ("RESTORE HEADERONLY FROM DISK = " + (SqlStr $copy))
        $last = $hdr.Rows | Sort-Object { [int]$_.Position } | Select-Object -Last 1
        $localMajor = [int]((Invoke-Query $masterCs "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS V").Rows[0].V)
        if ([int]$last.SoftwareVersionMajor -gt $localMajor) { throw "This backup comes from a newer SQL Server (version $($last.SoftwareVersionMajor)) than the local one ($localMajor) and can't be restored here." }
        $files = Invoke-Query $masterCs ("RESTORE FILELISTONLY FROM DISK = " + (SqlStr $copy) + " WITH FILE = " + $last.Position)
        $paths = (Invoke-Query $masterCs "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)) AS D, CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(400)) AS L").Rows[0]
        $safe = Get-SafeName $db
        $moves = @(); $nd = 0; $nl = 0
        foreach ($f in $files.Rows) {
            if ($f.Type -eq 'L') { $nl++; $p = Join-Path $paths.L ("{0}_log{1}.ldf" -f $safe, $(if ($nl -gt 1) { $nl } else { "" })) }
            elseif ($f.Type -eq 'S') { $p = Join-Path $paths.D ("{0}_fs_{1}" -f $safe, $f.LogicalName) }
            else { $nd++; $p = Join-Path $paths.D ("{0}{1}.{2}" -f $safe, $(if ($nd -gt 1) { "_$nd" } else { "" }), $(if ($nd -gt 1) { "ndf" } else { "mdf" })) }
            $moves += "MOVE " + (SqlStr $f.LogicalName) + " TO " + (SqlStr $p)
        }
        if ($replace -and (Test-LocalDbExists $masterCs $db)) { Invoke-NonQuery $masterCs ("ALTER DATABASE " + (QN $db) + " SET SINGLE_USER WITH ROLLBACK IMMEDIATE") | Out-Null }
        $sql = "RESTORE DATABASE " + (QN $db) + " FROM DISK = " + (SqlStr $copy) + " WITH FILE = " + $last.Position + ", " + ($moves -join ", ") + ", RECOVERY, STATS = 20" + $(if ($replace) { ", REPLACE" } else { "" })
        Write-Host "  Restoring $([IO.Path]::GetFileName($bakPath)) into [$db]..."
        Invoke-NonQuery $masterCs $sql | Out-Null
        Invoke-NonQuery $masterCs ("ALTER DATABASE " + (QN $db) + " SET MULTI_USER") | Out-Null
    }
    finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

# Drops every table, view, procedure and function in a database (used before restoring over it).
function Clear-Database([string]$cs) {
    Invoke-NonQuery $cs "DECLARE @s nvarchar(max) = N''; SELECT @s += N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) + N' DROP CONSTRAINT ' + QUOTENAME(f.name) + N';' FROM sys.foreign_keys f JOIN sys.tables t ON t.object_id = f.parent_object_id; EXEC sp_executesql @s;" | Out-Null
    for ($pass = 1; $pass -le 5; $pass++) {
        $objs = Invoke-Query $cs "SELECT o.type AS T, QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name) AS N FROM sys.objects o WHERE o.is_ms_shipped = 0 AND o.parent_object_id = 0 AND o.type IN ('V','P','FN','IF','TF','U') ORDER BY CASE o.type WHEN 'U' THEN 1 ELSE 0 END"
        if ($objs.Rows.Count -eq 0) { return }
        foreach ($o in $objs.Rows) {
            $kind = switch (([string]$o.T).Trim()) { 'V' { 'VIEW' } 'P' { 'PROCEDURE' } 'U' { 'TABLE' } default { 'FUNCTION' } }
            try { Invoke-NonQuery $cs "DROP $kind $($o.N);" | Out-Null } catch { }
        }
    }
    $left = (Invoke-Query $cs "SELECT COUNT(*) AS N FROM sys.objects WHERE is_ms_shipped = 0 AND parent_object_id = 0 AND type IN ('V','P','FN','IF','TF','U')").Rows[0].N
    if ($left -gt 0) { throw "Could not remove $left object(s) from the database." }
}

function Get-UserObjectCount([string]$cs) {
    return [int](Invoke-Query $cs "SELECT COUNT(*) AS N FROM sys.objects WHERE is_ms_shipped = 0 AND parent_object_id = 0 AND type IN ('V','P','FN','IF','TF','U')").Rows[0].N
}

# If $path is a .zip, extracts the first .bak/.sql/.bacpac inside to a temp folder.
# Returns @{ Path = file to use; Temp = folder to delete afterwards (or $null) }.
function Expand-BackupFile([string]$path) {
    if ($path -notmatch '\.zip$') { return @{ Path = $path; Temp = $null } }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("sqlunzip_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    Write-Host "  Unzipping $([IO.Path]::GetFileName($path))..."
    Expand-Archive -LiteralPath $path -DestinationPath $tmp
    $f = Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { $_.Extension -in '.bak', '.sql', '.bacpac', '.dump' } | Select-Object -First 1
    if (-not $f) { Remove-Item $tmp -Recurse -Force; throw "The zip doesn't contain a .bak, .sql, .bacpac or .dump file." }
    return @{ Path = $f.FullName; Temp = $tmp }
}

# Database name from a backup file name: "MyDb_2026-10-05_14-52-18.bak" -> "MyDb".
function Get-DbNameFromFile([string]$path) {
    $n = [IO.Path]::GetFileName($path) -replace '(\.zip)$', '' -replace '\.(bak|sql|bacpac|dump)$', ''
    return ($n -replace '_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$', '')
}

# Lets the user pick a backup file: recent ones from the backup folder, browse, or paste a path.
function Select-BackupFile($cfg, [string[]]$extensions, [string]$prompt) {
    $exts = @($extensions | ForEach-Object { $_.ToLower() })
    while ($true) {
        $roots = @($cfg.outputFolder, $ToolDir) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        $files = @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -File -Recurse -ErrorAction SilentlyContinue } |
            Where-Object { $n = $_.Name.ToLower(); @($exts | Where-Object { $n.EndsWith($_) }).Count -gt 0 } |
            Sort-Object FullName -Unique | Sort-Object LastWriteTime -Descending | Select-Object -First 15)
        Write-Host ""
        Write-Host $prompt -ForegroundColor Yellow
        for ($i = 0; $i -lt $files.Count; $i++) {
            Write-Host ("  {0,2}. {1,-62} {2,8} MB  {3:yyyy-MM-dd HH:mm}" -f ($i + 1), $files[$i].Name, [Math]::Round($files[$i].Length / 1MB, 1), $files[$i].LastWriteTime)
        }
        if ($files.Count -eq 0) { Write-Host "  (no backup files found in $($cfg.outputFolder))" -ForegroundColor DarkGray }
        Write-Host "   B. Browse for a file..."
        Write-Host "   P. Paste a file path"
        Write-Host "   Q. Quit"
        $a = Ask ">"
        if ($a -match '^[Qq]$') { return $null }
        if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $files.Count) { return $files[[int]$a - 1].FullName }
        if ($a -match '^[Bb]$') {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = $prompt
            $dlg.Filter = "Backup files (" + (($exts | ForEach-Object { "*$_" }) -join ";") + ")|" + (($exts | ForEach-Object { "*$_" }) -join ";") + "|All files (*.*)|*.*"
            if (Test-Path -LiteralPath $cfg.outputFolder) { $dlg.InitialDirectory = $cfg.outputFolder }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
            continue
        }
        if ($a -match '^[Pp]$') {
            $p = (Ask "File path").Trim('"')
            if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).Path }
            Write-Host "File not found." -ForegroundColor Red; continue
        }
        Write-Host "Not a valid choice." -ForegroundColor Red
    }
}

# PostgreSQL support
. (Join-Path $ToolDir "PgTools.ps1")
