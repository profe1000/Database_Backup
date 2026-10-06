# For the supplier (you): makes a signed yearly licence.key for a customer, or a renewal.
# Started by "Issue Licence.bat". Needs the private key made once by New-SigningKey.ps1.
# Every licence issued is saved in %USERPROFILE%\DatabaseTools-Licensing\issued and listed in issued.csv,
# which is also where renewals look up the customer's current end date.
param(
    [string]$Customer,
    [string]$Email,
    [int]$Years = 1,
    # First day of the licence (yyyy-MM-dd). Default: today, or the day after the customer's last licence ends.
    [string]$Start,
    [string]$KeyDir = (Join-Path $env:USERPROFILE "DatabaseTools-Licensing")
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\lib\Licence.ps1")

$keyFile = Join-Path $KeyDir "signing-key.xml"
$issuedDir = Join-Path $KeyDir "issued"
$register = Join-Path $KeyDir "issued.csv"
$culture = [Globalization.CultureInfo]::InvariantCulture

function Ask([string]$prompt, [string]$default) {
    $p = $(if ($default) { "$prompt [$default]" } else { $prompt })
    $r = Read-Host $p
    if ($null -eq $r) { throw "No more input - stopping." }
    $r = $r.Trim()
    return $(if ($r) { $r } else { $default })
}

try {
    if (-not (Test-Path -LiteralPath $keyFile)) { throw "No signing key at $keyFile. Run New-SigningKey.ps1 once first." }
    if (-not $LicencePublicKey) { throw "lib\Licence.ps1 has no public key. Run New-SigningKey.ps1 once first." }

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  ISSUE A YEARLY LICENCE" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    $history = @(if (Test-Path -LiteralPath $register) { Import-Csv -LiteralPath $register })
    if ($history.Count) {
        Write-Host ""
        Write-Host "Customers so far (latest licence):"
        $history | Group-Object Customer | ForEach-Object { $_.Group | Sort-Object Expires | Select-Object -Last 1 } |
            Sort-Object Expires | ForEach-Object { Write-Host ("  {0,-30} ends {1}" -f $_.Customer, $_.Expires) }
    }
    Write-Host ""
    if (-not $Customer) { $Customer = Ask "Customer name (as it should appear on the licence)" }
    if (-not $Customer -or $Customer -match '[\r\n=]') { throw "Type a customer name (no '=' sign)." }
    $last = $history | Where-Object { $_.Customer -eq $Customer } | Sort-Object Expires | Select-Object -Last 1
    if (-not $Email) { $Email = Ask "Customer email" $(if ($last) { $last.Email }) }
    if (-not $Email -or $Email -match '[\r\n]') { throw "Type an email address." }

    if (-not $Start) {
        $default = (Get-Date).Date
        if ($last) {
            # Renewal: carry on from the old end date so paying early doesn't lose days.
            $next = [datetime]::ParseExact($last.Expires, "yyyy-MM-dd", $culture).AddDays(1)
            if ($next -gt $default) { $default = $next }
            Write-Host "Renewal - the current licence ends $($last.Expires)." -ForegroundColor Yellow
        }
        $Start = Ask "Licence starts (yyyy-MM-dd)" $default.ToString("yyyy-MM-dd")
        $Years = [int](Ask "Number of years" "$Years")
    }
    $startDate = [datetime]::ParseExact($Start, "yyyy-MM-dd", $culture)
    if ($Years -lt 1) { throw "Number of years must be 1 or more." }

    $lic = @{
        Customer  = $Customer
        Email     = $Email
        LicenceId = [guid]::NewGuid().ToString()
        Issued    = (Get-Date).ToString("yyyy-MM-dd")
        Expires   = $startDate.AddYears($Years).AddDays(-1).ToString("yyyy-MM-dd")
    }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    $rsa.FromXmlString([IO.File]::ReadAllText($keyFile))
    $data = [Text.Encoding]::UTF8.GetBytes((Get-LicencePayload $lic))
    $lic.Signature = [Convert]::ToBase64String($rsa.SignData($data, (New-Object System.Security.Cryptography.SHA256CryptoServiceProvider)))

    $lines = @("# Database Tools licence - save this file as licence.key in the main folder (next to Main.bat).",
        "# Don't edit it: any change makes it invalid.")
    $lines += ($LicenceFields + "Signature") | ForEach-Object { "$_ = $($lic[$_])" }
    [void](New-Item -ItemType Directory -Path $issuedDir -Force)
    $safe = ($Customer -replace '[\\/:*?"<>|]', '_').Trim()
    $folder = Join-Path $issuedDir "$safe $($lic.Expires)"
    [void](New-Item -ItemType Directory -Path $folder -Force)
    $out = Join-Path $folder "licence.key"
    [IO.File]::WriteAllLines($out, $lines)

    # Check the new file the same way the tools will.
    $check = Get-LicenceStatus $out
    if ($check.Status -in "Missing", "Invalid") { throw "The new licence failed its own check: $($check.Message)" }

    [pscustomobject]@{ Customer = $Customer; Email = $Email; LicenceId = $lic.LicenceId; Issued = $lic.Issued; Starts = $startDate.ToString("yyyy-MM-dd"); Expires = $lic.Expires } |
        Export-Csv -LiteralPath $register -Append -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "Licence for $Customer, valid until $($lic.Expires):" -ForegroundColor Green
    Write-Host "  $out" -ForegroundColor Green
    Write-Host "Send that licence.key to the customer. They save it in the main folder (next to Main.bat)."
    Start-Process explorer.exe "/select,`"$out`""
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
