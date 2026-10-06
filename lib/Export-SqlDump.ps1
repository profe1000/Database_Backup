<#
.SYNOPSIS
    Dumps a database to a .sql script: structure + all data. Needs only read access.

.DESCRIPTION
    The script recreates the database when run in an EMPTY database (Restore Database.bat,
    Import-SqlDump.ps1, SSMS or sqlcmd). Order inside the file:
      schemas -> tables (columns, defaults, primary keys) -> data (INSERT ... VALUES, 500 rows each)
      -> check/unique constraints and indexes -> foreign keys -> views, functions, procedures, triggers
    Works on SQL Server 2014 and newer. The last lines list the row count of every table, so a
    restore can verify nothing is missing.

    Not included: users/logins/permissions, sequences, synonyms, user-defined types, full-text.

.EXAMPLE
    .\Export-SqlDump.ps1 -ConnectionString "Data Source=...;Initial Catalog=MyDb;..." -OutputDir D:\Backups -Zip
#>
param(
    [Parameter(Mandatory = $true)][string]$ConnectionString,
    [string]$OutputDir,
    [string]$OutputFile,
    [switch]$Zip,
    [int]$RowsPerInsert = 500
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "Common.ps1")

if (-not ("SqlDumpWriter" -as [type])) {
    Add-Type -ReferencedAssemblies System.Data -TypeDefinition @"
using System;
using System.IO;
using System.Data.SqlClient;
using System.Globalization;

public static class SqlDumpWriter
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    // Streams all rows of the reader as INSERT ... VALUES batches separated by GO.
    public static long WriteTable(SqlDataReader r, TextWriter w, string[] kinds, string insertHead, string before, string after, int rowsPerInsert)
    {
        long n = 0; int inBatch = 0;
        while (r.Read())
        {
            if (n == 0 && !string.IsNullOrEmpty(before)) { w.Write(before); w.Write("\r\nGO\r\n"); }
            if (inBatch == 0) { w.Write(insertHead); w.Write("\r\n"); } else { w.Write(",\r\n"); }
            w.Write('(');
            for (int i = 0; i < kinds.Length; i++) { if (i > 0) w.Write(','); w.Write(Literal(r, i, kinds[i])); }
            w.Write(')');
            n++; inBatch++;
            if (inBatch >= rowsPerInsert) { w.Write(";\r\nGO\r\n"); inBatch = 0; }
        }
        if (inBatch > 0) w.Write(";\r\nGO\r\n");
        if (n > 0 && !string.IsNullOrEmpty(after)) { w.Write(after); w.Write("\r\nGO\r\n"); }
        return n;
    }

    static string Literal(SqlDataReader r, int i, string kind)
    {
        if (r.IsDBNull(i)) return "NULL";
        object v = r.GetValue(i);
        switch (kind)
        {
            case "num": return Convert.ToString(v, Inv);
            case "float": return Convert.ToDouble(v, Inv).ToString("R", Inv);
            case "bit": return Convert.ToBoolean(v) ? "1" : "0";
            case "datetime": return "'" + ((DateTime)v).ToString("yyyy-MM-ddTHH:mm:ss.fff", Inv) + "'";
            case "smalldatetime": return "'" + ((DateTime)v).ToString("yyyy-MM-ddTHH:mm:ss", Inv) + "'";
            case "date": return "'" + ((DateTime)v).ToString("yyyy-MM-dd", Inv) + "'";
            case "datetime2": return "'" + ((DateTime)v).ToString("yyyy-MM-ddTHH:mm:ss.fffffff", Inv) + "'";
            case "time": return "'" + ((TimeSpan)v).ToString("hh\\:mm\\:ss\\.fffffff", Inv) + "'";
            case "dto": return "'" + ((DateTimeOffset)v).ToString("yyyy-MM-ddTHH:mm:ss.fffffffzzz", Inv) + "'";
            case "guid": return "'" + v.ToString() + "'";
            case "bin":
            {
                byte[] b = (byte[])v;
                return b.Length == 0 ? "0x" : "0x" + BitConverter.ToString(b).Replace("-", "");
            }
            default:
            {
                string s = Convert.ToString(v, Inv).Replace("'", "''");
                if (s.IndexOf('\r') < 0 && s.IndexOf('\n') < 0) return "N'" + s + "'";
                // Keep every literal on one line, so a value can never be mistaken for a GO separator.
                return "CAST(N'' AS nvarchar(max)) + N'" + s.Replace("\r", "' + NCHAR(13) + N'").Replace("\n", "' + NCHAR(10) + N'") + "'";
            }
        }
    }
}
"@
}

function Get-ValueKind($c) {
    switch -regex ($c.Type) {
        '^(int|bigint|smallint|tinyint|decimal|numeric|money|smallmoney)$' { return "num" }
        '^(float|real)$' { return "float" }
        '^bit$' { return "bit" }
        '^(datetime|smalldatetime|date|datetime2|time)$' { return $c.Type }
        '^datetimeoffset$' { return "dto" }
        '^uniqueidentifier$' { return "guid" }
        '^(binary|varbinary|image|hierarchyid|geography|geometry)$' { return "bin" }
        default { return "str" }
    }
}

