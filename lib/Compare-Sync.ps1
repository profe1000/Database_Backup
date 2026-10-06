# Compare two databases from connections.txt and sync them. Started by "Compare and Sync.bat".
#
#   1. Pick database A and B.
#   2. Compares tables, columns and every row (by primary key + row checksum).
#   3. Offers: Add missing rows / Delete extra rows / Copy A to B / Copy B to A.
#      Missing tables/columns on the side being changed are built from the other
#      database, or from the schemaFile set in connections.txt (.sql or .prisma).
#   4. Offers a backup of the database being changed, shows the exact plan, asks you
#      to type YES, applies everything in one transaction (all or nothing), then re-checks.
param([string]$ConfigPath)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common.ps1")
$host.UI.RawUI.WindowTitle = "Compare and Sync Databases"

# Table/column metadata helpers (Get-DbMeta, Get-CreateTableSql, ...) live in Common.ps1.

# ================================================================ data comparison

function Get-KeyExpr($t) {
    $parts = foreach ($k in $t.Pk) {
        if ($DateTypes -contains $t.Col[$k].Type) { "CONVERT(nvarchar(100), $(QN $k), 126)" } else { "CONVERT(nvarchar(100), $(QN $k))" }
    }
    return (@($parts) -join " + N'|' + ")
}

function Get-KeyHashes([string]$cs, [string]$sql) {
    $d = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)
    $c = New-Object System.Data.SqlClient.SqlConnection $cs
    $c.Open()
    try {
        $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 600
        $r = $cmd.ExecuteReader()
        while ($r.Read()) { $d[$r.GetString(0)] = $r.GetInt32(1) }
        $r.Close()
    } finally { $c.Close() }
    return , $d
}

# Compares one table. "Src" = the side rows come from, "Tgt" = the side being compared/changed.
function Compare-Table($src, $tgt, [string]$full) {
    $res = [pscustomobject]@{ Table = $full; SrcRows = $null; TgtRows = $null; OnlySrc = @(); OnlyTgt = @(); Changed = @(); Status = ""; Cols = @(); KeyExpr = $null }
    $s = $src.Meta.Tables[$full]; $t = $tgt.Meta.Tables[$full]
    if ($s) { $res.SrcRows = $s.Rows }
    if ($t) { $res.TgtRows = $t.Rows }
    if (-not $s) { $res.Status = "MissingSrc"; return $res }
    if (-not $t) { $res.Status = "MissingTgt"; return $res }
    if ($s.Pk.Count -eq 0 -or $t.Pk.Count -eq 0) { $res.Status = "Skipped: no primary key"; return $res }
    if (($s.Pk -join ',').ToLower() -ne ($t.Pk -join ',').ToLower()) { $res.Status = "Skipped: primary keys differ"; return $res }

    $common = @($s.Columns | Where-Object {
        $tc = $t.Col[$_.Name]
        $tc -and -not $_.Computed -and -not $tc.Computed -and $_.Type -ne 'timestamp' -and $tc.Type -ne 'timestamp'
    })
    $res.Cols = @($common | ForEach-Object { $t.Col[$_.Name].Name })   # target spelling
    $hashCols = @($common | Where-Object { $NonComparable -notcontains $_.Type -and $NonComparable -notcontains $t.Col[$_.Name].Type } | ForEach-Object { $_.Name })
    if ($hashCols.Count -eq 0) { $hashCols = $s.Pk }
    $res.KeyExpr = Get-KeyExpr $s
    $select = "SELECT " + $res.KeyExpr + " AS K, BINARY_CHECKSUM(" + (($hashCols | ForEach-Object { QN $_ }) -join ", ") + ") AS H FROM "
    $hs = Get-KeyHashes $src.Cs ($select + (Q $s))
    $ht = Get-KeyHashes $tgt.Cs ($select + (Q $t))

    $onlyS = New-Object System.Collections.Generic.List[string]
    $onlyT = New-Object System.Collections.Generic.List[string]
    $chg = New-Object System.Collections.Generic.List[string]
    $h = 0
    foreach ($k in $hs.Keys) {
        if ($ht.TryGetValue($k, [ref]$h)) { if ($h -ne $hs[$k]) { $chg.Add($k) } } else { $onlyS.Add($k) }
    }
    foreach ($k in $ht.Keys) { if (-not $hs.ContainsKey($k)) { $onlyT.Add($k) } }
    $res.SrcRows = $hs.Count; $res.TgtRows = $ht.Count
    $res.OnlySrc = $onlyS; $res.OnlyTgt = $onlyT; $res.Changed = $chg
    $res.Status = if ($onlyS.Count + $onlyT.Count + $chg.Count -eq 0) { "Same" } else { "Different" }
    return $res
}

