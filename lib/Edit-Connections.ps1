# Add, change, test and remove connections, the Auto Backup list and the settings in connections.txt
# without editing the file by hand. Started by "Edit Connections.bat" (and by E / "Edit the list" in the other tools).
# Comments and layout in the file are kept. Every save first copies the previous version to
# conn\history (newest 20 kept), so a bad change can be undone with U.
param([string]$ConfigPath)

. (Join-Path $PSScriptRoot "Common.ps1")

$SamplePath = Join-Path $ConnDir "connections.sample.txt"
$HistoryDir = Join-Path $ConnDir "history"
$HistoryKeep = 20
$SettingInfo = [ordered]@{
    outputFolder   = "Where backups and reports go. A relative path is relative to conn (..\Backups = the main Backups folder)."
    schemaFile     = "Optional .sql or .prisma schema used by Compare and Sync. Leave empty for none."
    localServer    = "Local SQL Server used to make .bak files of hosted databases."
    autoBackupKeep = "Auto Backup keeps this many backups per database and format (0 = keep all)."
}

# ---------------------------------------------------------------- reading / writing the file (keeps comments)

function Get-Lines { return , [Collections.Generic.List[string]]@([IO.File]::ReadAllLines($ConfigPath)) }

# Line range of a section: Start = first line after the header, End = exclusive. "" = the settings at the top.
function Get-Section($lines, [string]$section) {
    $start = if ($section) { -1 } else { 0 }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[(.+)\]\s*$') {
            if ($start -ge 0) { return @{ Start = $start; End = $i } }
            if ($Matches[1].Trim().ToLower() -eq $section) { $start = $i + 1 }
        }
    }
    if ($start -ge 0) { return @{ Start = $start; End = $lines.Count } }
    return $null
}

function Find-Entry($lines, [string]$section, [string]$key) {
    $s = Get-Section $lines $section
    if (-not $s) { return -1 }
    for ($i = $s.Start; $i -lt $s.End; $i++) {
        $t = $lines[$i].Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        $j = $t.IndexOf("=")
        if ($j -ge 1 -and $t.Substring(0, $j).Trim() -eq $key) { return $i }
    }
    return -1
}

function Get-EntryValue($lines, [string]$section, [string]$key) {
    $i = Find-Entry $lines $section $key
    if ($i -lt 0) { return $null }
    $t = $lines[$i].Trim()
    return $t.Substring($t.IndexOf("=") + 1).Trim()
}

# Changes the line of $key, or adds it at the end of the section (creating the section if needed).
function Set-Entry($lines, [string]$section, [string]$key, [string]$value) {
    $line = if ($value) { "$key = $value" } else { "$key =" }
    $i = Find-Entry $lines $section $key
    if ($i -ge 0) { $lines[$i] = $line; return }
    $s = Get-Section $lines $section
    if (-not $s) {
        if ($lines.Count -and $lines[$lines.Count - 1].Trim()) { $lines.Add("") }
        $lines.Add("[$section]"); $lines.Add($line); return
    }
    $at = $s.End
    while ($at -gt $s.Start -and -not $lines[$at - 1].Trim()) { $at-- }
    $lines.Insert($at, $line)
}

function Remove-Entry($lines, [string]$section, [string]$key) {
    $i = Find-Entry $lines $section $key
    if ($i -ge 0) { $lines.RemoveAt($i) }
}

function Rename-Entry($lines, [string]$section, [string]$old, [string]$new) {
    $i = Find-Entry $lines $section $old
    if ($i -ge 0) { $lines[$i] = "$new = $(Get-EntryValue $lines $section $old)".TrimEnd() }
}

# Saves the lines, keeping the previous version in connections-history.
function Save-Lines($lines, [string]$what) {
    if (Test-Path -LiteralPath $ConfigPath) {
        if (-not (Test-Path -LiteralPath $HistoryDir)) { [void](New-Item -ItemType Directory -Path $HistoryDir) }
        Copy-Item -LiteralPath $ConfigPath (Join-Path $HistoryDir ("connections_{0:yyyy-MM-dd_HH-mm-ss-fff}.txt" -f (Get-Date))) -Force
        Get-ChildItem -LiteralPath $HistoryDir -Filter "connections_*.txt" | Sort-Object Name -Descending | Select-Object -Skip $HistoryKeep | Remove-Item -Force
    }
    [IO.File]::WriteAllLines($ConfigPath, [string[]]$lines)
    Write-Host "  Saved: $what" -ForegroundColor Green
}

