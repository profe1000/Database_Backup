# Automatic backups of the connections listed under [autobackup] in connections.txt.
#   "Auto Backup.bat"             -> menu: run now / schedule / remove schedule / log
#   Auto-Backup.ps1 -Unattended   -> runs the backups with no questions (used by the scheduled task)
# Old backups beyond "autoBackupKeep" (per database and format) are deleted automatically.
param([string]$ConfigPath, [switch]$Unattended)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common.ps1")
$TaskName = "Database Auto Backup"
$ScriptPath = $MyInvocation.MyCommand.Path

# "both" / "bak" / "dump" / "sql" -> the formats that exist for this database type.
function Resolve-Formats([string]$engine, $formats) {
    $out = @()
    foreach ($f in $formats) {
        switch ($f) {
            "both" { if ($engine -eq "pg") { $out += "dump", "sql" } else { $out += "bak", "sql" } }
            { $_ -in "bak", "dump" } { if ($engine -eq "pg") { $out += "dump" } else { $out += "bak" } }
            "sql" { $out += "sql" }
            default { throw "unknown format '$f' (use bak, dump, sql or both)" }
        }
    }
    return , @($out | Select-Object -Unique)
}

$script:LogFile = $null
function Write-Log([string]$msg, [string]$color = "Gray") {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
    Write-Host $line -ForegroundColor $color
}

# Keeps the newest $keep backups of each format for this database; deletes the rest (and their zips).
function Remove-OldBackupsAuto([IO.FileInfo]$newFile, [int]$keep) {
    $m = [regex]::Match($newFile.Name, $BackupStampRx)
    if (-not $m.Success) { return }
    $prefix = $m.Groups['p'].Value
    $files = @(Get-ChildItem -LiteralPath $newFile.DirectoryName -File | ForEach-Object {
            $x = [regex]::Match($_.Name, $BackupStampRx)
            if ($x.Success -and $x.Groups['p'].Value -eq $prefix) {
                $e = $x.Groups['e'].Value -replace '\.zip$', ''
                if ($e -eq 'zip') { $e = 'bak' }   # MyDb_<stamp>.zip is the zip of MyDb_<stamp>.bak
                [pscustomobject]@{ File = $_; Stamp = $x.Groups['s'].Value; Format = $e }
            }
        })
    foreach ($fmt in ($files | Group-Object Format)) {
        $sets = @($fmt.Group | Group-Object Stamp | Sort-Object Name -Descending)
        foreach ($old in ($sets | Select-Object -Skip $keep)) {
            foreach ($x in $old.Group) { Remove-Item -LiteralPath $x.File.FullName -Force }
            Write-Log "        removed old backup $prefix`_$($old.Name).$($fmt.Name)" "DarkGray"
        }
    }
}

# Runs all automatic backups. Returns the number of failures.
function Invoke-AutoBackup {
    $cfg = Read-Config
    New-Item -ItemType Directory -Force -Path $cfg.outputFolder | Out-Null
    $script:LogFile = Join-Path $cfg.outputFolder "auto-backup.log"
    $keep = 0; [void][int]::TryParse([string]$cfg.autoBackupKeep, [ref]$keep)
    if (-not $cfg.AutoBackup.Count) { Write-Log "No databases listed under [autobackup] in connections.txt - nothing to do." "Yellow"; return 1 }
    Write-Log "Auto backup started ($($cfg.AutoBackup.Count) database(s), keeping the newest $keep of each)." "Cyan"
    $fail = 0
    foreach ($a in $cfg.AutoBackup) {
        $conn = $cfg.Connections | Where-Object { $_.Name -eq $a.Name } | Select-Object -First 1
        if (-not $conn) { Write-Log "FAILED  $($a.Name): no connection with that name under [connections]" "Red"; $fail++; continue }
        $engine = Get-DbEngine $conn.ConnectionString
        try { $formats = Resolve-Formats $engine $a.Formats }
        catch { Write-Log "FAILED  $($a.Name): $($_.Exception.Message)" "Red"; $fail++; continue }
        foreach ($fmt in $formats) {
            try {
                $file = Invoke-Backup $cfg $conn $fmt
                Write-Log ("OK      {0}  .{1}  {2}  ({3} MB)" -f $a.Name, $fmt, $file.FullName, [Math]::Round($file.Length / 1MB, 1)) "Green"
                if ($keep -gt 0) { Remove-OldBackupsAuto $file $keep }
            }
            catch { Write-Log "FAILED  $($a.Name)  .$fmt  $($_.Exception.Message)" "Red"; $fail++ }
        }
    }
    Write-Log "Auto backup finished: $fail failure(s)." $(if ($fail) { "Red" } else { "Cyan" })
    return $fail
}

# ---------------------------------------------------------------- scheduling (Windows Task Scheduler, current user)

function Show-Schedule {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { Write-Host "  Schedule: not scheduled" -ForegroundColor DarkGray; return }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $trig = $task.Triggers | Select-Object -First 1
    $how = if ($trig.Repetition.Interval) { "every $($trig.Repetition.Interval -replace '^PT', '' -replace 'H', ' hour(s)' -replace 'M$', ' min')" } elseif ($trig.DaysOfWeek) { "weekly" } else { "daily" }
    Write-Host ("  Schedule: {0}, next run {1}" -f $how, $(if ($info.NextRunTime) { $info.NextRunTime.ToString("yyyy-MM-dd HH:mm") } else { "-" })) -ForegroundColor Green
    if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) {
        Write-Host ("            last run {0} ({1})" -f $info.LastRunTime.ToString("yyyy-MM-dd HH:mm"), $(if ($info.LastTaskResult -eq 0) { "all OK" } else { "had failures - see the log" })) -ForegroundColor DarkGray
    }
}

