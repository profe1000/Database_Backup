# ONE-TIME SETUP for the supplier (you), not for customers.
# Makes the private key that signs licences and puts the matching public key into lib\Licence.ps1.
# The private key is saved OUTSIDE this folder, so it is never shipped or committed:
#   %USERPROFILE%\DatabaseTools-Licensing\signing-key.xml
# Back that file up. If it is lost you can't issue renewals that the shipped tools accept;
# if someone else gets it they can make licences.
param([string]$KeyDir = (Join-Path $env:USERPROFILE "DatabaseTools-Licensing"))
$ErrorActionPreference = "Stop"

$keyFile = Join-Path $KeyDir "signing-key.xml"
$licenceScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\lib\Licence.ps1"))

if (Test-Path -LiteralPath $keyFile) {
    Write-Host "A signing key already exists: $keyFile" -ForegroundColor Yellow
    Write-Host "Making a new one would make every licence issued so far invalid, so nothing was changed." -ForegroundColor Yellow
    Write-Host "(To really start over, move that file somewhere else first and run this again.)"
    exit 1
}

[void](New-Item -ItemType Directory -Path $KeyDir -Force)
$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 2048
$rsa.PersistKeyInCsp = $false
[IO.File]::WriteAllText($keyFile, $rsa.ToXmlString($true))
# Only the current Windows user may read the private key.
& icacls.exe $keyFile /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null

$public = $rsa.ToXmlString($false)
$text = [IO.File]::ReadAllText($licenceScript)
$text = [regex]::Replace($text, "(?m)^\`$LicencePublicKey = '.*'\r?$", { param($m) "`$LicencePublicKey = '$public'" + $(if ($m.Value.EndsWith("`r")) { "`r" } else { "" }) })
[IO.File]::WriteAllText($licenceScript, $text)

Write-Host "Private key saved: $keyFile" -ForegroundColor Green
Write-Host "Public key written into: $licenceScript" -ForegroundColor Green
Write-Host "BACK UP the private key file now (e.g. to a USB stick or password manager)." -ForegroundColor Yellow