function Get-SchemaDiff($a, $b) {
    $out = @()
    foreach ($full in ($a.Meta.Tables.Keys | Sort-Object)) {
        $ta = $a.Meta.Tables[$full]; $tb = $b.Meta.Tables[$full]
        if (-not $tb) { continue }
        foreach ($c in $ta.Columns) {
            $cb = $tb.Col[$c.Name]
            if (-not $cb) { $out += [pscustomobject]@{ Table = $full; Column = $c.Name; Issue = "missing in B" }; continue }
            $da = (Get-TypeSql $c) + $(if ($c.Nullable) { " NULL" } else { " NOT NULL" })
            $db = (Get-TypeSql $cb) + $(if ($cb.Nullable) { " NULL" } else { " NOT NULL" })
            if ($da -ne $db) { $out += [pscustomobject]@{ Table = $full; Column = $c.Name; Issue = "type differs: A=$da, B=$db" } }
        }
        foreach ($c in $tb.Columns) { if (-not $ta.Col[$c.Name]) { $out += [pscustomobject]@{ Table = $full; Column = $c.Name; Issue = "missing in A" } } }
    }
    return , $out
}

function Invoke-Compare($a, $b) {
    $all = @(@($a.Meta.Tables.Keys) + @($b.Meta.Tables.Keys) | Sort-Object -Unique)
    $results = @(); $i = 0
    foreach ($full in $all) {
        $i++
        Write-Progress -Activity "Comparing $($a.Name) with $($b.Name)" -Status "$full ($i of $($all.Count))" -PercentComplete ($i * 100 / $all.Count)
        if ($a.Meta.Engine -eq "pg") { $results += Compare-PgTable $a $b $full } else { $results += Compare-Table $a $b $full }
    }
    Write-Progress -Activity "Comparing" -Completed
    return , $results
}

function Show-CompareReport($a, $b, $results, $schemaDiff) {
    $rows = foreach ($r in $results) {
        $status = switch -regex ($r.Status) { '^MissingTgt$' { "Only in A" } '^MissingSrc$' { "Only in B" } default { $r.Status } }
        [pscustomobject]@{
            Table = $r.Table; "A rows" = $r.SrcRows; "B rows" = $r.TgtRows
            "Only in A" = $(if ($r.Status -in 'Same', 'Different') { $r.OnlySrc.Count } else { "" })
            "Only in B" = $(if ($r.Status -in 'Same', 'Different') { $r.OnlyTgt.Count } else { "" })
            "Changed" = $(if ($r.Status -in 'Same', 'Different') { $r.Changed.Count } else { "" })
            Status = $status
        }
    }
    $rows = @($rows)
    $diff = @($rows | Where-Object { $_.Status -ne "Same" })
    Write-Step "Result: A = $($a.Name)   B = $($b.Name)"
    if ($diff.Count) { $diff | Format-Table -AutoSize | Out-String -Width 220 | Write-Host }
    Write-Host ("  {0} of {1} tables are identical." -f @($rows | Where-Object { $_.Status -eq "Same" }).Count, $rows.Count) -ForegroundColor $(if ($diff.Count) { "Yellow" } else { "Green" })
    if ($schemaDiff.Count) {
        Write-Host ""
        Write-Host "Column differences:" -ForegroundColor Yellow
        $schemaDiff | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    }
    return , $rows
}