function Set-Schedule {
    Write-Host ""
    Write-Host "How often?" -ForegroundColor Yellow
    Write-Host "  1. Every day"
    Write-Host "  2. Once a week"
    Write-Host "  3. Every few hours"
    $how = Ask ">"
    if ($how -notin "1", "2", "3") { Write-Host "Cancelled."; return }
    $time = $null
    while (-not $time) {
        $t = Ask $(if ($how -eq "3") { "Start time (HH:mm, e.g. 08:00)" } else { "At what time? (HH:mm, e.g. 02:00)" })
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($t, "H:mm", [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$parsed)) { $time = $parsed } else { Write-Host "Use 24-hour time like 02:00 or 18:30." -ForegroundColor Red }
    }
    if ($how -eq "1") { $trigger = New-ScheduledTaskTrigger -Daily -At $time }
    elseif ($how -eq "2") {
        $days = [Enum]::GetNames([DayOfWeek])
        $d = Ask "Which day? ($($days -join ', '))"
        $day = $days | Where-Object { $_ -like "$d*" } | Select-Object -First 1
        if (-not $day) { Write-Host "Unknown day - cancelled." -ForegroundColor Red; return }
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $time
    }
    else {
        $h = Ask "Every how many hours? (1-23)"
        if ($h -notmatch '^\d+$' -or [int]$h -lt 1 -or [int]$h -gt 23) { Write-Host "Cancelled." -ForegroundColor Red; return }
        $trigger = New-ScheduledTaskTrigger -Once -At $time -RepetitionInterval (New-TimeSpan -Hours ([int]$h))
    }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Unattended") -WorkingDirectory $PSScriptRoot
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Backs up the databases listed under [autobackup] in $ConfigPath" -Force | Out-Null
    Write-Host "  Scheduled." -ForegroundColor Green
    Show-Schedule
    Write-Host "  It runs while you're signed in to Windows. If the PC is off at that time, it runs as soon as it's back on." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- main

if ($Unattended) {
    try { $failures = Invoke-AutoBackup } catch { Write-Log "FAILED: $($_.Exception.Message)" "Red"; $failures = 1 }
    exit ([int]$failures)
}

$host.UI.RawUI.WindowTitle = "Database Auto Backup"
try {
    while ($true) {
        Clear-Host
        Write-Banner "AUTOMATIC BACKUPS"
        $cfg = Read-Config
        Write-Host ""
        Write-Host "Databases backed up automatically ([autobackup] in connections.txt):" -ForegroundColor Yellow
        if (-not $cfg.AutoBackup.Count) { Write-Host "  (none yet - choose 4 and add lines like:  cocacola = sql)" -ForegroundColor DarkGray }
        foreach ($a in $cfg.AutoBackup) {
            $conn = $cfg.Connections | Where-Object { $_.Name -eq $a.Name } | Select-Object -First 1
            if (-not $conn) { Write-Host "  $($a.Name)  - not found under [connections]!" -ForegroundColor Red; continue }
            $engine = Get-DbEngine $conn.ConnectionString
            try { $fm = (Resolve-Formats $engine $a.Formats | ForEach-Object { ".$_" }) -join " + " } catch { $fm = "invalid: $($_.Exception.Message)" }
            Write-Host ("  {0,-22} {1,-11} {2}" -f $a.Name, (Get-EngineLabel $engine), $fm)
        }
        Write-Host "  Keeping the newest $($cfg.autoBackupKeep) backup(s) of each database and format (autoBackupKeep)." -ForegroundColor DarkGray
        Show-Schedule
        Write-Host ""
        Write-Host "  1. Run the backups now"
        Write-Host "  2. Schedule them (daily / weekly / every few hours)"
        Write-Host "  3. Remove the schedule"
        Write-Host "  4. Edit the list (which databases, which format)"
        Write-Host "  5. Open the log"
        Write-Host "  Q. Quit"
        $a = Ask ">"
        if ($a -match '^[Qq]$') { break }
        try {
            switch ($a) {
                "1" { Write-Host ""; [void](Invoke-AutoBackup); Read-Host "Press Enter to continue" | Out-Null }
                "2" { Set-Schedule; Read-Host "Press Enter to continue" | Out-Null }
                "3" {
                    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host "  Schedule removed." -ForegroundColor Green }
                    else { Write-Host "  There is no schedule." }
                    Read-Host "Press Enter to continue" | Out-Null
                }
                "4" { & (Join-Path $ToolDir "Edit-Connections.ps1") -ConfigPath $ConfigPath }
                "5" {
                    $log = Join-Path $cfg.outputFolder "auto-backup.log"
                    if (Test-Path -LiteralPath $log) { Start-Process notepad.exe -ArgumentList "`"$log`"" } else { Write-Host "  No log yet."; Read-Host "Press Enter to continue" | Out-Null }
                }
            }
        }
        catch {
            if ($_.Exception.Message -eq "No more input - stopping.") { throw }
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Read-Host "Press Enter to continue" | Out-Null
        }
    }
}
catch {
    if ($_.Exception.Message -ne "No more input - stopping.") {
        Write-Host ""
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Press Enter to close" | Out-Null
    }
}
