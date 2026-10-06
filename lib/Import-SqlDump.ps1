<#
.SYNOPSIS
    Runs a .sql script (e.g. from Export-SqlDump.ps1, SSMS "Generate Scripts", sqlcmd scripts) against a database.

.DESCRIPTION
    Splits the script on GO lines and runs each batch on one connection, so SET IDENTITY_INSERT
    and other session settings carry over like in SSMS. "USE [db]" batches are skipped so the
    script always goes into the database in -ConnectionString.
    Views/functions/procedures that fail because they depend on something created later are retried
    at the end. If the dump lists row counts ("-- table-rows:" lines), they are checked afterwards.

.EXAMPLE
    .\Import-SqlDump.ps1 -ConnectionString "Data Source=localhost\SQLEXPRESS;Initial Catalog=NewDb;Integrated Security=True;TrustServerCertificate=True" -File .\MyDb_2026-10-05_15-00-00.sql
#>
param(
    [Parameter(Mandatory = $true)][string]$ConnectionString,
    [Parameter(Mandatory = $true)][string]$File
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "Common.ps1")

$fi = Get-Item -LiteralPath $File
$csb = Get-Builder $ConnectionString
Write-Host "Running $($fi.Name) ($([Math]::Round($fi.Length / 1MB, 1)) MB) into [$($csb.InitialCatalog)] on $($csb.DataSource)..."
$started = Get-Date
$goRx = New-Object Text.RegularExpressions.Regex('^\s*GO\s*(?<n>\d+)?\s*(--.*)?$', 'IgnoreCase')
$moduleRx = New-Object Text.RegularExpressions.Regex('^\s*(--[^\n]*\n\s*)*CREATE\s+(OR\s+ALTER\s+)?(VIEW|FUNCTION|PROC|PROCEDURE|TRIGGER)\b', 'IgnoreCase')
$expected = [ordered]@{}
$complete = $false
$deferred = New-Object System.Collections.ArrayList
$batchNo = 0; $skipped = 0

$conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
$conn.Open()
$reader = New-Object IO.StreamReader($fi.FullName, [Text.Encoding]::UTF8, $true)
try {
    function Invoke-Batch([string]$text, [int]$times = 1) {
        if (-not $text.Trim()) { return }
        $script:batchNo++
        if ($text -match '^\s*USE\s+\S+\s*;?\s*$') { $script:skipped++; Write-Host "  Skipped: $($text.Trim())" -ForegroundColor DarkGray; return }
        for ($k = 0; $k -lt $times; $k++) {
            $cmd = $conn.CreateCommand(); $cmd.CommandText = $text; $cmd.CommandTimeout = 0
            try { [void]$cmd.ExecuteNonQuery() }
            catch {
                if ($moduleRx.IsMatch($text)) { [void]$deferred.Add($text); return }
                $snippet = $text.Trim(); if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) + "..." }
                $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                throw "Batch $($script:batchNo) failed: $msg`n--- batch starts with:`n$snippet"
            }
        }
    }

    $sb = New-Object Text.StringBuilder
    $total = [double][Math]::Max(1, $fi.Length)
    while ($null -ne ($line = $reader.ReadLine())) {
        if ($line.StartsWith("-- table-rows: ")) {
            $kv = $line.Substring(15); $eq = $kv.LastIndexOf("=")
            if ($eq -gt 0) { $expected[$kv.Substring(0, $eq)] = [long]$kv.Substring($eq + 1) }
        }
        elseif ($line -eq "-- dump-complete") { $complete = $true }
        $m = $goRx.Match($line)
        if ($m.Success) {
            $times = if ($m.Groups['n'].Success) { [int]$m.Groups['n'].Value } else { 1 }
            Invoke-Batch $sb.ToString() $times
            [void]$sb.Clear()
            if ($batchNo % 25 -eq 0) { Write-Progress -Activity "Restoring $($fi.Name)" -Status "batch $batchNo" -PercentComplete ([Math]::Min(100, $reader.BaseStream.Position * 100 / $total)) }
            continue
        }
        [void]$sb.AppendLine($line)
    }
    Invoke-Batch $sb.ToString()
    Write-Progress -Activity "Restoring" -Completed

    # Retry objects that depended on something created later in the script.
    for ($pass = 1; $pass -le 3 -and $deferred.Count; $pass++) {
        $todo = @($deferred); $deferred.Clear()
        foreach ($text in $todo) { $cmd = $conn.CreateCommand(); $cmd.CommandText = $text; try { [void]$cmd.ExecuteNonQuery() } catch { [void]$deferred.Add($text) } }
    }
    if ($deferred.Count) {
        foreach ($text in $deferred) {
            $cmd = $conn.CreateCommand(); $cmd.CommandText = $text
            try { [void]$cmd.ExecuteNonQuery() } catch { Write-Warning ("Could not create: " + (($text.Trim() -split "`n")[0]) + " - " + $_.Exception.InnerException.Message) }
        }
    }
}
finally { $reader.Close(); $conn.Close() }

Write-Host ("  Ran {0} batches in {1}s." -f ($batchNo - $skipped), [int]((Get-Date) - $started).TotalSeconds)
$ok = $true
if ($expected.Count) {
    $bad = @()
    foreach ($k in $expected.Keys) {
        $parts = $k.Split('.', 2)
        $n = [long](Invoke-Query $ConnectionString ("SELECT COUNT_BIG(*) AS N FROM " + (QN $parts[0]) + "." + (QN $parts[1]))).Rows[0].N
        if ($n -ne $expected[$k]) { $bad += "$k (expected $($expected[$k]), found $n)" }
    }
    if ($bad.Count) { $ok = $false; Write-Warning ("Row counts differ: " + ($bad -join "; ")) }
    else { Write-Host ("  Verified: all {0} tables have the expected row counts ({1} rows)." -f $expected.Count, ($expected.Values | Measure-Object -Sum).Sum) -ForegroundColor Green }
    if (-not $complete) { $ok = $false; Write-Warning "The dump has no end marker - the file may be incomplete." }
}
if ($deferred.Count) { $ok = $false }
return $ok