function Save-CompareReport($cfg, $a, $b, $rows, $results, $schemaDiff) {
    $dir = Join-Path $cfg.outputFolder "Compare-Reports"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $base = Join-Path $dir ("{0}_vs_{1}_{2}" -f (Get-SafeName $a.Name), (Get-SafeName $b.Name), (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    $rows | Export-Csv "$base.csv" -NoTypeInformation
    $details = foreach ($r in $results) {
        foreach ($k in $r.OnlySrc) { [pscustomobject]@{ Table = $r.Table; Key = $k; Difference = "Only in A" } }
        foreach ($k in $r.OnlyTgt) { [pscustomobject]@{ Table = $r.Table; Key = $k; Difference = "Only in B" } }
        foreach ($k in $r.Changed) { [pscustomobject]@{ Table = $r.Table; Key = $k; Difference = "Changed" } }
    }
    if ($details) { $details | Export-Csv "$base-rows.csv" -NoTypeInformation }
    if ($schemaDiff.Count) { $schemaDiff | Export-Csv "$base-columns.csv" -NoTypeInformation }
    Write-Host "  Report saved: $base.csv" -ForegroundColor DarkGray
}

# ================================================================ schema building

function Get-MissingSchema($src, $tgt) {
    $items = @()
    foreach ($full in ($src.Meta.Tables.Keys | Sort-Object)) {
        $s = $src.Meta.Tables[$full]; $t = $tgt.Meta.Tables[$full]
        if (-not $t) { $items += [pscustomobject]@{ Kind = "Table"; Table = $full; Column = $null }; continue }
        foreach ($c in $s.Columns) { if (-not $t.Col[$c.Name]) { $items += [pscustomobject]@{ Kind = "Column"; Table = $full; Column = $c.Name } } }
    }
    return , $items
}

function Get-DdlFromDatabase($items, $src, $tgt) {
    $stmts = New-Object System.Collections.ArrayList
    $newTables = @($items | Where-Object Kind -eq "Table" | ForEach-Object Table)
    $schemasDone = @{}
    foreach ($full in $newTables) {
        $s = $src.Meta.Tables[$full]
        if (-not $tgt.Meta.Schemas[$s.Schema] -and -not $schemasDone[$s.Schema]) {
            [void]$stmts.Add("EXEC(N'CREATE SCHEMA " + (QN $s.Schema).Replace("'", "''") + "');"); $schemasDone[$s.Schema] = $true
        }
        [void]$stmts.Add((Get-CreateTableSql $s))
    }
    foreach ($it in ($items | Where-Object Kind -eq "Column")) {
        $s = $src.Meta.Tables[$it.Table]; $t = $tgt.Meta.Tables[$it.Table]; $c = $s.Col[$it.Column]
        $needTmp = (-not $c.Nullable) -and (-not $c.Default) -and (-not $c.Identity) -and (-not $c.Computed) -and $t.Rows -gt 0
        $tmp = "DF_synctmp_" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        [void]$stmts.Add("ALTER TABLE " + (Q $t) + " ADD " + (Get-ColumnSql $c $needTmp $tmp) + ";")
        if ($needTmp) { [void]$stmts.Add("ALTER TABLE " + (Q $t) + " DROP CONSTRAINT " + (QN $tmp) + ";") }
    }
    foreach ($fk in $src.Meta.Fks) {
        if ($newTables -notcontains $fk.Child) { continue }
        if (-not ($tgt.Meta.Tables[$fk.Parent] -or $newTables -contains $fk.Parent)) { continue }
        [void]$stmts.Add((Get-FkSql $fk $src.Meta))
    }
    return , $stmts
}

function Get-SchemaFileSql([string]$path) {
    if (-not $path) { throw "No schemaFile is set in connections.txt." }
    if (-not (Test-Path -LiteralPath $path)) { throw "Schema file not found: $path" }
    if ($path -notmatch '\.prisma$') { return [IO.File]::ReadAllText($path) }

    $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $npx) { throw "A .prisma schema needs Node.js to convert it to SQL. Install Node.js (nodejs.org), or save the schema as a .sql file and point schemaFile at that." }
    if ([IO.File]::ReadAllText($path) -notmatch 'provider\s*=\s*"(sqlserver|postgresql)"') { Write-Warning "The Prisma datasource provider isn't ""sqlserver"" or ""postgresql"" - the generated SQL may not work." }
    # Prisma 7 prints nothing for this command, so use Prisma 6 (downloaded by npx on first use).
    Write-Host "  Converting the Prisma schema to SQL (npx prisma@6 migrate diff - first run downloads Prisma)..."
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    Push-Location (Split-Path -Parent $path)
    try { $out = & $npx.Source --yes prisma@6 migrate diff --from-empty --to-schema-datamodel $path --script 2>$null }
    finally { Pop-Location; $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0 -or -not ($out -match 'CREATE TABLE')) {
        throw "Prisma could not convert $path to SQL. Check that the datasource block has provider = ""sqlserver"" and a url line, e.g. url = env(""DATABASE_URL"")."
    }
    return (@($out) -join "`n")
}

function Find-CreateTable([string]$sql, [string]$schema, [string]$name) {
    $n = [regex]::Escape($name); $s = [regex]::Escape($schema)
    $rx = "CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:(?:\[$s\]|""$s""|$s)\s*\.\s*)?(?:\[$n\]|""$n""|$n)\s*\("
    $m = [regex]::Match($sql, $rx, 'IgnoreCase')
    if (-not $m.Success) { return $null }
    $open = $m.Index + $m.Length - 1
    $depth = 0; $inStr = $false
    for ($i = $open; $i -lt $sql.Length; $i++) {
        $ch = $sql[$i]
        if ($ch -eq "'") { $inStr = -not $inStr; continue }
        if ($inStr) { continue }
        if ($ch -eq '(') { $depth++ }
        elseif ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { return @{ Sql = $sql.Substring($m.Index, $i - $m.Index + 1) + ";"; Body = $sql.Substring($open + 1, $i - $open - 1) } }
        }
    }
    return $null
}

