# Licensing (for the supplier only)

The tools only run with a signed `licence.key` in the main folder. Each licence names the customer and an end date, normally one year from the start.

| Days until the licence ends | What the customer sees |
|---|---|
| More than 30 | Nothing |
| 30 to 0 | Yellow reminder when a tool starts; the tool works |
| 1 to 14 days after it ended | Yellow warning with the days left; the tool works |
| More than 14 days after it ended | Red message; the tool closes (scheduled Auto Backups stop too) |

The check is in `lib\Licence.ps1`. Every tool except Install Dependencies runs it at startup. Change `$LicenceWarnDays` and `$LicenceGraceDays` there to adjust the timings, and set `$LicenceContact` to the email address customers should use to renew.

## One-time setup

Double-click **`Issue Licence.bat`**. On the first run it calls `New-SigningKey.ps1`, which:

- makes your private signing key at `%USERPROFILE%\DatabaseTools-Licensing\signing-key.xml`, outside this folder, so it is never shipped or committed
- writes the matching public key into `lib\Licence.ps1`. Commit that change.

**Back up `signing-key.xml`.** If it is lost, you can't issue renewals that the copies you've shipped will accept. If someone else gets it, they can make licences.

## Issuing and renewing

Double-click **`Issue Licence.bat`** and type the customer name and email. It saves `licence.key` in `%USERPROFILE%\DatabaseTools-Licensing\issued\<customer> <end date>\` and adds a line to `issued.csv` (your list of who has a licence and when it ends). Send the customer that `licence.key`.

For a **renewal**, type the same customer name. If they renew before their licence ends, the new year starts the day after the old one ends, so they don't lose any days. If it has already ended, the new year starts today.

## Shipping to a customer

Give them the main folder **without** the `licensing` folder, plus their own `licence.key`. (Even with this folder, nobody can make a licence without your private key.)

## Limits

The tools are plain PowerShell scripts, so someone who knows PowerShell could edit the check out of `lib\Licence.ps1`. They can't make a licence or change the end date on one, but the check does rely on the PC's clock.
