# Interactive backup menu. Started by "Backup Database.bat".
# Reads connections from connections.txt, backs up the chosen ones, then offers to clear old backups.
param([string]$ConfigPath)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common.ps1")
$host.UI.RawUI.WindowTitle = "Database Backup"

try {
    do {
        Clear-Host
        Write-Banner "DATABASE BACKUP  (SQL Server / PostgreSQL)"
        $engine = Select-Engine
        if (-not $engine) { break }
        $picked = Select-Connections "Which $(Get-EngineLabel $engine) database(s) do you want to back up?" -Engine $engine
        if (-not $picked) { break }
        $picked = @($picked)
        $cfg = Read-Config
        $formats = Select-BackupFormat $engine

        Write-Host ""
        Write-Host "Will back up:" -ForegroundColor Yellow
        foreach ($c in $picked) { $ci = Get-ConnInfo $c.ConnectionString; Write-Host "  - $($c.Name)  ($($ci.Server) / $($ci.Database))" }
        Write-Host "Format   : $(($formats | ForEach-Object { ".$_" }) -join " + ")"
        Write-Host "Saving to: $($cfg.outputFolder)\<name>\"
        if (-not (Confirm-Yes "Start?")) { continue }

        $results = @()
        $i = 0
        foreach ($c in $picked) {
            $i++
            Write-Host ""
            Write-Host "##### [$i/$($picked.Count)] $($c.Name) #####" -ForegroundColor Magenta
            foreach ($fmt in $formats) {
            try {
                $bak = Invoke-Backup $cfg $c $fmt
                $results += [pscustomobject]@{ Name = $c.Name; Ok = $true; Bak = $bak; Error = $null }
            }
            catch {
                $msg = $_.Exception.Message
                Write-Host "FAILED: $msg" -ForegroundColor Red
                if ($msg -match 'VIEW DEFINITION|BACKUP DATABASE permission') { Write-Host "Tip: this login can't make a .bak - choose the .sql format instead." -ForegroundColor Yellow }
                if ($msg -match 'already exists on') { Write-Host "Tip: a leftover local copy of this database exists on $($cfg.localServer). Delete it (or run Backup-RemoteDatabase.ps1 with -ReplaceLocal)." -ForegroundColor Yellow }
                $results += [pscustomobject]@{ Name = $c.Name; Ok = $false; Bak = $null; Error = $msg }
            }
            }
        }

        Write-Step "Summary"
        foreach ($r in $results) {
            if ($r.Ok) { Write-Host ("  OK      {0,-22} {1} ({2} MB)" -f $r.Name, $r.Bak.FullName, [Math]::Round($r.Bak.Length / 1MB, 1)) -ForegroundColor Green }
            else { Write-Host ("  FAILED  {0,-22} {1}" -f $r.Name, $r.Error) -ForegroundColor Red }
        }

        foreach ($g in ($results | Where-Object Ok | Group-Object Name)) { Clear-OldBackups @($g.Group | ForEach-Object Bak) $g.Name }

        $ok = @($results | Where-Object Ok)
        if ($ok.Count -and (Confirm-Yes "Open the backup folder?")) {
            if ($ok.Count -eq 1) { Start-Process explorer.exe "/select,`"$($ok[0].Bak.FullName)`"" }
            else { Start-Process explorer.exe "`"$($cfg.outputFolder)`"" }
        }
        Write-Host ""
    } while (Confirm-Yes "Back up more databases?")
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to close" | Out-Null
}