# ---------------------------------------------------------------- input helpers

function Ask-Default([string]$prompt, $default) {
    $a = Ask $(if ("$default") { "$prompt [$default]" } else { $prompt })
    if ($a) { return $a } else { return "$default" }
}

function Ask-Secret([string]$prompt) {
    $s = Read-Host $prompt -AsSecureString
    if ($null -eq $s) { throw "No more input - stopping." }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Pause-Menu { [void](Read-Host "Press Enter to continue") }

# Returns an error message, or $null when the name can be used.
function Test-ConnName([string]$name, $cfg, [string]$except) {
    if (-not $name) { return "The name can't be empty." }
    if ($name -match '[=\[\]]' -or $name.StartsWith("#")) { return "The name can't contain = [ ] or start with #." }
    if ($name -ne $except -and @($cfg.Connections | Where-Object { $_.Name -eq $name }).Count) { return "There is already a connection called '$name'." }
    return $null
}

# ---------------------------------------------------------------- connection strings

function Read-SqlServerCs([string]$current) {
    $old = if ($current) { Get-Builder $current } else { $null }
    # The builder is a dictionary, so PowerShell needs its keywords ("Data Source") rather than property names.
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    if ($old) { $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $current }   # keeps any extra options
    $server = Ask-Default "Server (e.g. sql6033.site4now.net or localhost\SQLEXPRESS)" $(if ($old) { $old["Data Source"] })
    $db = Ask-Default "Database name" $(if ($old) { $old["Initial Catalog"] })
    if (-not $server -or -not $db) { Write-Host "Server and database are required." -ForegroundColor Red; return $null }
    $b["Data Source"] = $server
    $b["Initial Catalog"] = $db
    $wasWin = $old -and $old["Integrated Security"]
    $win = (Ask-Default "Login type: 1 = user name and password, 2 = Windows login (SQL Server on this PC/network)" $(if ($wasWin) { "2" } else { "1" })) -eq "2"
    if ($win) {
        $b["Integrated Security"] = $true
        [void]$b.Remove("User ID"); [void]$b.Remove("Password")
    }
    else {
        $b["Integrated Security"] = $false
        $b["User ID"] = Ask-Default "User name" $(if ($old -and -not $wasWin) { $old["User ID"] })
        $hasPw = $old -and $old["Password"]
        $pw = Ask-Secret $(if ($hasPw) { "Password (Enter = keep the current one)" } else { "Password" })
        if (-not $pw -and $hasPw) { $pw = $old["Password"] }
        $b["Password"] = $pw
    }
    $enc = Ask-Default "Encrypt the connection? (Y/N)" $(if ($old -and -not $old["Encrypt"]) { "N" } else { "Y" })
    $b["Encrypt"] = $enc -match '^[Yy]'
    $b["TrustServerCertificate"] = $true
    return $b.ConnectionString
}

function Read-PgCs([string]$current) {
    $old = if ($current) { Get-PgConn $current } else { $null }
    $h = Ask-Default "Host (e.g. pg1001.site4now.net or localhost)" $(if ($old) { $old.Host })
    $port = Ask-Default "Port" $(if ($old) { $old.Port } else { 5432 })
    $db = Ask-Default "Database name" $(if ($old) { $old.Database })
    $user = Ask-Default "User name" $(if ($old) { $old.User })
    $hasPw = $old -and $old.Password
    $pw = Ask-Secret $(if ($hasPw) { "Password (Enter = keep the current one)" } else { "Password" })
    if (-not $pw -and $hasPw) { $pw = $old.Password }
    if (-not $h -or -not $db) { Write-Host "Host and database are required." -ForegroundColor Red; return $null }
    if ($port -notmatch '^\d+$') { Write-Host "The port must be a number." -ForegroundColor Red; return $null }
    if ("$h$db$user$pw" -match ';') { Write-Host "Values can't contain ';' - paste the full connection string instead (option 1)." -ForegroundColor Red; return $null }
    $cs = "Host=$h;Port=$port;Database=$db;Username=$user;Password=$pw"
    if ($old -and $old.SslMode) { $cs += ";SslMode=$($old.SslMode)" }
    return $cs
}

# Asks for a connection string (pasted or built from fields). Returns $null when cancelled.
function Read-ConnectionString([string]$current) {
    $eng = if ($current) { Get-DbEngine $current } else { $null }
    Write-Host ""
    Write-Host "How do you want to enter it?" -ForegroundColor Yellow
    Write-Host "  1. Paste a connection string"
    Write-Host "  2. SQL Server - type server, database and login$(if ($eng -eq 'mssql') { '  (current values are offered)' })"
    Write-Host "  3. PostgreSQL - type host, port, database and login$(if ($eng -eq 'pg') { '  (current values are offered)' })"
    Write-Host "  Q. Cancel"
    while ($true) {
        $a = Ask ">"
        $cs = $null
        switch ($a) {
            "1" { $cs = (Ask "Paste the connection string").Trim('"') }
            "2" { $cs = Read-SqlServerCs $(if ($eng -eq "mssql") { $current }) }
            "3" { $cs = Read-PgCs $(if ($eng -eq "pg") { $current }) }
            default { if ($a -match '^[Qq]$') { return $null }; Write-Host "Type 1, 2, 3 or Q." -ForegroundColor Red; continue }
        }
        if (-not $cs) { return $null }
        $ci = Get-ConnInfo $cs
        if (-not $ci) { Write-Host "That isn't a valid connection string (it needs at least a server and a database)." -ForegroundColor Red; return $null }
        Write-Host ("  {0}: {1} / {2}" -f (Get-EngineLabel $ci.Engine), $ci.Server, $ci.Database)
        if (Confirm-Yes "Test the connection now?") {
            Write-Host "  Connecting..." -ForegroundColor DarkGray
            $err = Test-DbConnection $cs
            if ($err) {
                Write-Host "  Could not connect: $err" -ForegroundColor Red
                if (-not (Confirm-Yes "Save it anyway?")) { return $null }
            }
            else { Write-Host "  Connection works." -ForegroundColor Green }
        }
        return $cs
    }
}

# ---------------------------------------------------------------- screens

function Get-AutoLabel($cfg, [string]$name) {
    $a = @($cfg.AutoBackup | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
    if ($a) { return "auto: " + ($a.Formats -join ", ") }
    return ""
}

function Show-Connections($cfg) {
    $list = @($cfg.Connections)
    if (-not $list.Count) { Write-Host "  (no connections yet - press A to add one)" -ForegroundColor DarkGray }
    for ($i = 0; $i -lt $list.Count; $i++) {
        $ci = Get-ConnInfo $list[$i].ConnectionString
        if ($ci) { Write-Host ("  {0,2}. {1,-20} {2,-11} {3} / {4}  " -f ($i + 1), $list[$i].Name, (Get-EngineLabel $ci.Engine), $ci.Server, $ci.Database) -NoNewline }
        else { Write-Host ("  {0,2}. {1,-20} (invalid connection string)  " -f ($i + 1), $list[$i].Name) -ForegroundColor Red -NoNewline }
        Write-Host (Get-AutoLabel $cfg $list[$i].Name) -ForegroundColor DarkCyan
    }
}

function Add-Connection {
    $cfg = Read-Config
    Write-Step "ADD A CONNECTION"
    while ($true) {
        $name = Ask "Name for the connection (short, e.g. cocacola or hotel-test; Q = cancel)"
        if ($name -match '^[Qq]$') { return }
        $err = Test-ConnName $name $cfg ""
        if (-not $err) { break }
        Write-Host $err -ForegroundColor Red
    }
    $cs = Read-ConnectionString ""
    if (-not $cs) { Write-Host "  Not added." -ForegroundColor Yellow; return }
    $lines = Get-Lines
    Set-Entry $lines "connections" $name $cs
    Save-Lines $lines "connection '$name' added"
    if (Confirm-Yes "Include '$name' in the automatic backups?") { Set-AutoBackup $name (Get-DbEngine $cs) }
}

# Asks the Auto Backup format for one connection and saves it ("off" removes it from the list).
function Set-AutoBackup([string]$name, [string]$engine) {
    $full = if ($engine -eq "pg") { "dump" } else { "bak" }
    Write-Host ""
    Write-Host "Automatic backup format for '$name':" -ForegroundColor Yellow
    Write-Host "  1. .$full$(if ($engine -ne 'pg') { '  (a hosted database needs SQL Server Express on this PC)' })"
    Write-Host "  2. .sql  (works with read-only logins)"
    Write-Host "  3. both"
    Write-Host "  0. Off - don't back it up automatically"
    Write-Host "  Q. Cancel"
    while ($true) {
        $a = Ask ">"
        $fmt = switch ($a) { "1" { $full } "2" { "sql" } "3" { "both" } "0" { "off" } default { $null } }
        if ($a -match '^[Qq]$') { return }
        if ($fmt) { break }
        Write-Host "Type 0-3 or Q." -ForegroundColor Red
    }
    $lines = Get-Lines
    if ($fmt -eq "off") { Remove-Entry $lines "autobackup" $name; Save-Lines $lines "'$name' removed from the automatic backups" }
    else { Set-Entry $lines "autobackup" $name $fmt; Save-Lines $lines "'$name' backed up automatically as $fmt" }
}

function Edit-Connection([string]$name) {
    while ($true) {
        $cfg = Read-Config
        $conn = @($cfg.Connections | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
        if (-not $conn) { return }
        $ci = Get-ConnInfo $conn.ConnectionString
        $auto = Get-AutoLabel $cfg $name
        Write-Step "CONNECTION '$name'"
        if ($ci) { Write-Host ("  {0}: {1} / {2}" -f (Get-EngineLabel $ci.Engine), $ci.Server, $ci.Database) }
        else { Write-Host "  (invalid connection string)" -ForegroundColor Red }
        Write-Host ""
        Write-Host "  1. Change the connection details"
        Write-Host "  2. Rename"
        Write-Host "  3. Test the connection"
        Write-Host "  4. Automatic backup  ($(if ($auto) { $auto.Substring(6) } else { 'off' }))"
        Write-Host "  5. Show the full connection string (includes the password)"
        Write-Host "  6. Remove this connection"
        Write-Host "  Q. Back"
        $a = Ask ">"
        switch ($a) {
            "1" {
                $cs = Read-ConnectionString $conn.ConnectionString
                if ($cs) { $lines = Get-Lines; Set-Entry $lines "connections" $name $cs; Save-Lines $lines "connection '$name' changed" }
                else { Write-Host "  Not changed." -ForegroundColor Yellow }
                Pause-Menu
            }
            "2" {
                $new = Ask "New name (Enter = cancel)"
                if (-not $new) { break }
                $err = Test-ConnName $new $cfg $name
                if ($err) { Write-Host $err -ForegroundColor Red; Pause-Menu; break }
                $lines = Get-Lines
                Rename-Entry $lines "connections" $name $new
                Rename-Entry $lines "autobackup" $name $new
                Save-Lines $lines "'$name' renamed to '$new'"
                Write-Host "  Its backups already made stay in the folder '$name' under Backups; new ones go to '$new'." -ForegroundColor DarkGray
                $name = $new
                Pause-Menu
            }
            "3" {
                Write-Host "  Connecting..." -ForegroundColor DarkGray
                $err = Test-DbConnection $conn.ConnectionString
                if ($err) { Write-Host "  Could not connect: $err" -ForegroundColor Red } else { Write-Host "  Connection works." -ForegroundColor Green }
                Pause-Menu
            }
            "4" { Set-AutoBackup $name (Get-DbEngine $conn.ConnectionString); Pause-Menu }
            "5" { Write-Host ""; Write-Host "  $($conn.ConnectionString)"; Pause-Menu }
            "6" {
                if (Confirm-Yes "Remove '$name'? (backups already made are not deleted)") {
                    $lines = Get-Lines
                    Remove-Entry $lines "connections" $name
                    Remove-Entry $lines "autobackup" $name
                    Save-Lines $lines "connection '$name' removed"
                    Pause-Menu
                    return
                }
            }
            default { if ($a -match '^[Qq]$') { return } }
        }
    }
}

function Test-AllConnections {
    $cfg = Read-Config
    Write-Step "TESTING ALL CONNECTIONS"
    foreach ($c in $cfg.Connections) {
        Write-Host ("  {0,-20} " -f $c.Name) -NoNewline
        if (-not (Get-ConnInfo $c.ConnectionString)) { Write-Host "invalid connection string" -ForegroundColor Red; continue }
        $err = Test-DbConnection $c.ConnectionString
        if ($err) { Write-Host "FAILED - $err" -ForegroundColor Red } else { Write-Host "OK" -ForegroundColor Green }
    }
    Pause-Menu
}

function Edit-AutoBackupList {
    while ($true) {
        $cfg = Read-Config
        Write-Step "AUTOMATIC BACKUPS  (what Auto Backup.bat backs up)"
        $list = @($cfg.Connections)
        $orphans = @($cfg.AutoBackup | Where-Object { $n = $_.Name; -not @($list | Where-Object { $_.Name -eq $n }).Count })
        for ($i = 0; $i -lt $list.Count; $i++) {
            $auto = Get-AutoLabel $cfg $list[$i].Name
            Write-Host ("  {0,2}. {1,-20} {2}" -f ($i + 1), $list[$i].Name, $(if ($auto) { $auto.Substring(6) } else { "off" })) -ForegroundColor $(if ($auto) { "White" } else { "DarkGray" })
        }
        for ($i = 0; $i -lt $orphans.Count; $i++) {
            Write-Host ("  {0,2}. {1,-20} {2}  - no connection with this name" -f ($list.Count + $i + 1), $orphans[$i].Name, ($orphans[$i].Formats -join ", ")) -ForegroundColor Red
        }
        Write-Host "  Type a number to change it, or Q to go back." -ForegroundColor DarkGray
        $a = Ask ">"
        if ($a -match '^[Qq]$') { return }
        if ($a -notmatch '^\d+$' -or [int]$a -lt 1 -or [int]$a -gt $list.Count + $orphans.Count) { Write-Host "Not a valid choice." -ForegroundColor Red; continue }
        $n = [int]$a
        if ($n -le $list.Count) { Set-AutoBackup $list[$n - 1].Name (Get-DbEngine $list[$n - 1].ConnectionString) }
        else {
            $o = $orphans[$n - $list.Count - 1].Name
            if (Confirm-Yes "Remove '$o' from the automatic backups?") { $lines = Get-Lines; Remove-Entry $lines "autobackup" $o; Save-Lines $lines "'$o' removed from the automatic backups" }
        }
    }
}

function Edit-Settings {
    while ($true) {
        $lines = Get-Lines
        $cfg = Read-Config
        Write-Step "SETTINGS"
        $keys = @($SettingInfo.Keys)
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $v = Get-EntryValue $lines "" $keys[$i]
            Write-Host ("  {0}. {1,-15} = {2}" -f ($i + 1), $keys[$i], $(if ($null -eq $v) { "(not set - default used)" } elseif (-not $v) { "(empty)" } else { $v }))
        }
        Write-Host "  Backups currently go to: $($cfg.outputFolder)" -ForegroundColor DarkGray
        Write-Host "  Q. Back"
        $a = Ask ">"
        if ($a -match '^[Qq]$') { return }
        if ($a -notmatch '^\d+$' -or [int]$a -lt 1 -or [int]$a -gt $keys.Count) { Write-Host "Not a valid choice." -ForegroundColor Red; continue }
        $key = $keys[[int]$a - 1]
        Write-Host "  $($SettingInfo[$key])" -ForegroundColor DarkGray
        $val = Ask "New value for $key (Enter = keep, - = empty)"
        if (-not $val) { continue }
        if ($val -eq "-") { $val = "" }
        if ($key -eq "autoBackupKeep" -and $val -notmatch '^\d+$') { Write-Host "Type a whole number (0 = keep all)." -ForegroundColor Red; Pause-Menu; continue }
        if ($key -eq "outputFolder" -and -not $val) { Write-Host "The backup folder can't be empty." -ForegroundColor Red; Pause-Menu; continue }
        if ($key -in "outputFolder", "schemaFile" -and $val) {
            $p = [Environment]::ExpandEnvironmentVariables($val.Trim('"'))
            if (-not [IO.Path]::IsPathRooted($p)) { $p = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ConfigPath) $p)) }
            if (-not (Test-Path -LiteralPath $p)) {
                if ($key -eq "schemaFile") { Write-Host "  Note: $p doesn't exist (yet)." -ForegroundColor Yellow }
                elseif (Confirm-Yes "$p doesn't exist. Create it?") { [void](New-Item -ItemType Directory -Path $p -Force) }
            }
        }
        $lines = Get-Lines
        Set-Entry $lines "" $key $val
        Save-Lines $lines "$key changed"
    }
}

