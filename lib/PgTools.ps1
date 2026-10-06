# PostgreSQL support for the database tools. Dot-sourced by Common.ps1 - not meant to be run on its own.
# Uses the portable PostgreSQL tools in %USERPROFILE%\pgsql\bin (downloaded automatically on first use).

$PgBin = Join-Path $env:USERPROFILE "pgsql\bin"
$PgLocalData = Join-Path $env:USERPROFILE "pgsql\localdata"   # private PostgreSQL server on this PC
$PgLocalPort = 54329
$PgDownloadUrl = "https://get.enterprisedb.com/postgresql/postgresql-18.3-1-windows-x64-binaries.zip"

# ---------------------------------------------------------------- connection strings

# "pg" for PostgreSQL connection strings (Host=...;Username=... or postgresql://...), otherwise "mssql".
function Get-DbEngine([string]$cs) {
    if ($cs -match '^\s*postgres(ql)?://' -or $cs -match '(^|;)\s*(Host|Username)\s*=') { return "pg" }
    return "mssql"
}
function Get-EngineLabel([string]$e) { if ($e -eq "pg") { return "PostgreSQL" } else { return "SQL Server" } }

# Parses an Npgsql-style ("Host=..;Port=..;Database=..;Username=..;Password=..") or URI connection string.
function Get-PgConn([string]$cs) {
    $r = [ordered]@{ Host = $null; Port = 5432; Database = $null; User = $null; Password = $null; SslMode = $null }
    if ($cs -match '^\s*postgres(ql)?://') {
        $u = [Uri]$cs.Trim()
        $r.Host = $u.Host; if ($u.Port -gt 0) { $r.Port = $u.Port }
        $r.Database = [Uri]::UnescapeDataString($u.AbsolutePath.TrimStart('/'))
        if ($u.UserInfo) { $ui = $u.UserInfo.Split(':', 2); $r.User = [Uri]::UnescapeDataString($ui[0]); if ($ui.Count -gt 1) { $r.Password = [Uri]::UnescapeDataString($ui[1]) } }
        if ($u.Query -match 'sslmode=([^&]+)') { $r.SslMode = $Matches[1] }
    }
    else {
        foreach ($part in $cs.Split(';')) {
            $i = $part.IndexOf('='); if ($i -lt 1) { continue }
            $k = ($part.Substring(0, $i).Trim().ToLower()) -replace '\s', ''
            $v = $part.Substring($i + 1).Trim()
            if ($k -in 'host', 'server') { $r.Host = $v }
            elseif ($k -eq 'port') { $r.Port = [int]$v }
            elseif ($k -in 'database', 'db') { $r.Database = $v }
            elseif ($k -in 'username', 'userid', 'user', 'uid') { $r.User = $v }
            elseif ($k -in 'password', 'pwd') { $r.Password = $v }
            elseif ($k -eq 'sslmode') { $r.SslMode = ($v.ToLower() -replace '^verifyfull$', 'verify-full' -replace '^verifyca$', 'verify-ca') }
        }
    }
    if (-not $r.Host -or -not $r.Database) { return $null }
    return [pscustomobject]$r
}