function Split-TopLevel([string]$body) {
    $items = @(); $depth = 0; $inStr = $false; $start = 0
    for ($i = 0; $i -lt $body.Length; $i++) {
        $ch = $body[$i]
        if ($ch -eq "'") { $inStr = -not $inStr }
        elseif (-not $inStr) {
            if ($ch -eq '(') { $depth++ } elseif ($ch -eq ')') { $depth-- }
            elseif ($ch -eq ',' -and $depth -eq 0) { $items += $body.Substring($start, $i - $start).Trim(); $start = $i + 1 }
        }
    }
    $items += $body.Substring($start).Trim()
    return , $items
}

function Get-DdlFromFile($items, $tgt, [string]$fileSql) {
    $stmts = New-Object System.Collections.ArrayList
    $notFound = @()
    foreach ($it in $items) {
        $schema, $name = $it.Table.Split('.', 2)
        $block = Find-CreateTable $fileSql $schema $name
        if (-not $block) { $notFound += $it; continue }
        if ($it.Kind -eq "Table") { [void]$stmts.Add($block.Sql); continue }
        $c = [regex]::Escape($it.Column)
        $parts = Split-TopLevel $block.Body
        $def = $parts | Where-Object { $_ -match "^(\[$c\]|""$c""|$c)\s" } | Select-Object -First 1
        if (-not $def) { $notFound += $it; continue }
        if ($tgt.Meta.Engine -eq "pg") { [void]$stmts.Add("ALTER TABLE " + (PgQ $tgt.Meta.Tables[$it.Table]) + " ADD COLUMN " + $def + ";") }
        else { [void]$stmts.Add("ALTER TABLE " + (Q $tgt.Meta.Tables[$it.Table]) + " ADD " + $def + ";") }
    }
    return @{ Stmts = $stmts; NotFound = $notFound }
}

# ================================================================ applying changes

function Invoke-Tx($conn, $tx, [string]$sql) {
    $cmd = $conn.CreateCommand(); $cmd.Transaction = $tx; $cmd.CommandText = $sql; $cmd.CommandTimeout = 0
    return $cmd.ExecuteNonQuery()
}

function Get-InList($keys, [int]$start, [int]$count) {
    return (($keys.GetRange($start, $count) | ForEach-Object { SqlStr $_ }) -join ",")
}