# Returns a list of problems found in connections.txt.
function Get-ConfigProblems {
    $cfg = Read-Config
    $lines = Get-Lines
    $p = @($cfg.Warnings)
    foreach ($k in $SettingInfo.Keys) { if ($null -eq (Get-EntryValue $lines "" $k)) { $p += "setting '$k' is missing (the default is used)" } }
    if ("$((Get-EntryValue $lines '' 'autoBackupKeep'))" -notmatch '^\d*$') { $p += "autoBackupKeep must be a whole number" }
    if ($cfg.schemaFile -and -not (Test-Path -LiteralPath $cfg.schemaFile)) { $p += "schemaFile not found: $($cfg.schemaFile)" }
    if (-not (Get-Section $lines "connections")) { $p += "the [connections] section is missing" }
    foreach ($c in $cfg.Connections) { if (-not (Get-ConnInfo $c.ConnectionString)) { $p += "connection '$($c.Name)' has an invalid connection string" } }
    foreach ($a in $cfg.AutoBackup) {
        $conn = @($cfg.Connections | Where-Object { $_.Name -eq $a.Name }) | Select-Object -First 1
        if (-not $conn) { $p += "automatic backup '$($a.Name)': there is no connection with this name"; continue }
        $pg = (Get-DbEngine $conn.ConnectionString) -eq "pg"
        foreach ($f in $a.Formats) {
            if ($f -notin "bak", "dump", "sql", "both") { $p += "automatic backup '$($a.Name)': unknown format '$f' (use $(if ($pg) { 'dump' } else { 'bak' }), sql or both)" }
        }
    }
    return , $p
}