# libpq connection string for psql/pg_dump/pg_restore (the password goes in PGPASSWORD, never on the command line).
function Get-PgConnInfo($pg, [string]$database) {
    function QV([string]$v) { if ($v -match '^[A-Za-z0-9_.\-]+$') { return $v } else { return "'" + $v.Replace('\', '\\').Replace("'", "\'") + "'" } }
    $db = if ($database) { $database } else { $pg.Database }
    $s = "host=$(QV $pg.Host) port=$($pg.Port) dbname=$(QV $db)"
    if ($pg.User) { $s += " user=$(QV $pg.User)" }
    if ($pg.SslMode) { $s += " sslmode=$(QV $pg.SslMode)" }
    return $s
}

function PgQN([string]$n) { return '"' + $n.Replace('"', '""') + '"' }
function PgQ($t) { return (PgQN $t.Schema) + "." + (PgQN $t.Name) }
function PgStr([string]$s) { return "'" + $s.Replace("'", "''") + "'" }

# ---------------------------------------------------------------- running the PostgreSQL tools

function Assert-PgTools {
    if (Test-Path (Join-Path $PgBin "psql.exe")) { return }
    Write-Host "  PostgreSQL tools not found - downloading them from EnterpriseDB (about 340 MB, one time only)..."
    $zip = Join-Path ([IO.Path]::GetTempPath()) "pgsql-binaries.zip"
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest $PgDownloadUrl -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $old }
    Expand-Archive $zip -DestinationPath $env:USERPROFILE -Force   # creates %USERPROFILE%\pgsql
    Remove-Item $zip -Force
    # EDB's binaries aren't code-signed, so check that the download (over HTTPS from EDB) actually runs.
    $v = & (Join-Path $PgBin "psql.exe") --version 2>$null
    if ($v -notmatch 'PostgreSQL') { throw "The downloaded PostgreSQL tools don't work - delete $env:USERPROFILE\pgsql and try again." }
}

function Join-ProcessArgs([string[]]$list) {
    return (($list | ForEach-Object {
                if ($_ -eq '') { '""' }
                elseif ($_ -notmatch '[\s"]') { $_ }
                else { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
            }) -join ' ')
}

# Runs a PostgreSQL tool. Returns @{ Code; Out; Err }. -NoRedirect for pg_ctl start (the server inherits its handles).
function Invoke-PgExe([string]$exe, [string[]]$arguments, $pg, [switch]$NoRedirect) {
    Assert-PgTools
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $PgBin $exe
    $psi.Arguments = Join-ProcessArgs $arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["PGCLIENTENCODING"] = "UTF8"
    $psi.EnvironmentVariables["PGCONNECT_TIMEOUT"] = "30"
    if ($pg -and $pg.Password) { $psi.EnvironmentVariables["PGPASSWORD"] = $pg.Password }
    if (-not $NoRedirect) {
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($NoRedirect) { $p.WaitForExit(); return [pscustomobject]@{ Code = $p.ExitCode; Out = ""; Err = "" } }
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $errTask.Result }
}

function Assert-PgOk($r, [string]$what) {
    if ($r.Code -ne 0) {
        $e = (($r.Err + "`n" + $r.Out).Trim() -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 8) -join "`n"
        throw "$what failed: $e"
    }
}

function New-TempFile([string]$ext) { return Join-Path ([IO.Path]::GetTempPath()) ("pg_" + [guid]::NewGuid().ToString("N").Substring(0, 10) + $ext) }
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

# Runs SQL and returns the rows as string arrays (NULL comes back as an empty string).
function Invoke-PgQuery($pg, [string]$sql, [string]$database) {
    $in = New-TempFile ".sql"; $out = New-TempFile ".txt"
    try {
        [IO.File]::WriteAllText($in, $sql, $Utf8NoBom)
        $r = Invoke-PgExe "psql.exe" @("-X", "-q", "-A", "-t", "-z", "-v", "ON_ERROR_STOP=1", "-d", (Get-PgConnInfo $pg $database), "-f", $in, "-o", $out) $pg
        Assert-PgOk $r "PostgreSQL query"
        $rows = New-Object System.Collections.Generic.List[object]
        if (Test-Path $out) {
            foreach ($line in [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8).Split("`n")) {
                $line = $line.TrimEnd("`r")
                if ($line.Length) { $rows.Add([string[]]$line.Split([char]0)) }
            }
        }
        return , $rows
    }
    finally { Remove-Item $in, $out -ErrorAction SilentlyContinue }
}

function Invoke-PgScript($pg, [string]$file, [string]$database, [switch]$SingleTransaction) {
    $a = @("-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", (Get-PgConnInfo $pg $database), "-f", $file)
    if ($SingleTransaction) { $a = @("-1") + $a }
    $r = Invoke-PgExe "psql.exe" $a $pg
    Assert-PgOk $r "Running $([IO.Path]::GetFileName($file))"
    return $r
}

function Test-PgConnection($pg) {
    if ($pg.Host -in 'localhost', '127.0.0.1' -and [int]$pg.Port -eq $PgLocalPort) { [void](Start-PgLocal) }   # private server on this PC
    $r = Invoke-PgExe "psql.exe" @("-X", "-q", "-t", "-c", "select 1", "-d", (Get-PgConnInfo $pg)) $pg
    if ($r.Code -eq 0) { return $null }
    return (($r.Err.Trim() -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 1)
}

# ---------------------------------------------------------------- structure (same shape as Get-DbMeta)

$PgUserSchemas = "n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%'"

function Get-PgMeta([string]$cs) {
    $pg = Get-PgConn $cs
    $m = @{ Tables = @{}; Fks = @(); Schemas = @{}; DbCollation = $null; Engine = "pg" }
    $cols = Invoke-PgQuery $pg @"
SELECT n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod), t.typname,
       a.attnotnull, a.attidentity, a.attgenerated, pg_get_expr(d.adbin, d.adrelid), GREATEST(c.reltuples, 0)::bigint
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
JOIN pg_type t ON t.oid = a.atttypid
LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND $PgUserSchemas
ORDER BY n.nspname, c.relname, a.attnum;
"@
    foreach ($r in $cols) {
        $full = "$($r[0]).$($r[1])"
        if (-not $m.Tables.ContainsKey($full)) {
            $m.Tables[$full] = [pscustomobject]@{ Full = $full; Schema = $r[0]; Name = $r[1]; Columns = (New-Object System.Collections.ArrayList); Col = @{}; Pk = @(); PkName = $null; PkType = $null; Rows = [long]$r[9] }
        }
        $gen = $r[7] -eq 's'
        $c = [pscustomobject]@{
            Name = $r[2]; Type = $r[4].ToLower(); TypeSql = $r[3]; Nullable = ($r[5] -ne 't')
            Identity = ($r[6] -eq 'a' -or $r[6] -eq 'd'); IdentityAlways = ($r[6] -eq 'a')
            Computed = $gen; CompDef = $(if ($gen) { $r[8] } else { $null }); Default = $(if (-not $gen -and $r[8]) { $r[8] } else { $null })
            Collate = $null
        }
        [void]$m.Tables[$full].Columns.Add($c)
        $m.Tables[$full].Col[$c.Name] = $c
    }
    $pks = Invoke-PgQuery $pg @"
SELECT n.nspname, c.relname, con.conname, a.attname
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
WHERE con.contype = 'p' AND $PgUserSchemas
ORDER BY n.nspname, c.relname, k.ord;
"@
    foreach ($r in $pks) { $t = $m.Tables["$($r[0]).$($r[1])"]; if ($t) { $t.Pk += $r[3]; $t.PkName = $r[2] } }
    $fks = Invoke-PgQuery $pg @"
SELECT con.conname, cn.nspname || '.' || cc.relname, pn.nspname || '.' || pc.relname
FROM pg_constraint con
JOIN pg_class cc ON cc.oid = con.conrelid JOIN pg_namespace cn ON cn.oid = cc.relnamespace
JOIN pg_class pc ON pc.oid = con.confrelid JOIN pg_namespace pn ON pn.oid = pc.relnamespace
WHERE con.contype = 'f';
"@
    $m.Fks = @($fks | ForEach-Object { [pscustomobject]@{ Name = $_[0]; Child = $_[1]; Parent = $_[2] } })
    foreach ($r in (Invoke-PgQuery $pg "SELECT n.nspname FROM pg_namespace n WHERE $PgUserSchemas;")) { $m.Schemas[$r[0]] = $true }
    return $m
}

function Get-PgObjectCount($pg, [string]$database) {
    $r = Invoke-PgQuery $pg @"
SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p','v','m','S','f') AND $PgUserSchemas)
     + (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE $PgUserSchemas
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e'));
"@ $database
    return [int]$r[0][0]
}

function Get-PgSummary($pg, [string]$database) {
    $r = Invoke-PgQuery $pg @"
SELECT count(*), COALESCE(sum((xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text::bigint), 0)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND $PgUserSchemas;
"@ $database
    return "$($r[0][0]) tables, $($r[0][1]) rows"
}

# Drops all tables, views, sequences, functions and types in the user schemas (before restoring over a database).
function Clear-PgDatabase($pg, [string]$database) {
    $sql = @'
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT n.nspname, c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE c.relkind IN ('v', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
             AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e') LOOP
    EXECUTE format('DROP %s IF EXISTS %I.%I CASCADE', CASE r.relkind WHEN 'v' THEN 'VIEW' ELSE 'MATERIALIZED VIEW' END, r.nspname, r.relname);
  END LOOP;
  FOR r IN SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE c.relkind IN ('r', 'p', 'f') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
             AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e') LOOP
    EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE', r.nspname, r.relname);
  END LOOP;
  FOR r IN SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE c.relkind = 'S' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
             AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e') LOOP
    EXECUTE format('DROP SEQUENCE IF EXISTS %I.%I CASCADE', r.nspname, r.relname);
  END LOOP;
  FOR r IN SELECT p.oid::regprocedure AS f FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND p.prokind IN ('f', 'p')
             AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') LOOP
    EXECUTE format('DROP ROUTINE IF EXISTS %s CASCADE', r.f);
  END LOOP;
  FOR r IN SELECT n.nspname, t.typname FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
           WHERE t.typtype IN ('e', 'd', 'c') AND (t.typrelid = 0 OR (SELECT relkind FROM pg_class WHERE oid = t.typrelid) = 'c')
             AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
             AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e') LOOP
    EXECUTE format('DROP TYPE IF EXISTS %I.%I CASCADE', r.nspname, r.typname);
  END LOOP;
  FOR r IN SELECT n.nspname FROM pg_namespace n
           WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'public') AND n.nspname NOT LIKE 'pg_%'
             AND pg_get_userbyid(n.nspowner) = current_user LOOP
    EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', r.nspname);
  END LOOP;
END $$;
'@
    $f = New-TempFile ".sql"
    try { [IO.File]::WriteAllText($f, $sql, $Utf8NoBom); [void](Invoke-PgScript $pg $f $database) } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    $left = Get-PgObjectCount $pg $database
    if ($left -gt 0) { throw "Could not remove $left object(s) - they are probably owned by another database user." }
}

# ---------------------------------------------------------------- backup / restore / convert

# pg_dump to <folder>\<db>_<stamp>.dump (custom format, for pg_restore) or .sql (plain script). Returns the file.
function Export-PgBackup($pg, [string]$format, [string]$folder, [switch]$Zip) {
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $ext = if ($format -eq "dump") { "dump" } else { "sql" }
    $file = Join-Path (Resolve-Path $folder).Path ("{0}_{1}.{2}" -f (Get-SafeName $pg.Database), (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"), $ext)
    Write-Host "Server  : $($pg.Host):$($pg.Port)  (PostgreSQL)"
    Write-Host "Database: $($pg.Database)"
    Write-Host "Dumping to $([IO.Path]::GetFileName($file)) ..."
    $started = Get-Date
    $r = Invoke-PgExe "pg_dump.exe" @("--no-owner", "--no-acl", "-F", $(if ($ext -eq "dump") { "c" } else { "p" }), "-f", $file, "-d", (Get-PgConnInfo $pg)) $pg
    Assert-PgOk $r "pg_dump"
    # check the file is complete
    if ($ext -eq "dump") {
        $l = Invoke-PgExe "pg_restore.exe" @("--list", $file) $null
        Assert-PgOk $l "Checking the dump"
        $n = @($l.Out -split "`n" | Where-Object { $_ -match ' TABLE DATA ' }).Count
        Write-Host "  Verified: dump is readable ($n tables with data)." -ForegroundColor Green
    }
    else {
        $tail = Get-Content -LiteralPath $file -Tail 5 -Encoding UTF8
        if (-not ($tail -match 'PostgreSQL database dump complete')) { throw "The dump file looks incomplete (no end marker)." }
        Write-Host "  Verified: dump is complete." -ForegroundColor Green
    }
    $fi = Get-Item -LiteralPath $file
    Write-Host ("Dump saved: {0} ({1} MB, {2}s)" -f $fi.FullName, [Math]::Round($fi.Length / 1MB, 1), [int]((Get-Date) - $started).TotalSeconds) -ForegroundColor Green
    if ($Zip) {
        Compress-Archive -LiteralPath $file -DestinationPath "$file.zip" -Force
        Write-Host "Zipped    : $file.zip ($([Math]::Round((Get-Item -LiteralPath "$file.zip").Length / 1MB, 1)) MB)"
    }
    return $fi
}

# Is this .sql a PostgreSQL dump (pg_dump) rather than a SQL Server one?
function Test-PgSqlFile([string]$path) {
    $head = Get-Content -LiteralPath $path -TotalCount 40 -Encoding UTF8
    return [bool]($head -match 'PostgreSQL database dump|pg_dump|SET client_encoding|\\restrict ')
}

# Restores a .dump or .sql into an existing (preferably empty) database.
# Errors that don't matter on a hosted server (e.g. "must be owner of extension") are reported as warnings.
function Restore-PgFile($pg, [string]$file, [string]$database) {
    $isDump = [IO.Path]::GetExtension($file) -eq ".dump"
    Write-Host "  Restoring $([IO.Path]::GetFileName($file)) into [$(if ($database) { $database } else { $pg.Database })]..."
    if ($isDump) { $r = Invoke-PgExe "pg_restore.exe" @("--no-owner", "--no-acl", "-d", (Get-PgConnInfo $pg $database), $file) $pg }
    else { $r = Invoke-PgExe "psql.exe" @("-X", "-q", "-d", (Get-PgConnInfo $pg $database), "-f", $file) $pg }
    $errors = @(($r.Err -split "`r?`n") | Where-Object { $_ -match 'ERROR:' })
    $harmless = 'must be owner of (extension|schema)|permission denied to (create|comment)|extension .* already exists|schema "public" already exists|only superuser|COMMENT ON EXTENSION'
    $real = @($errors | Where-Object { $_ -notmatch $harmless })
    foreach ($e in ($errors | Where-Object { $_ -match $harmless })) { Write-Host "  (ignored) $($e.Trim())" -ForegroundColor DarkGray }
    if ($real.Count) { throw ("Restore finished with $($real.Count) error(s):`n" + (($real | Select-Object -First 8) -join "`n")) }
    if ($r.Code -ne 0 -and $errors.Count -eq 0) { Assert-PgOk $r "Restore" }
}

# .dump -> .sql (no server needed)
function Convert-PgDumpToSql([string]$dumpFile, [string]$sqlFile) {
    $r = Invoke-PgExe "pg_restore.exe" @("--no-owner", "--no-acl", "-f", $sqlFile, $dumpFile) $null
    Assert-PgOk $r "Converting the dump"
}

# ---------------------------------------------------------------- private PostgreSQL server on this PC

function Get-PgLocalConn([string]$db = "postgres") {
    return [pscustomobject]@{ Host = "localhost"; Port = $PgLocalPort; Database = $db; User = "postgres"; Password = $null; SslMode = "disable" }
}

# Starts the private server (creating it the first time). Returns $true if this call started it.
function Start-PgLocal {
    Assert-PgTools
    if (-not (Test-Path (Join-Path $PgLocalData "PG_VERSION"))) {
        Write-Host "  Setting up a private PostgreSQL server on this PC (one time, port $PgLocalPort)..."
        $r = Invoke-PgExe "initdb.exe" @("-D", $PgLocalData, "-U", "postgres", "-A", "trust", "-E", "UTF8", "--locale=C") $null
        Assert-PgOk $r "Creating the local PostgreSQL server"
    }
    $st = Invoke-PgExe "pg_ctl.exe" @("-D", $PgLocalData, "status") $null
    if ($st.Code -eq 0) { return $false }
    # Started through the shell so the server doesn't inherit (and hold open) this window's handles.
    $p = Start-Process -FilePath (Join-Path $PgBin "pg_ctl.exe") -WindowStyle Hidden -PassThru -ArgumentList (Join-ProcessArgs @("-D", $PgLocalData, "-l", (Join-Path $PgLocalData "server.log"), "-o", "-p $PgLocalPort -c listen_addresses=localhost", "-w", "start"))
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "Could not start the local PostgreSQL server - see $PgLocalData\server.log" }
    return $true
}

function Stop-PgLocal { [void](Invoke-PgExe "pg_ctl.exe" @("-D", $PgLocalData, "-m", "fast", "-w", "stop") $null) }

function Test-PgLocalDbExists([string]$db) {
    $r = Invoke-PgQuery (Get-PgLocalConn) ("SELECT count(*) FROM pg_database WHERE datname = " + (PgStr $db) + ";")
    return [int]$r[0][0] -gt 0
}
function New-PgLocalDb([string]$db) { [void](Invoke-PgQuery (Get-PgLocalConn) ("CREATE DATABASE " + (PgQN $db) + ";")) }
function Remove-PgLocalDb([string]$db) { [void](Invoke-PgQuery (Get-PgLocalConn) ("DROP DATABASE IF EXISTS " + (PgQN $db) + " WITH (FORCE);")) }

# .sql -> .dump (loads the script into a temporary database on the private server, then pg_dump -Fc)
function Convert-PgSqlToDump([string]$sqlFile, [string]$dumpFile) {
    $started = Start-PgLocal
    $tmp = "convert_" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    try {
        New-PgLocalDb $tmp
        Restore-PgFile (Get-PgLocalConn $tmp) $sqlFile
        $r = Invoke-PgExe "pg_dump.exe" @("--no-owner", "--no-acl", "-F", "c", "-f", $dumpFile, "-d", (Get-PgConnInfo (Get-PgLocalConn $tmp))) $null
        Assert-PgOk $r "pg_dump"
    }
    finally { try { Remove-PgLocalDb $tmp } catch { }; if ($started) { Stop-PgLocal } }
}

# ---------------------------------------------------------------- compare / sync

function Get-PgKeyExpr($t) { return (@($t.Pk | ForEach-Object { "(" + (PgQN $_) + ")::text" }) -join " || '|' || ") }

function Compare-PgTable($src, $tgt, [string]$full) {
    $res = [pscustomobject]@{ Table = $full; SrcRows = $null; TgtRows = $null; OnlySrc = @(); OnlyTgt = @(); Changed = @(); Status = ""; Cols = @(); KeyExpr = $null }
    $s = $src.Meta.Tables[$full]; $t = $tgt.Meta.Tables[$full]
    if ($s) { $res.SrcRows = $s.Rows }
    if ($t) { $res.TgtRows = $t.Rows }
    if (-not $s) { $res.Status = "MissingSrc"; return $res }
    if (-not $t) { $res.Status = "MissingTgt"; return $res }
    if ($s.Pk.Count -eq 0 -or $t.Pk.Count -eq 0) { $res.Status = "Skipped: no primary key"; return $res }
    if (($s.Pk -join ',') -ne ($t.Pk -join ',')) { $res.Status = "Skipped: primary keys differ"; return $res }
    $common = @($s.Columns | Where-Object { $tc = $t.Col[$_.Name]; $tc -and -not $_.Computed -and -not $tc.Computed })
    $res.Cols = @($common | ForEach-Object { $t.Col[$_.Name].Name })
    $res.KeyExpr = Get-PgKeyExpr $s
    $sql = "SET TIME ZONE 'UTC'; SET DateStyle = ISO; SET extra_float_digits = 3; SELECT " + $res.KeyExpr + ", md5(ROW(" + (($common | ForEach-Object { PgQN $_.Name }) -join ", ") + ")::text) FROM "
    $hs = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $ht = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($r in (Invoke-PgQuery $src.Pg ($sql + (PgQ $s) + ";"))) { $hs[$r[0]] = $r[1] }
    foreach ($r in (Invoke-PgQuery $tgt.Pg ($sql + (PgQ $t) + ";"))) { $ht[$r[0]] = $r[1] }
    $onlyS = New-Object System.Collections.Generic.List[string]
    $onlyT = New-Object System.Collections.Generic.List[string]
    $chg = New-Object System.Collections.Generic.List[string]
    $h = $null
    foreach ($k in $hs.Keys) { if ($ht.TryGetValue($k, [ref]$h)) { if ($h -ne $hs[$k]) { $chg.Add($k) } } else { $onlyS.Add($k) } }
    foreach ($k in $ht.Keys) { if (-not $hs.ContainsKey($k)) { $onlyT.Add($k) } }
    $res.SrcRows = $hs.Count; $res.TgtRows = $ht.Count
    $res.OnlySrc = $onlyS; $res.OnlyTgt = $onlyT; $res.Changed = $chg
    $res.Status = if ($onlyS.Count + $onlyT.Count + $chg.Count -eq 0) { "Same" } else { "Different" }
    return $res
}

function Get-PgZeroValue($c) {
    switch -regex ($c.Type) {
        '^(int2|int4|int8|numeric|float4|float8|money|oid)$' { return "0" }
        '^bool$' { return "false" }
        '^(text|varchar|bpchar|name|citext)$' { return "''" }
        '^(date|timestamp|timestamptz)$' { return "'1970-01-01'" }
        '^(time|timetz)$' { return "'00:00'" }
        '^uuid$' { return "'00000000-0000-0000-0000-000000000000'" }
        '^bytea$' { return "'\x'" }
        '^(json|jsonb)$' { return "'{}'" }
        default { return $null }
    }
}

# DDL (as a script file) that creates the missing tables/columns in the target, copied from the source database.
function New-PgDdlFromDatabase($items, $src, $tgt, [string]$workDir) {
    $file = Join-Path $workDir "structure.sql"
    $parts = New-Object System.Collections.Generic.List[string]
    $newTables = @($items | Where-Object Kind -eq "Table" | ForEach-Object Table)
    foreach ($s in ($newTables | ForEach-Object { $src.Meta.Tables[$_].Schema } | Sort-Object -Unique)) {
        if (-not $tgt.Meta.Schemas[$s]) { $parts.Add("CREATE SCHEMA IF NOT EXISTS " + (PgQN $s) + ";") }
    }
    if ($newTables.Count) {
        $a = @("-s", "--no-owner", "--no-acl")
        foreach ($full in $newTables) {
            $t = $src.Meta.Tables[$full]
            $a += @("-t", ((PgQN $t.Schema) + "." + (PgQN $t.Name)))
            foreach ($c in $t.Columns) { if ($c.Default -match "^nextval\('(.+?)'(::regclass)?\)") { $a += @("-t", $Matches[1]) } }   # serial sequences
        }
        $tmp = Join-Path $workDir "tables.sql"
        $r = Invoke-PgExe "pg_dump.exe" ($a + @("-f", $tmp, "-d", (Get-PgConnInfo $src.Pg))) $src.Pg
        Assert-PgOk $r "Reading table structure from $($src.Name)"
        $parts.Add([IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8))
    }
    foreach ($it in ($items | Where-Object Kind -eq "Column")) {
        $s = $src.Meta.Tables[$it.Table]; $t = $tgt.Meta.Tables[$it.Table]; $c = $s.Col[$it.Column]
        $def = "ALTER TABLE " + (PgQ $t) + " ADD COLUMN " + (PgQN $c.Name) + " " + $c.TypeSql
        if ($c.Computed) { $def += " GENERATED ALWAYS AS (" + $c.CompDef + ") STORED;" }
        else {
            if ($c.Identity) { $def += $(if ($c.IdentityAlways) { " GENERATED ALWAYS AS IDENTITY" } else { " GENERATED BY DEFAULT AS IDENTITY" }) }
            elseif ($c.Default -and $c.Default -notmatch '^nextval\(') { $def += " DEFAULT " + $c.Default }
            if (-not $c.Nullable -and -not $c.Identity) {
                if ($c.Default -or $t.Rows -eq 0) { $def += " NOT NULL;" }
                else {
                    $z = Get-PgZeroValue $c
                    if ($z) { $def += " NOT NULL DEFAULT $z; ALTER TABLE " + (PgQ $t) + " ALTER COLUMN " + (PgQN $c.Name) + " DROP DEFAULT;" } else { $def += ";" }
                }
            }
            else { $def += ";" }
        }
        $parts.Add($def)
    }
    [IO.File]::WriteAllText($file, ($parts -join "`n`n"), $Utf8NoBom)
    return $file
}

function ConvertFrom-CopyText([string]$s) {
    if ($s.IndexOf('\') -lt 0) { return $s }
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $s.Length; $i++) {
        $ch = $s[$i]
        if ($ch -ne '\' -or $i -eq $s.Length - 1) { [void]$sb.Append($ch); continue }
        $i++; $n = $s[$i]
        switch ($n) { 't' { [void]$sb.Append("`t") } 'n' { [void]$sb.Append("`n") } 'r' { [void]$sb.Append("`r") } 'b' { [void]$sb.Append([char]8) } 'f' { [void]$sb.Append([char]12) } 'v' { [void]$sb.Append([char]11) } default { [void]$sb.Append($n) } }
    }
    return $sb.ToString()
}

# Exports the wanted rows of one source table as COPY text files: one for inserts, one for updates.
function Export-PgRows($src, $s, $cols, [string]$keyExpr, $insKeys, $updKeys, [string]$workDir, [int]$n) {
    $all = Join-Path $workDir "t${n}_all.tsv"
    $sel = "SELECT " + $keyExpr + ", " + (($cols | ForEach-Object { PgQN $s.Col[$_].Name }) -join ", ") + " FROM " + (PgQ $s)
    $script = Join-Path $workDir "t${n}_export.sql"
    [IO.File]::WriteAllText($script, "SET TIME ZONE 'UTC';`nSET DateStyle = ISO;`nSET extra_float_digits = 3;`n\copy ($sel) TO '" + $all.Replace('\', '/').Replace("'", "''") + "'`n", $Utf8NoBom)
    [void](Invoke-PgScript $src.Pg $script)
    $ins = [System.Collections.Generic.HashSet[string]]::new([string[]]@($insKeys))
    $upd = [System.Collections.Generic.HashSet[string]]::new([string[]]@($updKeys))
    $res = @{ Ins = (Join-Path $workDir "t${n}_ins.tsv"); Upd = (Join-Path $workDir "t${n}_upd.tsv"); InsCount = 0; UpdCount = 0 }
    $wi = New-Object IO.StreamWriter($res.Ins, $false, $Utf8NoBom); $wi.NewLine = "`n"
    $wu = New-Object IO.StreamWriter($res.Upd, $false, $Utf8NoBom); $wu.NewLine = "`n"
    $rd = New-Object IO.StreamReader($all, [Text.Encoding]::UTF8)
    try {
        while ($null -ne ($line = $rd.ReadLine())) {
            $tab = $line.IndexOf("`t"); if ($tab -lt 0) { continue }
            $key = ConvertFrom-CopyText $line.Substring(0, $tab)
            if ($ins.Contains($key)) { $wi.WriteLine($line.Substring($tab + 1)); $res.InsCount++ }
            elseif ($upd.Contains($key)) { $wu.WriteLine($line.Substring($tab + 1)); $res.UpdCount++ }
        }
    }
    finally { $rd.Close(); $wi.Close(); $wu.Close() }
    return $res
}

function Invoke-PgSyncJob($cfg, $src, $tgt, [bool]$doIns, [bool]$doUpd, [bool]$doDel) {
    $what = @(); if ($doIns) { $what += "add" }; if ($doUpd) { $what += "update" }; if ($doDel) { $what += "delete" }
    Write-Step ("Changing {0}  (using {1} as the source; will {2} rows)" -f $tgt.Name, $src.Name, ($what -join "/"))
    $work = Join-Path ([IO.Path]::GetTempPath()) ("pgsync_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        # ---- 1. missing tables / columns
        $ddlFile = $null; $ddlLines = @()
        if ($doIns -or $doUpd) {
            $items = Get-MissingSchema $src $tgt
            if ($items.Count) {
                Write-Host ""
                Write-Host "$($tgt.Name) is missing these tables/columns that exist in $($src.Name):" -ForegroundColor Yellow
                foreach ($it in $items) { if ($it.Kind -eq "Table") { Write-Host "  table   $($it.Table)" } else { Write-Host "  column  $($it.Table).$($it.Column)" } }
                Write-Host ""
                Write-Host "How should they be created?"
                Write-Host "  1. Copy their structure from $($src.Name)  (recommended)"
                $hasFile = [bool]$cfg.schemaFile
                if ($hasFile) { Write-Host "  2. Build them from the schema file: $($cfg.schemaFile)" } else { Write-Host "  2. Build them from a schema file  (not available - set schemaFile in connections.txt)" -ForegroundColor DarkGray }
                Write-Host "  3. Don't create them - leave those tables/columns out of the sync"
                $ans = Ask ">"
                if ($ans -eq "1") {
                    $ddlFile = New-PgDdlFromDatabase $items $src $tgt $work
                    $ddlLines = @($items | ForEach-Object { if ($_.Kind -eq "Table") { "CREATE TABLE $($_.Table) (+ its keys, indexes and sequences)" } else { "ADD COLUMN $($_.Table).$($_.Column)" } })
                }
                elseif ($ans -eq "2" -and $hasFile) {
                    $r = Get-DdlFromFile $items $tgt (Get-SchemaFileSql $cfg.schemaFile)
                    foreach ($nf in $r.NotFound) { Write-Host "  Not in schema file, skipped: $($nf.Table)$(if ($nf.Column) { '.' + $nf.Column })" -ForegroundColor Yellow }
                    if ($r.Stmts.Count) {
                        $ddlFile = Join-Path $work "structure.sql"
                        [IO.File]::WriteAllText($ddlFile, (@($r.Stmts) -join "`n"), $Utf8NoBom)
                        $ddlLines = @($r.Stmts | ForEach-Object { ($_ -split "`r?`n")[0] })
                    }
                }
                else { Write-Host "  Skipping missing tables/columns." }
            }
        }

        # ---- 2. backup
        Write-Host ""
        Write-Host "Back up $($tgt.Name) before changing it?" -ForegroundColor Yellow
        Write-Host "  1. Yes, as .dump  (recommended)"
        Write-Host "  2. Yes, as .sql"
        Write-Host "  3. No"
        $fmt = Ask ">"
        if ($fmt -eq "1" -or $fmt -eq "2") {
            try { $bak = Invoke-Backup $cfg $tgt.Conn $(if ($fmt -eq "1") { "dump" } else { "sql" }); Write-Host "  Backup: $($bak.FullName)" -ForegroundColor Green }
            catch {
                Write-Host "  Backup failed: $($_.Exception.Message)" -ForegroundColor Red
                if (-not (Confirm-Yes "Continue WITHOUT a backup?")) { Write-Host "  Cancelled - nothing was changed."; return }
            }
        }

        # ---- 3. structure
        if ($ddlFile) {
            Write-Host ""
            Write-Host "Structure changes for $($tgt.Name):" -ForegroundColor Yellow
            foreach ($l in $ddlLines) { Write-Host "  $l" }
            if (-not (Confirm-Yes "Apply these structure change(s)?")) { Write-Host "  Cancelled - nothing was changed."; return }
            [void](Invoke-PgScript $tgt.Pg $ddlFile -SingleTransaction)
            Write-Host "  Structure updated." -ForegroundColor Green
            $tgt.Meta = Get-PgMeta $tgt.Cs
        }

        # ---- 4. plan
        Write-Host ""
        Write-Host "Working out the row changes..."
        $plan = @{}
        $tables = @($src.Meta.Tables.Keys | Where-Object { $tgt.Meta.Tables.ContainsKey($_) } | Sort-Object)
        $i = 0
        foreach ($full in $tables) {
            $i++
            Write-Progress -Activity "Comparing" -Status "$full ($i of $($tables.Count))" -PercentComplete ($i * 100 / $tables.Count)
            $d = Compare-PgTable $src $tgt $full
            if ($d.Status -ne "Different") { if ($d.Status -like "Skipped*") { Write-Host "  $full - $($d.Status)" -ForegroundColor DarkGray }; continue }
            $none = New-Object System.Collections.Generic.List[string]
            $p = [pscustomobject]@{ Table = $full; Ins = $none; Upd = $none; Del = $none; Cols = $d.Cols; KeyExpr = $d.KeyExpr; Note = "" }
            if ($doIns) { $p.Ins = $d.OnlySrc }
            if ($doUpd) { $p.Upd = $d.Changed }
            if ($doDel) { $p.Del = $d.OnlyTgt }
            if ($p.Ins.Count) {
                $s = $src.Meta.Tables[$full]
                $blockers = @($tgt.Meta.Tables[$full].Columns | Where-Object { -not $s.Col[$_.Name] -and -not $_.Nullable -and -not $_.Default -and -not $_.Identity -and -not $_.Computed })
                if ($blockers.Count) { $p.Note = "can't add rows: required column(s) only in $($tgt.Name): " + (($blockers | ForEach-Object Name) -join ", "); $p.Ins = $none }
            }
            if ($p.Ins.Count + $p.Upd.Count + $p.Del.Count -gt 0 -or $p.Note) { $plan[$full] = $p }
        }
        Write-Progress -Activity "Comparing" -Completed
        $work2 = @($plan.Values | Where-Object { $_.Ins.Count + $_.Upd.Count + $_.Del.Count -gt 0 })
        foreach ($p in ($plan.Values | Where-Object Note)) { Write-Host "  $($p.Table): $($p.Note)" -ForegroundColor Yellow }
        if ($work2.Count -eq 0) { Write-Host "  Nothing to change - $($tgt.Name) already matches for the chosen action." -ForegroundColor Green; return }

        Write-Host ""
        Write-Host "Planned changes to $($tgt.Name):" -ForegroundColor Yellow
        $work2 | Sort-Object Table | ForEach-Object { [pscustomobject]@{ Table = $_.Table; "Add rows" = $_.Ins.Count; "Update rows" = $_.Upd.Count; "Delete rows" = $_.Del.Count } } |
            Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        Write-Host ""
        if ((Ask "Type YES to apply these changes to $($tgt.Name)") -cne "YES") { Write-Host "  Cancelled - no rows were changed."; return }

        # ---- 5. build one script (one transaction) and run it on the target
        Write-Host "  Reading the rows from $($src.Name)..."
        $order = Get-TableOrder $tgt.Meta @($work2 | ForEach-Object Table)
        $sb = New-Object System.Collections.Generic.List[string]
        $sb.Add("SET client_encoding = 'UTF8';"); $sb.Add("SET TIME ZONE 'UTC';"); $sb.Add("SET DateStyle = ISO;"); $sb.Add("BEGIN;")
        $n = 0; $report = @()
        foreach ($full in $order) {
            $p = $plan[$full]; $s = $src.Meta.Tables[$full]; $t = $tgt.Meta.Tables[$full]
            if ($p.Ins.Count + $p.Upd.Count -eq 0) { continue }
            $n++
            $rows = Export-PgRows $src $s $p.Cols $p.KeyExpr $p.Ins $p.Upd $work $n
            $colList = ($p.Cols | ForEach-Object { PgQN $_ }) -join ", "
            $tq = PgQ $t
            $over = if (@($p.Cols | Where-Object { $t.Col[$_].Identity }).Count) { " OVERRIDING SYSTEM VALUE" } else { "" }
            if ($rows.InsCount) {
                $sb.Add("CREATE TEMP TABLE _sync_stage AS SELECT $colList FROM $tq WITH NO DATA;")
                $sb.Add("\copy _sync_stage ($colList) FROM '" + $rows.Ins.Replace('\', '/') + "'")
                $sb.Add("INSERT INTO $tq ($colList)$over SELECT $colList FROM _sync_stage;")
                $sb.Add("DROP TABLE _sync_stage;")
                foreach ($c in $t.Columns) {
                    if ($c.Identity -or $c.Default -match '^nextval\(') {
                        $sb.Add("SELECT setval(pg_get_serial_sequence(" + (PgStr $tq) + ", " + (PgStr $c.Name) + "), m) FROM (SELECT max(" + (PgQN $c.Name) + ") AS m FROM $tq) x WHERE m IS NOT NULL;")
                    }
                }
            }
            if ($rows.UpdCount) {
                $setCols = @($p.Cols | Where-Object { $t.Pk -notcontains $_ -and -not $t.Col[$_].IdentityAlways })
                if ($setCols.Count) {
                    $sb.Add("CREATE TEMP TABLE _sync_stage AS SELECT $colList FROM $tq WITH NO DATA;")
                    $sb.Add("\copy _sync_stage ($colList) FROM '" + $rows.Upd.Replace('\', '/') + "'")
                    $set = ($setCols | ForEach-Object { (PgQN $_) + " = s." + (PgQN $_) }) -join ", "
                    $on = ($t.Pk | ForEach-Object { "t." + (PgQN $_) + " = s." + (PgQN $_) }) -join " AND "
                    $sb.Add("UPDATE $tq AS t SET $set FROM _sync_stage AS s WHERE $on;")
                    $sb.Add("DROP TABLE _sync_stage;")
                }
            }
            $report += [pscustomobject]@{ Table = $full; Added = $rows.InsCount; Updated = $rows.UpdCount; Deleted = 0 }
        }
        for ($j = $order.Count - 1; $j -ge 0; $j--) {
            $full = $order[$j]; $p = $plan[$full]; $t = $tgt.Meta.Tables[$full]
            if (-not $p.Del.Count) { continue }
            for ($i = 0; $i -lt $p.Del.Count; $i += 500) {
                $c = [Math]::Min(500, $p.Del.Count - $i)
                $sb.Add("DELETE FROM " + (PgQ $t) + " WHERE (" + $p.KeyExpr + ") IN (" + (($p.Del.GetRange($i, $c) | ForEach-Object { PgStr $_ }) -join ",") + ");")
            }
            $existing = $report | Where-Object Table -eq $full
            if ($existing) { $existing.Deleted = $p.Del.Count } else { $report += [pscustomobject]@{ Table = $full; Added = 0; Updated = 0; Deleted = $p.Del.Count } }
        }
        $sb.Add("COMMIT;")
        $scriptFile = Join-Path $work "sync.sql"
        [IO.File]::WriteAllText($scriptFile, ($sb -join "`n") + "`n", $Utf8NoBom)
        Write-Host "  Applying the changes to $($tgt.Name) in one transaction..."
        try { [void](Invoke-PgScript $tgt.Pg $scriptFile) }
        catch { throw "Sync failed and was rolled back - $($tgt.Name) is unchanged. Reason: $($_.Exception.Message)" }
        foreach ($r in ($report | Sort-Object Table)) { Write-Host ("  {0,-40} added {1,6}  updated {2,6}  deleted {3,6}" -f $r.Table, $r.Added, $r.Updated, $r.Deleted) }
        Write-Host "  All changes saved to $($tgt.Name)." -ForegroundColor Green

        # ---- 6. re-check
        Write-Host "Re-checking..."
        $tgt.Meta = Get-PgMeta $tgt.Cs; $src.Meta = Get-PgMeta $src.Cs
        $left = 0
        foreach ($p in $work2) {
            $d = Compare-PgTable $src $tgt $p.Table
            $c = 0; if ($doIns) { $c += $d.OnlySrc.Count }; if ($doUpd) { $c += $d.Changed.Count }; if ($doDel) { $c += $d.OnlyTgt.Count }
            if ($c) { $left += $c; Write-Host "  $($p.Table): $c difference(s) remain" -ForegroundColor Yellow }
        }
        if ($left -eq 0) { Write-Host "  Verified: done." -ForegroundColor Green }
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