# Reads the given rows (by key) from the source table, with columns named as on the target.
function Get-SourceRows($src, $s, $cols, [string]$keyExpr, $keys) {
    $sel = "SELECT " + $keyExpr + " AS [__K], " + (($cols | ForEach-Object { (QN $s.Col[$_].Name) + " AS " + (QN $_) }) -join ", ") + " FROM " + (Q $s)
    if ($keys.Count -gt 2000) {
        $all = Invoke-Query $src.Cs $sel 600
        $want = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $keys) { [void]$want.Add($k) }
        $dt = $all.Clone()
        foreach ($r in $all.Rows) { if ($want.Contains([string]$r["__K"])) { $dt.ImportRow($r) } }
        return , $dt
    }
    $dt = $null
    for ($i = 0; $i -lt $keys.Count; $i += 500) {
        $n = [Math]::Min(500, $keys.Count - $i)
        $part = Invoke-Query $src.Cs ($sel + " WHERE " + $keyExpr + " IN (" + (Get-InList $keys $i $n) + ")") 600
        if ($null -eq $dt) { $dt = $part } else { $dt.Merge($part) }
    }
    return , $dt
}

function Write-Bulk($conn, $tx, [string]$dest, $dt, $cols, [bool]$checkConstraints) {
    $o = [System.Data.SqlClient.SqlBulkCopyOptions]::KeepIdentity -bor [System.Data.SqlClient.SqlBulkCopyOptions]::KeepNulls
    if ($checkConstraints) { $o = $o -bor [System.Data.SqlClient.SqlBulkCopyOptions]::CheckConstraints }
    $bc = [System.Data.SqlClient.SqlBulkCopy]::new($conn, $o, $tx)
    try {
        $bc.DestinationTableName = $dest; $bc.BulkCopyTimeout = 0; $bc.BatchSize = 5000
        foreach ($c in $cols) { [void]$bc.ColumnMappings.Add([string]$c, [string]$c) }
        $bc.WriteToServer($dt)
    } finally { $bc.Close() }
}

