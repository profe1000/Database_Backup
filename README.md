# Database Tools

Double-click tools for backing up, restoring, comparing, syncing and copying **SQL Server** and **PostgreSQL** databases, including hosted ones such as site4now. Everything runs on this PC with Windows PowerShell; there is nothing to install on the database servers.

| Double-click | What it does |
|---|---|
| `Main.bat` | Menu that opens any of the tools below |
| `Install Dependencies.bat` | Installs everything the tools need (run this first on a new PC) |
| `Edit Connections.bat` | Add, change, test or remove connections, automatic backups and settings |
| `Backup Database.bat` | Back up one, several or all databases to `.bak` / `.dump` / `.sql` |
| `Auto Backup.bat` | Run the backups listed in `connections.txt` automatically, on a schedule |
| `Restore Database.bat` | Restore a backup into a database, or convert between backup formats |
| `Compare and Sync.bat` | Compare two databases row by row and sync them |
| `Copy Across Engines.bat` | Copy a database from SQL Server to PostgreSQL or the other way round |

---

## 1. Quick start

1. Copy the whole folder to the PC (the `.bat` files and the `lib` folder must stay together).
2. Double-click **`Install Dependencies.bat`** and choose **1**. When Windows asks *"Do you want to allow this app to make changes"*, click **Yes** (needed for SQL Server Express only).
3. Double-click **`Edit Connections.bat`**, press **A** and add your databases (see below).
4. Double-click **`Main.bat`** and pick a tool (or double-click the tool's own `.bat`). Every tool first asks **1. SQL Server / 2. PostgreSQL** and then lists your connections of that type.

Nothing is changed in a database until you confirm, and changing operations offer a backup first and ask you to type **YES** (or the database name).

---

## 2. Dependencies

`Install Dependencies.bat` downloads and installs these for you, and skips anything already installed. To install by hand, use the links:

| Dependency | Needed for | Download | Installed to |
|---|---|---|---|
| **Windows 10/11 + Windows PowerShell 5.1** | everything | built into Windows | - |
| **SQL Server 2022 Express** (free) | `.bak` backups of hosted SQL Server databases, restoring `.bak` files, converting `.sql` -> `.bak`, restoring to "this PC" | [SQL Server downloads](https://www.microsoft.com/en-us/sql-server/sql-server-downloads) - offline package used by the installer: [SQLEXPR_x64_ENU.exe](https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLEXPR_x64_ENU.exe) | instance `localhost\SQLEXPRESS` |
| **SqlPackage** (Microsoft) | `.bak` backups of hosted SQL Server databases (via `.bacpac`), `.bacpac` files | [SqlPackage download page](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-download) - [direct zip](https://aka.ms/sqlpackage-windows) | `%USERPROFILE%\sqlpackage` |
| **PostgreSQL 18 tools** (`psql`, `pg_dump`, `pg_restore`, private local server) | all PostgreSQL features | [EnterpriseDB binaries](https://www.enterprisedb.com/download-postgresql-binaries) - [direct zip (18.3)](https://get.enterprisedb.com/postgresql/postgresql-18.3-1-windows-x64-binaries.zip) | `%USERPROFILE%\pgsql` |
| **Node.js LTS** (optional) | only for `.prisma` schema files in Compare and Sync | [nodejs.org](https://nodejs.org/) | standard install |

Optional graphical tools for looking inside databases (not needed by the tools):
[SQL Server Management Studio](https://learn.microsoft.com/en-us/ssms/install/install) and [pgAdmin](https://www.pgadmin.org/download/).

Notes
- The SQL Server installer is checked to be signed by Microsoft and to be version 2022 before it runs. (The current "Express" download on Microsoft's site is SQL Server **2025**; its `.bak` files can't be restored on SQL Server 2022 servers such as site4now, so 2022 is used on purpose.)
- EnterpriseDB's PostgreSQL files are not code-signed; they are downloaded over HTTPS from enterprisedb.com.
- SQL Server Express databases can be at most 10 GB each.

---

## 3. `conn\connections.txt`

One settings file for all tools. **It contains passwords - don't share or email it.**

Change it with **`Edit Connections.bat`** instead of editing the file by hand:

| Key | What it does |
|---|---|
| a number | Change, rename, test or remove that connection, set its automatic backup, or show the full connection string |
| **A** | Add a connection: paste a connection string, or type server / database / login and the string is built for you. You can test it before it's saved. |
| **T** | Test all connections |
| **B** | Automatic backups: which databases `Auto Backup.bat` backs up, and in which format |
| **S** | Settings: backup folder, schema file, local server, how many backups to keep |
| **K** | Check the file for mistakes (bad connection strings, auto backups for names that don't exist, ...) |
| **U** | Undo: put back an earlier version. Every save keeps the previous file in `conn\history` (newest 20). |
| **D** | Start again from the sample file: either rebuild the file but keep your entries (fixes a damaged file), or start fresh |
| **N** | Open the file in Notepad (it's checked for mistakes after you close Notepad) |

`conn\connections.sample.txt` is a clean copy with examples and no passwords. The tools never change it. If `connections.txt` is deleted, the next tool you open makes a new one from the sample.

The file itself looks like this (lines starting with `#` are comments, and they're kept when the editor saves):

```ini
outputFolder   = ..\Backups         # where backups and reports go (one sub-folder per connection)
schemaFile     =                    # optional .sql or .prisma file used by Compare and Sync
localServer    = localhost\SQLEXPRESS
autoBackupKeep = 7                  # Auto Backup keeps this many backups per database and format (0 = all)

[connections]
# name = connection string  - the type is recognised automatically
cocacola = Data Source=server;Initial Catalog=MyDb;User Id=user;Password=...;Encrypt=True;TrustServerCertificate=True;
Hotel_db = Host=server;Port=5432;Database=mydb;Username=user;Password=...

[autobackup]
# connection name = format(s) for Auto Backup.bat
cocacola = sql
Hotel_db = dump
```

- **SQL Server** strings use `Data Source=...;Initial Catalog=...` (the usual .NET format).
- **PostgreSQL** strings use `Host=...;Port=...;Database=...;Username=...;Password=...` (Npgsql format) or `postgresql://user:password@host:port/db`.
- In any list you can also press **P** to paste a connection string that isn't in the file, or **E** to open the connection editor.

---

## 4. The tools

### Backup Database.bat
Pick the database type, then one database (`1`), several (`1,3`) or all (`A`), then the format:

| | Format | Notes |
|---|---|---|
| SQL Server | **.bak** | Native backup. Restores on SQL Server **2022 or newer** only. For hosted databases it's made through SqlPackage + the local SQL Server Express. |
| SQL Server | **.sql** | Script with structure + all data. Works with **read-only logins** and restores on **SQL Server 2014+**. |
| PostgreSQL | **.dump** | `pg_dump` custom format (PostgreSQL's equivalent of `.bak`). |
| PostgreSQL | **.sql** | Plain `pg_dump` script. |

Each backup is checked after it's made and also zipped. Files go to `Backups\<connection name>\<database>_<date>_<time>.<ext>`. Afterwards you can delete older backups of the same database (all, or keep the newest few).

### Auto Backup.bat
Backs up the databases listed under `[autobackup]` in `connections.txt`, in the format given there (`bak`, `dump`, `sql` or `both`).

- **1** runs them now, **2** schedules them (every day, once a week, or every few hours) in Windows Task Scheduler as task *"Database Auto Backup"*, **3** removes the schedule (this stops the automatic backups), **4** changes which databases are backed up, **5** opens the log.
- Old backups beyond `autoBackupKeep` are deleted automatically, per database and format.
- Every run is written to `Backups\auto-backup.log`.
- The schedule runs while you're signed in to Windows; if the PC was off at the scheduled time, it runs as soon as it's back on.

### Restore Database.bat
1. **Restore a backup** - pick a file from the recent list, browse, or paste a path (`.zip` files are unpacked automatically), then restore it into:
   - **a database on this PC** (SQL Server Express, or the private PostgreSQL server on port 54329), new or replacing one; or
   - **a database from `connections.txt`** - it offers a backup first, asks you to type the database name, deletes everything in it, then restores. A `.bak` can be restored into any SQL Server (including 2014 and hosted ones) because it's converted to a script first.
2. **Convert** - SQL Server: `.sql` or `.bacpac` -> `.bak`. PostgreSQL: `.dump` <-> `.sql`.

### Compare and Sync.bat
Pick database A and B (same type). It compares every table, column and row, shows the differences and saves a report in `Backups\Compare-Reports`. Then choose:

1. **Add missing rows** - into A, B or both (nothing is changed or deleted)
2. **Delete extra rows** - from A or B
3. **Copy A to B** / 4. **Copy B to A** - make one an exact copy of the other

Tables or columns missing on the side being changed are built from the other database, or from `schemaFile` (`.sql`, or `.prisma` with `provider = "sqlserver"` / `"postgresql"`). All row changes are made in one transaction and checked again afterwards.

### Copy Across Engines.bat
Copies between SQL Server and PostgreSQL (either direction):

1. **Create the tables and copy the data** - types, primary keys, indexes, foreign keys, auto-numbering and common defaults (`getdate()` <-> `now()`, `newid()` <-> `gen_random_uuid()`) are translated.
2. **Copy into tables that already exist** (e.g. created by your app or EF migrations) - tables and columns are matched ignoring upper/lower case and `_` (`SaleItems` = `sale_items`). Choose **replace the data** or **only add missing rows**.

The plan lists everything that had to be approximated and is saved to `Backups\Copy-Reports`. The copy runs in one transaction and every row is compared on both sides afterwards.
Not copied: views, procedures, functions and triggers (T-SQL and PL/pgSQL are different languages - they are listed so you can recreate them).

---

## 5. Troubleshooting

| Problem | Fix |
|---|---|
| *"running scripts is disabled on this system"* | Start the tools with the `.bat` files, or run `powershell -ExecutionPolicy Bypass -File lib\<script>.ps1`. |
| A `.bak` backup of a hosted SQL Server fails with *VIEW DEFINITION* / permission errors | The login can't read the database structure. Use the **.sql** format, or ask the host to grant `VIEW DEFINITION`. |
| *"backup comes from a newer SQL Server"* | `.bak` files only restore on the same or newer version. Use a `.sql` backup instead. |
| *"A database named ... already exists on localhost\SQLEXPRESS"* during a `.bak` backup | A copy left from an interrupted run. Delete that database on the local server, then retry. |
| SQL Server setup fails with *path exceeds 260 characters* | The installer already unpacks to `%USERPROFILE%\sqlsetup`; make sure your user name/path isn't unusually long. |
| PostgreSQL restore shows *(ignored) must be owner of extension* | Normal on hosted PostgreSQL - you aren't the server administrator. Real errors stop the restore and are shown. |
| Auto Backup didn't run | Check `Backups\auto-backup.log`, and that you were signed in to Windows. The `Auto Backup.bat` menu shows the next and last run. |

---

## 6. Files

The main folder holds the `.bat` launchers, `README.md`, `index.html`, the `Backups\` folder and the `conn\` folder. `conn\` holds your connections and is kept out of git (see `.gitignore`); only `connections.sample.txt` is committed. Everything else is in `lib\`:

| File | Purpose |
|---|---|
| `Main.bat`, `*.bat` (main folder) | The double-click launchers listed at the top |
| `conn\connections.txt` | Settings and connection strings (contains passwords) |
| `conn\connections.sample.txt` | Clean sample of `connections.txt` (no passwords), used to rebuild it |
| `conn\history\` | Earlier versions of `connections.txt`, kept by Edit Connections (contain passwords) |
| `Common.ps1`, `PgTools.ps1` | Shared code for SQL Server and PostgreSQL |
| `Backup-Launcher.ps1`, `Auto-Backup.ps1`, `Restore-Launcher.ps1`, `Compare-Sync.ps1`, `Copy-AcrossEngines.ps1`, `Edit-Connections.ps1`, `Install-Dependencies.ps1` | The tools behind the `.bat` files |
| `Backup-FromConnectionString.ps1` | `.bak` of a database on a server where the login may back up (e.g. the local server) |
| `Backup-RemoteDatabase.ps1` | `.bak` of a hosted SQL Server database (export -> local import -> backup) |
| `Export-SqlDump.ps1` / `Import-SqlDump.ps1` | Write / run a SQL Server `.sql` dump |
| `Backups\` (main folder) | Backups (one folder per connection), `Compare-Reports\`, `Copy-Reports\`, `auto-backup.log` |

The scripts can also be run directly from PowerShell, e.g.:

```powershell
powershell -ExecutionPolicy Bypass -File .\lib\Export-SqlDump.ps1 -ConnectionString "Data Source=...;Initial Catalog=...;..." -OutputDir D:\Backups -Zip
powershell -ExecutionPolicy Bypass -File .\lib\Auto-Backup.ps1 -Unattended
```
