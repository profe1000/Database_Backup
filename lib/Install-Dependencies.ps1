# Installs what the database tools need. Started by "Install Dependencies.bat".
# Safe to run again: anything already installed is detected and skipped.
#   -CheckOnly   just show what is installed
param([switch]$CheckOnly)
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'   # makes downloads much faster in Windows PowerShell

# ---- download locations (also listed in README.md)
$SqlExpressUrl = "https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLEXPR_x64_ENU.exe"   # SQL Server 2022 Express, offline package
$SqlPackageUrl = "https://aka.ms/sqlpackage-windows"
$PgUrl = "https://get.enterprisedb.com/postgresql/postgresql-18.3-1-windows-x64-binaries.zip"
$SqlPackageExe = Join-Path $env:USERPROFILE "sqlpackage\SqlPackage.exe"
$PgPsql = Join-Path $env:USERPROFILE "pgsql\bin\psql.exe"
$Instance = "SQLEXPRESS"

function Write-Title($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

function Get-Status {
    $s = [ordered]@{}
    $svc = Get-Service -Name "MSSQL`$$Instance" -ErrorAction SilentlyContinue
    $ver = $null
    if ($svc) {
        try {
            $c = New-Object System.Data.SqlClient.SqlConnection "Data Source=localhost\$Instance;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=10"
            $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)) + ' ' + CAST(SERVERPROPERTY('Edition') AS nvarchar(100))"; $ver = $cmd.ExecuteScalar(); $c.Close()
        } catch { $ver = "installed, service $($svc.Status) (couldn't connect: $($_.Exception.InnerException.Message))" }
    }
    $s["SQL Server Express"] = $(if ($svc) { $ver } else { $null })
    $s["SqlPackage"] = $(if (Test-Path $SqlPackageExe) { (Get-Item $SqlPackageExe).VersionInfo.ProductVersion.Split('+')[0] } else { $null })
    $s["PostgreSQL tools"] = $(if (Test-Path $PgPsql) { (& $PgPsql --version 2>$null) } else { $null })
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    $s["Node.js (optional)"] = $(if ($node) { "node " + (& $node.Source --version 2>$null) } else { $null })
    return $s
}

function Show-Status($s) {
    Write-Host ""
    foreach ($k in $s.Keys) {
        if ($s[$k]) { Write-Host ("  [OK]       {0,-20} {1}" -f $k, $s[$k]) -ForegroundColor Green }
        else { Write-Host ("  [missing]  {0,-20}" -f $k) -ForegroundColor Yellow }
    }
}

function Get-File([string]$url, [string]$file) {
    Write-Host "  Downloading $url ..."
    Invoke-WebRequest $url -OutFile $file -UseBasicParsing
    Write-Host ("  Downloaded {0:N0} MB" -f ((Get-Item $file).Length / 1MB))
}