function Invoke-SyncJob($cfg, $src, $tgt, [bool]$doIns, [bool]$doUpd, [bool]$doDel) {
    if ($tgt.Meta.Engine -eq "pg") { Invoke-PgSyncJob $cfg $src $tgt $doIns $doUpd $doDel; return }
    $what = @(); if ($doIns) { $what += "add" }; if ($doUpd) { $what += "update" }; if ($doDel) { $what += "delete" }
    Write-Step ("Changing {0}  (using {1} as the source; will {2} rows)" -f $tgt.Name, $src.Name, ($what -join "/"))

    # ---- 1. missing tables / columns on the target
    $ddl = @()
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
            if ($hasFile) { Write-Host "  2. Build them from the schema file: $($cfg.schemaFile)" }
            else { Write-Host "  2. Build them from a schema file  (not available - set schemaFile in connections.txt)" -ForegroundColor DarkGray }
            Write-Host "  3. Don't create them - leave those tables/columns out of the sync"
            $ans = Ask ">"
            if ($ans -eq "1") { $ddl = Get-DdlFromDatabase $items $src $tgt }
            elseif ($ans -eq "2" -and $hasFile) {
                $r = Get-DdlFromFile $items $tgt (Get-SchemaFileSql $cfg.schemaFile)
                $ddl = @($r.Stmts)
                foreach ($nf in $r.NotFound) { Write-Host "  Not in schema file, skipped: $($nf.Table)$(if ($nf.Column) { '.' + $nf.Column })" -ForegroundColor Yellow }
            }
            else { Write-Host "  Skipping missing tables/columns." }
        }
    }

    # ---- 2. backup of the target
    Write-Host ""
    Write-Host "Back up $($tgt.Name) before changing it?" -ForegroundColor Yellow
    Write-Host "  1. Yes, as .sql  (recommended - works with any login)"
    Write-Host "  2. Yes, as .bak"
    Write-Host "  3. No"
    $fmt = Ask ">"
    if ($fmt -eq "1" -or $fmt -eq "2") {
        try { $bak = Invoke-Backup $cfg $tgt.Conn $(if ($fmt -eq "1") { "sql" } else { "bak" }); Write-Host "  Backup: $($bak.FullName)" -ForegroundColor Green }
        catch {
            Write-Host "  Backup failed: $($_.Exception.Message)" -ForegroundColor Red
            if (-not (Confirm-Yes "Continue WITHOUT a backup?")) { Write-Host "  Cancelled - nothing was changed."; return }
        }
    }

    # ---- 3. create the missing structure
    if ($ddl.Count) {
        Write-Host ""
        Write-Host "Structure changes for $($tgt.Name):" -ForegroundColor Yellow
        foreach ($s in $ddl) { Write-Host ("  " + ($s -split "`r?`n")[0]) }
        if (-not (Confirm-Yes "Apply these $($ddl.Count) structure change(s)?")) { Write-Host "  Cancelled - nothing was changed."; return }
        $conn = New-Object System.Data.SqlClient.SqlConnection $tgt.Cs; $conn.Open(); $tx = $conn.BeginTransaction()
        try { foreach ($s in $ddl) { [void](Invoke-Tx $conn $tx $s) }; $tx.Commit(); Write-Host "  Structure updated." -ForegroundColor Green }
        catch { $tx.Rollback(); throw "Structure change failed, nothing was changed: $($_.Exception.Message)" }
        finally { $conn.Close() }
        $tgt.Meta = Get-DbMeta $tgt.Cs
    }

    # ---- 4. work out the row changes (fresh, right now)
    Write-Host ""
    Write-Host "Working out the row changes..."
    $plan = @{}
    $tables = @($src.Meta.Tables.Keys | Where-Object { $tgt.Meta.Tables.ContainsKey($_) } | Sort-Object)
    $i = 0
    foreach ($full in $tables) {
        $i++
        Write-Progress -Activity "Comparing" -Status "$full ($i of $($tables.Count))" -PercentComplete ($i * 100 / $tables.Count)
        $d = Compare-Table $src $tgt $full
        if ($d.Status -ne "Different") { if ($d.Status -like "Skipped*") { Write-Host "  $full - $($d.Status)" -ForegroundColor DarkGray }; continue }
        $none = New-Object System.Collections.Generic.List[string]
        $p = [pscustomobject]@{ Table = $full; Ins = $none; Upd = $none; Del = $none; Cols = $d.Cols; KeyExpr = $d.KeyExpr; Note = "" }
        if ($doIns) { $p.Ins = $d.OnlySrc }
        if ($doUpd) { $p.Upd = $d.Changed }
        if ($doDel) { $p.Del = $d.OnlyTgt }
        if ($p.Ins.Count) {
            $s = $src.Meta.Tables[$full]
            $blockers = @($tgt.Meta.Tables[$full].Columns | Where-Object { -not $s.Col[$_.Name] -and -not $_.Nullable -and -not $_.Default -and -not $_.Identity -and -not $_.Computed -and $_.Type -ne 'timestamp' })
            if ($blockers.Count) { $p.Note = "can't add rows: required column(s) only in $($tgt.Name): " + (($blockers | ForEach-Object Name) -join ", "); $p.Ins = $none }
        }
        if ($p.Ins.Count + $p.Upd.Count + $p.Del.Count -gt 0 -or $p.Note) { $plan[$full] = $p }
    }
    Write-Progress -Activity "Comparing" -Completed

    $work = @($plan.Values | Where-Object { $_.Ins.Count + $_.Upd.Count + $_.Del.Count -gt 0 })
    foreach ($p in ($plan.Values | Where-Object Note)) { Write-Host "  $($p.Table): $($p.Note)" -ForegroundColor Yellow }
    if ($work.Count -eq 0) { Write-Host "  Nothing to change - $($tgt.Name) already matches for the chosen action." -ForegroundColor Green; return }

    Write-Host ""
    Write-Host "Planned changes to $($tgt.Name):" -ForegroundColor Yellow
    $work | Sort-Object Table | ForEach-Object { [pscustomobject]@{ Table = $_.Table; "Add rows" = $_.Ins.Count; "Update rows" = $_.Upd.Count; "Delete rows" = $_.Del.Count } } |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    $tot = @{ I = ($work | ForEach-Object { $_.Ins.Count } | Measure-Object -Sum).Sum; U = ($work | ForEach-Object { $_.Upd.Count } | Measure-Object -Sum).Sum; D = ($work | ForEach-Object { $_.Del.Count } | Measure-Object -Sum).Sum }
    Write-Host ("  Total: add {0}, update {1}, delete {2} rows in {3} table(s)." -f $tot.I, $tot.U, $tot.D, $work.Count)
    Write-Host ""
    if ((Ask "Type YES to apply these changes to $($tgt.Name)") -cne "YES") { Write-Host "  Cancelled - no rows were changed."; return }

    # ---- 5. apply, all in one transaction
    $order = Get-TableOrder $tgt.Meta @($work | ForEach-Object Table)
    $conn = New-Object System.Data.SqlClient.SqlConnection $tgt.Cs; $conn.Open(); $tx = $conn.BeginTransaction()
    try {
        foreach ($full in $order) {
            $p = $plan[$full]; $s = $src.Meta.Tables[$full]; $t = $tgt.Meta.Tables[$full]
            if ($p.Ins.Count) {
                $dt = Get-SourceRows $src $s $p.Cols $p.KeyExpr $p.Ins
                Write-Bulk $conn $tx (Q $t) $dt $p.Cols $true
                Write-Host ("  {0,-34} added   {1}" -f $full, $dt.Rows.Count)
                if ($dt.Rows.Count -ne $p.Ins.Count) { Write-Host "    ($($p.Ins.Count - $dt.Rows.Count) row(s) disappeared from $($src.Name) meanwhile)" -ForegroundColor Yellow }
            }
            if ($p.Upd.Count) {
                $setCols = @($p.Cols | Where-Object { $t.Pk -notcontains $_ -and -not $t.Col[$_].Identity })
                if ($setCols.Count) {
                    $dt = Get-SourceRows $src $s $p.Cols $p.KeyExpr $p.Upd
                    [void](Invoke-Tx $conn $tx ("SELECT TOP 0 " + (($p.Cols | ForEach-Object { QN $_ }) -join ", ") + " INTO #sync_stage FROM " + (Q $t) + ";"))
                    Write-Bulk $conn $tx "#sync_stage" $dt $p.Cols $false
                    $set = ($setCols | ForEach-Object { "t." + (QN $_) + " = u." + (QN $_) }) -join ", "
                    $on = ($t.Pk | ForEach-Object { "t." + (QN $_) + " = u." + (QN $_) }) -join " AND "
                    $n = Invoke-Tx $conn $tx ("UPDATE t SET $set FROM " + (Q $t) + " t JOIN #sync_stage u ON $on; ")
                    [void](Invoke-Tx $conn $tx "DROP TABLE #sync_stage;")
                    Write-Host ("  {0,-34} updated {1}" -f $full, $n)
                }
            }
        }
        for ($j = $order.Count - 1; $j -ge 0; $j--) {
            $full = $order[$j]; $p = $plan[$full]; $t = $tgt.Meta.Tables[$full]
            if (-not $p.Del.Count) { continue }
            $n = 0
            for ($i = 0; $i -lt $p.Del.Count; $i += 500) {
                $c = [Math]::Min(500, $p.Del.Count - $i)
                $n += Invoke-Tx $conn $tx ("DELETE FROM " + (Q $t) + " WHERE " + $p.KeyExpr + " IN (" + (Get-InList $p.Del $i $c) + ");")
            }
            Write-Host ("  {0,-34} deleted {1}" -f $full, $n)
        }
        $tx.Commit()
        Write-Host "  All changes saved to $($tgt.Name)." -ForegroundColor Green
    }
    catch {
        $tx.Rollback()
        throw "Sync failed and was rolled back - $($tgt.Name) is unchanged. Reason: $($_.Exception.Message)"
    }
    finally { $conn.Close() }

    # ---- 6. re-check
    Write-Host "Re-checking..."
    $tgt.Meta = Get-DbMeta $tgt.Cs; $src.Meta = Get-DbMeta $src.Cs
    $left = 0
    foreach ($p in $work) {
        $d = Compare-Table $src $tgt $p.Table
        $n = 0; if ($doIns) { $n += $d.OnlySrc.Count }; if ($doUpd) { $n += $d.Changed.Count }; if ($doDel) { $n += $d.OnlyTgt.Count }
        if ($n) { $left += $n; Write-Host "  $($p.Table): $n difference(s) remain" -ForegroundColor Yellow }
    }
    if ($left -eq 0) { Write-Host "  Verified: done." -ForegroundColor Green }
}

