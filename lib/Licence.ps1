# Yearly licence check. Dot-sourced by Common.ps1 - not meant to be run on its own.
# The customer's licence is the file "licence.key" in the main folder (next to the .bat files).
# It is signed with the supplier's private key (kept outside this folder, see licensing\README.md);
# only the public key below is shipped, so a licence can be checked here but not made or changed.

# Written by licensing\New-SigningKey.ps1 - don't edit by hand.
$LicencePublicKey = '<RSAKeyValue><Modulus>mdlKFui6bLYwdOjaCJbLFVSrem/gV/QmW+QwkCOYgshf1tkGhanELSypy6uhx7GdbyRZ9miq4gsujujTL9Sr3BRG88FQLqZ95ugpIvSPkyMg8x1HvMHmSQH0zWuHZs7KFdl1pR+E2gV51qxJODti6kf8DUtm0L24wKPg4fd6v1nVDuoRtxY8QhJ+3TENHcpOufKhi1b5iQhG4YIP2VRWkTsnM6RdaAfwa+obOlzKUZCyzI793D/zTB8r/Cz1QDV5E80w367TSHM/DnQNY/aiYPB/DqLu/Jz5jodF6vljbdRbGQ15SPBhL+myKhPH3hpQtc/lJSbqrwNS6ApeyTcy5Q==</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
# Shown to the customer when the licence needs renewing, e.g. "renewals@yourcompany.com".
$LicenceContact = ''

$LicenceWarnDays = 30    # warn this many days before the licence ends
$LicenceGraceDays = 14   # keep working this many days after it ends, with a warning
$LicenceFields = @("Customer", "Email", "LicenceId", "Issued", "Expires")

# The exact text that is signed: one "name=value" line per field, in $LicenceFields order.
function Get-LicencePayload($lic) {
    return "DBTOOLS-LICENCE-1`n" + (($LicenceFields | ForEach-Object { "$_=$($lic[$_])" }) -join "`n")
}

# Reads licence.key into a hashtable (field -> value), or $null if the file is missing.
function Read-LicenceFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $lic = @{}
    foreach ($raw in [IO.File]::ReadAllLines($path)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $i = $line.IndexOf("=")
        if ($i -gt 0) { $lic[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() }
    }
    return $lic
}

# Returns @{ Status; Message; Licence } where Status is Ok, Warn, Grace, Expired, Missing or Invalid.
function Get-LicenceStatus([string]$path) {
    $lic = Read-LicenceFile $path
    if ($null -eq $lic) { return @{ Status = "Missing"; Message = "No licence found. Put your licence.key file in:`n  $(Split-Path -Parent $path)" } }
    if (-not $LicencePublicKey) { return @{ Status = "Invalid"; Message = "These tools have not been set up for licensing yet (no public key in lib\Licence.ps1)." } }
    foreach ($f in $LicenceFields + "Signature") {
        if (-not $lic[$f]) { return @{ Status = "Invalid"; Message = "licence.key is damaged (missing '$f')." } }
    }
    $ok = $false
    try {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString($LicencePublicKey)
        $data = [Text.Encoding]::UTF8.GetBytes((Get-LicencePayload $lic))
        $ok = $rsa.VerifyData($data, (New-Object System.Security.Cryptography.SHA256CryptoServiceProvider), [Convert]::FromBase64String($lic.Signature))
    } catch { $ok = $false }
    if (-not $ok) { return @{ Status = "Invalid"; Message = "licence.key is not valid (it was changed, or was not issued for these tools)." } }

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $expires = [datetime]::ParseExact($lic.Expires, "yyyy-MM-dd", $culture)
    $left = ($expires - (Get-Date).Date).Days
    $who = "Licensed to $($lic.Customer)"
    if ($left -ge $LicenceWarnDays) { return @{ Status = "Ok"; Licence = $lic; Message = "$who until $($lic.Expires)." } }
    if ($left -ge 0) { return @{ Status = "Warn"; Licence = $lic; Message = "$who - the licence ends on $($lic.Expires) ($left day(s) left). Please renew." } }
    $graceLeft = $LicenceGraceDays + $left
    if ($graceLeft -ge 0) { return @{ Status = "Grace"; Licence = $lic; Message = "$who - the licence ended on $($lic.Expires). The tools stop working in $graceLeft day(s) unless it is renewed." } }
    return @{ Status = "Expired"; Licence = $lic; Message = "$who - the licence ended on $($lic.Expires)." }
}

# Ends the whole PowerShell process (exit code 1) unless there is a valid licence; warns when it is about to end.
# Runs once per PowerShell process (tools that start other tools don't repeat it).
# -NoPause: don't wait for Enter before closing (scheduled / unattended runs).
function Assert-Licence([string]$path, [switch]$NoPause) {
    if ($global:DbToolsLicenceChecked) { return }
    $s = Get-LicenceStatus $path
    $contact = $(if ($LicenceContact) { $LicenceContact } else { "the supplier of these tools" })
    switch ($s.Status) {
        "Ok" { }
        { $_ -in "Warn", "Grace" } {
            Write-Host "LICENCE: $($s.Message)" -ForegroundColor Yellow
            Write-Host "         To renew, contact $contact." -ForegroundColor Yellow
            Write-Host ""
        }
        default {
            Write-Host ""
            Write-Host "LICENCE: $($s.Message)" -ForegroundColor Red
            Write-Host "To get or renew a licence, contact $contact." -ForegroundColor Red
            Write-Host "Then save the licence.key you receive in the main folder (replace the old one)." -ForegroundColor Red
            Write-Host ""
            if (-not $NoPause) { Read-Host "Press Enter to close" | Out-Null }
            # Not "exit": inside a dot-sourced script that would only leave Common.ps1 and the tool would carry on.
            [Environment]::Exit(1)
        }
    }
    $global:DbToolsLicenceChecked = $true
}