function Install-SqlExpress {
    Write-Title "SQL Server 2022 Express"
    $exe = Join-Path ([IO.Path]::GetTempPath()) "SQLEXPR2022_x64_ENU.exe"
    $setupDir = Join-Path $env:USERPROFILE "sqlsetup"   # short path: SQL setup fails on paths over 260 characters
    Get-File $SqlExpressUrl $exe
    $sig = Get-AuthenticodeSignature $exe
    $v = (Get-Item $exe).VersionInfo
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "The SQL Server download isn't signed by Microsoft - stopped." }
    if (-not $v.ProductVersion.StartsWith("16.")) { throw "Expected SQL Server 2022 (version 16) but got $($v.ProductName) $($v.ProductVersion) - stopped." }
    Write-Host "  Verified: $($v.ProductName) $($v.ProductVersion), signed by Microsoft."
    Write-Host "  Unpacking..."
    if (Test-Path $setupDir) { Remove-Item $setupDir -Recurse -Force }
    $p = Start-Process $exe -ArgumentList "/q", "/x:$setupDir" -Wait -PassThru
    if ($p.ExitCode -ne 0 -or -not (Test-Path "$setupDir\SETUP.EXE")) { throw "Unpacking failed (exit code $($p.ExitCode))." }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Host "  Installing (5-15 minutes). Windows will ask for administrator permission - click Yes." -ForegroundColor Yellow
    $setupArgs = @("/Q", "/ACTION=Install", "/FEATURES=SQLENGINE", "/INSTANCENAME=$Instance", "/SQLSYSADMINACCOUNTS=`"$me`"",
        "/IACCEPTSQLSERVERLICENSETERMS", "/UPDATEENABLED=0", "/TCPENABLED=1", "/SQLSVCSTARTUPTYPE=Automatic")
    try { $p = Start-Process "$setupDir\SETUP.EXE" -ArgumentList $setupArgs -Verb RunAs -Wait -PassThru }
    catch { throw "Administrator permission was not given - SQL Server was not installed." }
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "SQL Server setup failed (exit code $($p.ExitCode)). Details: C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\Summary.txt"
    }
    if ($p.ExitCode -eq 3010) { Write-Host "  Installed - Windows wants a restart to finish." -ForegroundColor Yellow } else { Write-Host "  Installed." -ForegroundColor Green }
    Remove-Item $setupDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
}

function Install-SqlPackage {
    Write-Title "SqlPackage (Microsoft)"
    $zip = Join-Path ([IO.Path]::GetTempPath()) "sqlpackage.zip"
    Get-File $SqlPackageUrl $zip
    $dir = Split-Path $SqlPackageExe
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
    Remove-Item $zip -Force
    $sig = Get-AuthenticodeSignature $SqlPackageExe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { Remove-Item $dir -Recurse -Force; throw "SqlPackage isn't signed by Microsoft - removed." }
    Write-Host "  Installed to $dir (signed by Microsoft)." -ForegroundColor Green
}

function Install-PgTools {
    Write-Title "PostgreSQL 18 tools (EnterpriseDB binaries, about 340 MB)"
    $zip = Join-Path ([IO.Path]::GetTempPath()) "pgsql-binaries.zip"
    Get-File $PgUrl $zip
    $dir = Join-Path $env:USERPROFILE "pgsql"
    if (Test-Path $dir) {
        if (Test-Path (Join-Path $dir "localdata")) { throw "$dir exists and contains the private server's data (localdata) - not overwriting it. Rename it first if you want a clean install." }
        Remove-Item $dir -Recurse -Force
    }
    Write-Host "  Unpacking..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $env:USERPROFILE)   # the zip contains a "pgsql" folder
    Remove-Item $zip -Force
    $v = & $PgPsql --version 2>$null
    if ($v -notmatch 'PostgreSQL') { throw "The PostgreSQL tools don't run after unpacking." }
    Write-Host "  Installed to $dir ($v). Note: EnterpriseDB's files aren't code-signed; they were downloaded over HTTPS from enterprisedb.com." -ForegroundColor Green
}

function Install-Node {
    Write-Title "Node.js LTS (only needed for .prisma schema files)"
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { Write-Host "  winget isn't available - opening https://nodejs.org so you can install it." -ForegroundColor Yellow; Start-Process "https://nodejs.org/"; return }
    & $winget.Source install --id OpenJS.NodeJS.LTS --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget couldn't install Node.js (exit code $LASTEXITCODE). Install it from https://nodejs.org/" }
    Write-Host "  Installed. Close and reopen any open windows so 'node' is found." -ForegroundColor Green
}

# ---------------------------------------------------------------- main

$host.UI.RawUI.WindowTitle = "Install Dependencies"
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  INSTALL DEPENDENCIES FOR THE DATABASE TOOLS" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
$status = Get-Status
Show-Status $status
if ($CheckOnly) { return }

$missing = @($status.Keys | Where-Object { -not $status[$_] })
if ($missing.Count -eq 0) { Write-Host ""; Write-Host "Everything is installed." -ForegroundColor Green; return }

Write-Host ""
Write-Host "What each one is for:" -ForegroundColor Yellow
Write-Host "  SQL Server Express - .bak backups of hosted SQL Server databases, restoring .bak files, .sql -> .bak"
Write-Host "  SqlPackage         - reading hosted SQL Server databases for .bak backups (.bacpac)"
Write-Host "  PostgreSQL tools   - everything PostgreSQL (backup, restore, compare, copy across engines)"
Write-Host "  Node.js            - optional, only for .prisma schema files"
Write-Host ""
Write-Host "  1. Install everything that's missing (except the optional Node.js)  (recommended)"
Write-Host "  2. Ask me for each one"
Write-Host "  Q. Quit"
$a = (Read-Host ">").Trim()
if ($a -notin "1", "2") { return }

$failed = @()
foreach ($k in $missing) {
    if ($a -eq "1" -and $k -like "Node.js*") { continue }
    if ($a -eq "2" -and (Read-Host "Install $k? (Y/N)") -notmatch '^[Yy]') { continue }
    try {
        switch -wildcard ($k) {
            "SQL Server*" { Install-SqlExpress }
            "SqlPackage" { Install-SqlPackage }
            "PostgreSQL*" { Install-PgTools }
            "Node.js*" { Install-Node }
        }
    }
    catch { Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red; $failed += $k }
}

Write-Title "Result"
Show-Status (Get-Status)
if ($failed.Count) { Write-Host ""; Write-Host "Not installed: $($failed -join ', '). See README.md for manual download links." -ForegroundColor Red }