# ================================================================ main menu

function New-Side([string]$label, $conn) {
    Write-Host "  Connecting to $label ($($conn.Name))..."
    $err = Test-DbConnection $conn.ConnectionString
    if ($err) { throw "Can't connect to $($conn.Name): $err" }
    if ((Get-DbEngine $conn.ConnectionString) -eq "pg") {
        return [pscustomobject]@{ Label = $label; Name = $conn.Name; Cs = $conn.ConnectionString; Conn = $conn; Pg = (Get-PgConn $conn.ConnectionString); Meta = (Get-PgMeta $conn.ConnectionString) }
    }
    return [pscustomobject]@{ Label = $label; Name = $conn.Name; Cs = $conn.ConnectionString; Conn = $conn; Pg = $null; Meta = (Get-DbMeta $conn.ConnectionString) }
}

try {
    do {
        Clear-Host
        Write-Banner "COMPARE AND SYNC DATABASES  (SQL Server / PostgreSQL)"
        $engine = Select-Engine
        if (-not $engine) { break }
        $ca = Select-Connections "Choose $(Get-EngineLabel $engine) database A:" -Single -Engine $engine
        if (-not $ca) { break }
        $cb = Select-Connections "Choose database B (to compare with A = $($ca.Name)):" -Single -Engine $engine
        if (-not $cb) { break }
        if ($ca.ConnectionString -eq $cb.ConnectionString) { Write-Host "A and B are the same database." -ForegroundColor Red; continue }
        $cfg = Read-Config

        Write-Step "Reading both databases"
        $A = New-Side "A" $ca
        $B = New-Side "B" $cb

        $results = Invoke-Compare $A $B
        $schemaDiff = Get-SchemaDiff $A $B
        $rows = Show-CompareReport $A $B $results $schemaDiff
        Save-CompareReport $cfg $A $B $rows $results $schemaDiff

        if (@($rows | Where-Object Status -ne "Same").Count -eq 0 -and $schemaDiff.Count -eq 0) {
            Write-Host ""; Write-Host "The databases are identical. Nothing to sync." -ForegroundColor Green
            continue
        }

        Write-Host ""
        Write-Host "How do you want to sync?" -ForegroundColor Yellow
        Write-Host "  1. Add missing rows    - copy rows that exist on one side only (nothing is changed or deleted)"
        Write-Host "  2. Delete extra rows   - delete rows that exist on one side only"
        Write-Host "  3. Copy A to B         - make B exactly like A ($($A.Name) -> $($B.Name))"
        Write-Host "  4. Copy B to A         - make A exactly like B ($($B.Name) -> $($A.Name))"
        Write-Host "  5. Nothing"
        $choice = Ask ">"
        try { switch ($choice) {
            "1" {
                Write-Host "Add missing rows into:"
                Write-Host "  1. B ($($B.Name)) - rows that are only in A"
                Write-Host "  2. A ($($A.Name)) - rows that are only in B"
                Write-Host "  3. Both"
                $d = Ask ">"
                if ($d -in "1", "3") { Invoke-SyncJob $cfg $A $B $true $false $false }
                if ($d -in "2", "3") { Invoke-SyncJob $cfg $B $A $true $false $false }
            }
            "2" {
                Write-Host "Delete extra rows from:"
                Write-Host "  1. B ($($B.Name)) - rows that are not in A"
                Write-Host "  2. A ($($A.Name)) - rows that are not in B"
                $d = Ask ">"
                if ($d -eq "1") { Invoke-SyncJob $cfg $A $B $false $false $true }
                if ($d -eq "2") { Invoke-SyncJob $cfg $B $A $false $false $true }
            }
            "3" { Invoke-SyncJob $cfg $A $B $true $true $true }
            "4" { Invoke-SyncJob $cfg $B $A $true $true $true }
        } }
        catch {
            if ($_.Exception.Message -eq "No more input - stopping.") { throw }
            Write-Host ""
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host ""
    } while (Confirm-Yes "Compare again / another pair?")
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to close" | Out-Null
}