function Show-Check {
    Write-Step "CHECKING connections.txt"
    $p = Get-ConfigProblems
    if (-not $p.Count) { Write-Host "  No problems found." -ForegroundColor Green }
    else {
        foreach ($x in $p) { Write-Host "  - $x" -ForegroundColor Yellow }
        Write-Host "  Fix them with the options in this menu, or U / D if the file is badly damaged." -ForegroundColor DarkGray
    }
    Pause-Menu
}

function Restore-History {
    $files = @(Get-ChildItem -LiteralPath $HistoryDir -Filter "connections_*.txt" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    Write-Step "UNDO - EARLIER VERSIONS OF connections.txt"
    if (-not $files.Count) { Write-Host "  No earlier versions yet (one is kept each time you save here)." -ForegroundColor DarkGray; Pause-Menu; return }
    for ($i = 0; $i -lt $files.Count; $i++) {
        $n = @([IO.File]::ReadAllLines($files[$i].FullName) | Where-Object { $_ -match '^\s*[^#\[\s][^=]*=' }).Count
        Write-Host ("  {0,2}. {1:yyyy-MM-dd HH:mm:ss}   ({2} entries)" -f ($i + 1), $files[$i].LastWriteTime, $n)
    }
    Write-Host "  1 = the version before your last change. Q = back." -ForegroundColor DarkGray
    $a = Ask ">"
    if ($a -notmatch '^\d+$' -or [int]$a -lt 1 -or [int]$a -gt $files.Count) { return }
    $f = $files[[int]$a - 1]
    if (-not (Confirm-Yes "Put back the version from $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))? (the current one is kept as an earlier version)")) { return }
    Save-Lines ([Collections.Generic.List[string]]@([IO.File]::ReadAllLines($f.FullName))) "version from $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) restored"
    Pause-Menu
}

function Reset-FromSample {
    if (-not (Test-Path -LiteralPath $SamplePath)) { Write-Host "The sample file is missing: $SamplePath" -ForegroundColor Red; Pause-Menu; return }
    Write-Step "START AGAIN FROM THE SAMPLE FILE"
    Write-Host "  1. Rebuild the file but keep my connections, automatic backups and settings  (fixes a damaged layout)"
    Write-Host "  2. Start completely fresh - no connections  (only the sample examples)"
    Write-Host "  Q. Cancel"
    Write-Host "  Either way the current file is kept and can be put back with U." -ForegroundColor DarkGray
    $a = Ask ">"
    if ($a -notin "1", "2") { return }
    $lines = [Collections.Generic.List[string]]@([IO.File]::ReadAllLines($SamplePath))
    if ($a -eq "1" -and (Test-Path -LiteralPath $ConfigPath)) {
        $old = Get-Lines
        $cfg = Read-Config
        foreach ($k in $SettingInfo.Keys) { $v = Get-EntryValue $old "" $k; if ($null -ne $v) { Set-Entry $lines "" $k $v } }
        foreach ($c in $cfg.Connections) { Set-Entry $lines "connections" $c.Name $c.ConnectionString }
        foreach ($x in $cfg.AutoBackup) { Set-Entry $lines "autobackup" $x.Name ($x.Formats -join ", ") }
    }
    elseif (-not (Confirm-Yes "Remove all connections and automatic backups?")) { return }
    Save-Lines $lines $(if ($a -eq "1") { "file rebuilt from the sample, entries kept" } else { "fresh file from the sample" })
    Pause-Menu
}

# ---------------------------------------------------------------- main menu

try {
    while ($true) {
        Clear-Host
        Write-Banner "EDIT CONNECTIONS  (conn\connections.txt)"
        $cfg = Read-Config
        foreach ($w in $cfg.Warnings) { Write-Host "  connections.txt: $w" -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "Connections:" -ForegroundColor Yellow
        Show-Connections $cfg
        Write-Host ""
        if ($cfg.Connections.Count) { Write-Host "  Type a number to change, test, rename or remove that connection." -ForegroundColor DarkGray }
        Write-Host "   A. Add a connection"
        Write-Host "   T. Test all connections"
        Write-Host "   B. Automatic backups (which databases, which format)"
        Write-Host "   S. Settings (backup folder, schema file, local server, how many backups to keep)"
        Write-Host "   K. Check the file for mistakes"
        Write-Host "   U. Undo - put back an earlier version"
        Write-Host "   D. Start again from the sample file"
        Write-Host "   N. Open in Notepad"
        Write-Host "   Q. Quit"
        $a = Ask ">"
        try {
            if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $cfg.Connections.Count) { Edit-Connection $cfg.Connections[[int]$a - 1].Name; continue }
            switch ($a) {
                { $_ -match '^[Aa]$' } { Add-Connection; Pause-Menu }
                { $_ -match '^[Tt]$' } { Test-AllConnections }
                { $_ -match '^[Bb]$' } { Edit-AutoBackupList }
                { $_ -match '^[Ss]$' } { Edit-Settings }
                { $_ -match '^[Kk]$' } { Show-Check }
                { $_ -match '^[Uu]$' } { Restore-History }
                { $_ -match '^[Dd]$' } { Reset-FromSample }
                { $_ -match '^[Nn]$' } {
                    $before = (Get-Item -LiteralPath $ConfigPath).LastWriteTime
                    if (-not (Test-Path -LiteralPath $HistoryDir)) { [void](New-Item -ItemType Directory -Path $HistoryDir) }
                    $copy = Join-Path $HistoryDir ("connections_{0:yyyy-MM-dd_HH-mm-ss-fff}.txt" -f (Get-Date))
                    Copy-Item -LiteralPath $ConfigPath $copy
                    Start-Process notepad.exe -ArgumentList "`"$ConfigPath`"" -Wait
                    if ((Get-Item -LiteralPath $ConfigPath).LastWriteTime -eq $before) { Remove-Item -LiteralPath $copy } else { Show-Check }
                }
                { $_ -match '^[Qq]$' } { return }
                default { Write-Host "Not a valid choice." -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
            }
        }
        catch {
            if ($_.Exception.Message -eq "No more input - stopping.") { throw }
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Pause-Menu
        }
    }
}
catch { Write-Host ""; Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