$csb = Get-Builder $ConnectionString
if (-not $csb) { throw "Invalid connection string (needs Data Source and Initial Catalog)." }
$db = $csb.InitialCatalog
if (-not $OutputFile) {
    if (-not $OutputDir) { $OutputDir = (Get-Location).Path }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $OutputFile = Join-Path (Resolve-Path $OutputDir).Path ("{0}_{1}.sql" -f (Get-SafeName $db), (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
}
$started = Get-Date
Write-Host "Server  : $($csb.DataSource)"
Write-Host "Database: $db"
Write-Host "Dump    : $OutputFile"
Write-Host "Reading structure..."
$meta = Get-DbMeta $ConnectionString
$version = [string](Invoke-Query $ConnectionString "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)) AS V").Rows[0].V

$idx = Invoke-Query $ConnectionString @"
SELECT s.name AS S, t.name AS T, i.name AS I, i.is_unique AS U, i.type_desc AS D, i.is_unique_constraint AS UC, i.filter_definition AS F,
       c.name AS C, ic.is_descending_key AS Dsc, ic.is_included_column AS Inc
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = i.object_id AND c.column_id = ic.column_id
WHERE t.is_ms_shipped = 0 AND i.is_primary_key = 0 AND i.type IN (1, 2) AND i.is_hypothetical = 0
ORDER BY s.name, t.name, i.name, ic.is_included_column, ic.key_ordinal, ic.index_column_id
"@
$checks = Invoke-Query $ConnectionString @"
SELECT s.name AS S, t.name AS T, cc.name AS N, cc.definition AS D, cc.is_disabled AS Dis, cc.is_not_trusted AS NT
FROM sys.check_constraints cc JOIN sys.tables t ON t.object_id = cc.parent_object_id JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0 ORDER BY s.name, t.name, cc.name
"@
$modules = Invoke-Query $ConnectionString @"
SELECT o.type AS T, SCHEMA_NAME(o.schema_id) AS S, o.name AS N, m.definition AS D, m.uses_ansi_nulls AS AN, m.uses_quoted_identifier AS QI
FROM sys.objects o LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.is_ms_shipped = 0 AND o.type IN ('V', 'P', 'FN', 'IF', 'TF', 'TR')
ORDER BY o.create_date, o.object_id
"@

$tables = @($meta.Tables.Keys | Sort-Object)
$w = New-Object IO.StreamWriter($OutputFile, $false, (New-Object Text.UTF8Encoding($true)), 1MB)
$counts = [ordered]@{}
$warnings = @()
try {
    function L([string]$s) { $w.Write($s); $w.Write("`r`n") }
    L "-- ============================================================================"
    L "-- SQL dump of database [$db] from $($csb.DataSource) (SQL Server $version)"
    L "-- Created $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by Export-SqlDump.ps1"
    L "-- Restore: run this script in an EMPTY database (Restore Database.bat, SSMS or sqlcmd)."
    L "-- ============================================================================"
    L "SET NOCOUNT ON;"; L "SET ANSI_NULLS ON;"; L "SET QUOTED_IDENTIFIER ON;"; L "GO"; L ""

    L "-- ---------------------------------------------------------------- schemas"
    foreach ($s in ($tables | ForEach-Object { $meta.Tables[$_].Schema } | Sort-Object -Unique)) {
        if ($s -ne "dbo") { L ("IF SCHEMA_ID(" + (SqlStr $s) + ") IS NULL EXEC(N'CREATE SCHEMA " + (QN $s).Replace("'", "''") + "');"); L "GO" }
    }
    L ""; L "-- ---------------------------------------------------------------- tables"
    foreach ($full in $tables) { L (Get-CreateTableSql $meta.Tables[$full]); L "GO" }

    L ""; L "-- ---------------------------------------------------------------- data"
    $i = 0
    foreach ($full in $tables) {
        $i++
        $t = $meta.Tables[$full]
        Write-Progress -Activity "Dumping data" -Status "$full ($i of $($tables.Count))" -PercentComplete ($i * 100 / $tables.Count)
        $cols = @($t.Columns | Where-Object { -not $_.Computed -and $_.Type -ne 'timestamp' })
        if ($cols.Count -eq 0) { continue }
        $sel = ($cols | ForEach-Object { if ($_.Type -in 'hierarchyid', 'geography', 'geometry') { "CAST(" + (QN $_.Name) + " AS varbinary(max)) AS " + (QN $_.Name) } else { QN $_.Name } }) -join ", "
        $order = if ($t.Pk.Count) { " ORDER BY " + (($t.Pk | ForEach-Object { QN $_ }) -join ", ") } else { "" }
        $hasId = @($cols | Where-Object Identity).Count -gt 0
        $before = if ($hasId) { "SET IDENTITY_INSERT " + (Q $t) + " ON;" } else { "" }
        $after = if ($hasId) { "SET IDENTITY_INSERT " + (Q $t) + " OFF;" } else { "" }
        $head = "INSERT INTO " + (Q $t) + " (" + (($cols | ForEach-Object { QN $_.Name }) -join ", ") + ") VALUES"
        $kinds = [string[]]@($cols | ForEach-Object { Get-ValueKind $_ })

        $conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
        $conn.Open()
        try {
            $cmd = $conn.CreateCommand(); $cmd.CommandTimeout = 0
            $cmd.CommandText = "SELECT $sel FROM $(Q $t)$order"
            $r = $cmd.ExecuteReader()
            L "-- $full"
            $n = [SqlDumpWriter]::WriteTable($r, $w, $kinds, $head, $before, $after, $RowsPerInsert)
            $r.Close()
        } finally { $conn.Close() }
        $counts[$full] = $n
    }
    Write-Progress -Activity "Dumping data" -Completed

    L ""; L "-- ---------------------------------------------------------------- constraints and indexes"
    foreach ($ck in $checks.Rows) {
        $tq = (QN $ck.S) + "." + (QN $ck.T)
        $mode = if ($ck.NT -or $ck.Dis) { "WITH NOCHECK" } else { "WITH CHECK" }
        L ("ALTER TABLE $tq $mode ADD CONSTRAINT " + (QN $ck.N) + " CHECK " + $ck.D + ";")
        if ($ck.Dis) { L ("ALTER TABLE $tq NOCHECK CONSTRAINT " + (QN $ck.N) + ";") }
        L "GO"
    }
    foreach ($g in ($idx.Rows | Group-Object { "$($_.S)|$($_.T)|$($_.I)" })) {
        $f = $g.Group[0]
        $tq = (QN $f.S) + "." + (QN $f.T)
        $keys = ($g.Group | Where-Object { -not $_.Inc } | ForEach-Object { (QN $_.C) + $(if ($_.Dsc) { " DESC" } else { " ASC" }) }) -join ", "
        $inc = @($g.Group | Where-Object { $_.Inc } | ForEach-Object { QN $_.C })
        $kind = if ($f.D -eq "CLUSTERED") { "CLUSTERED" } else { "NONCLUSTERED" }
        if ($f.UC) { L ("ALTER TABLE $tq ADD CONSTRAINT " + (QN $f.I) + " UNIQUE $kind ($keys);") }
        else {
            $s = "CREATE " + $(if ($f.U) { "UNIQUE " } else { "" }) + "$kind INDEX " + (QN $f.I) + " ON $tq ($keys)"
            if ($inc.Count) { $s += " INCLUDE (" + ($inc -join ", ") + ")" }
            if ((NZ $f.F)) { $s += " WHERE " + $f.F }
            L "$s;"
        }
        L "GO"
    }

    L ""; L "-- ---------------------------------------------------------------- foreign keys"
    foreach ($fk in ($meta.Fks | Sort-Object Child, Name)) { L (Get-FkSql $fk $meta); L "GO" }

    L ""; L "-- ---------------------------------------------------------------- views, functions, procedures, triggers"
    foreach ($m in $modules.Rows) {
        $def = NZ $m.D
        if (-not $def) { $warnings += "$($m.S).$($m.N)"; L "-- (definition of $($m.S).$($m.N) not readable with this login - skipped)"; continue }
        L ("SET ANSI_NULLS " + $(if ($m.AN) { "ON" } else { "OFF" }) + ";"); L ("SET QUOTED_IDENTIFIER " + $(if ($m.QI) { "ON" } else { "OFF" }) + ";"); L "GO"
        L $def.TrimEnd(); L "GO"
    }

    L ""; L "-- ---------------------------------------------------------------- row counts (used to verify a restore)"
    foreach ($k in $counts.Keys) { L "-- table-rows: $k=$($counts[$k])" }
    L "-- dump-complete"
}
finally { $w.Close() }

$total = ($counts.Values | Measure-Object -Sum).Sum
$sizeMb = [Math]::Round((Get-Item -LiteralPath $OutputFile).Length / 1MB, 1)
Write-Host ("Dumped {0} tables, {1} rows, {2} indexes/constraints, {3} foreign keys, {4} views/procedures/functions/triggers in {5}s." -f `
    $tables.Count, $total, (@($idx.Rows | Group-Object { "$($_.S)|$($_.T)|$($_.I)" }).Count + $checks.Rows.Count), $meta.Fks.Count, ($modules.Rows.Count - $warnings.Count), [int]((Get-Date) - $started).TotalSeconds)
if ($warnings.Count) { Write-Warning "Skipped $($warnings.Count) object(s) whose definition this login can't read: $($warnings -join ', ')" }
Write-Host "Dump saved: $OutputFile ($sizeMb MB)" -ForegroundColor Green
if ($Zip) {
    Compress-Archive -LiteralPath $OutputFile -DestinationPath "$OutputFile.zip" -Force
    Write-Host "Zipped    : $OutputFile.zip ($([Math]::Round((Get-Item -LiteralPath "$OutputFile.zip").Length / 1MB, 1)) MB)"
}
return $OutputFile
