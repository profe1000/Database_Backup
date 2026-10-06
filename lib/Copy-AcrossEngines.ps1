# Copy a database between SQL Server and PostgreSQL. Started by "Copy Across Engines.bat".
#
#   Mode 1 - create the tables in the target (types, primary keys, indexes, foreign keys,
#            auto-numbering and common defaults are translated) and copy all data.
#   Mode 2 - copy the data into tables that already exist in the target (e.g. created by the
#            app / EF migrations). Tables and columns are matched by name, ignoring case and "_",
#            so SaleItems matches sale_items. Either replace their data or only add missing rows.
#
# Views, procedures, functions and triggers are listed but not copied (T-SQL and PL/pgSQL differ).
# Everything is written in one transaction, and afterwards every row is compared on both sides.
param([string]$ConfigPath)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common.ps1")
$host.UI.RawUI.WindowTitle = "Copy Across Engines"

if (-not ("XEngine" -as [type])) {
    Add-Type -ReferencedAssemblies System.Data, System.Xml -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.Collections.Generic;
using System.Security.Cryptography;

public static class XEngine
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    // PostgreSQL keeps microseconds, SQL Server datetime2 keeps 100ns: both sides are rounded the same way.
    static DateTime RoundMicro(DateTime d)
    {
        long r = d.Ticks % 10;
        if (r == 0) return d;
        if (r >= 5 && d.Ticks + (10 - r) <= DateTime.MaxValue.Ticks) return d.AddTicks(10 - r);
        return d.AddTicks(-r);
    }
    static long RoundTicks(long t) { long r = t % 10; if (r < 0) r += 10; return r == 0 ? t : (r >= 5 ? t + 10 - r : t - r); }
    static string Hex(byte[] b) { var sb = new StringBuilder(b.Length * 2); foreach (var x in b) sb.Append(x.ToString("x2")); return sb.ToString(); }

    // ---------------- canonical form of a value (used to verify the copy)
    public static string Norm(object v)
    {
        if (v == null || v is DBNull) return "\u0001";
        if (v is bool) return (bool)v ? "1" : "0";
        if (v is byte || v is sbyte || v is short || v is ushort || v is int || v is uint || v is long) return Convert.ToInt64(v).ToString(Inv);
        if (v is decimal) return ((decimal)v).ToString("G29", Inv);
        if (v is double) return ((double)v).ToString("R", Inv);
        if (v is float) return ((float)v).ToString("R", Inv);
        if (v is DateTime) return RoundMicro((DateTime)v).ToString("yyyy-MM-ddTHH:mm:ss.ffffff", Inv);
        if (v is DateTimeOffset) return RoundMicro(((DateTimeOffset)v).UtcDateTime).ToString("yyyy-MM-ddTHH:mm:ss.ffffff", Inv) + "Z";
        if (v is TimeSpan) return new TimeSpan(RoundTicks(((TimeSpan)v).Ticks)).ToString("c", Inv);
        if (v is Guid) return ((Guid)v).ToString("D");
        if (v is byte[]) return Hex((byte[])v);
        return Convert.ToString(v, Inv);
    }

    // ---------------- SQL Server value -> PostgreSQL COPY text
    static string EscapeCopy(string s)
    {
        if (s.IndexOfAny(new[] { '\\', '\t', '\n', '\r', '\0' }) < 0) return s;
        var sb = new StringBuilder(s.Length + 8);
        foreach (char c in s)
        {
            switch (c)
            {
                case '\\': sb.Append("\\\\"); break;
                case '\t': sb.Append("\\t"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\0': break;   // PostgreSQL text can't hold NUL characters
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }

    public static string PgText(object v, string tk)
    {
        if (v == null || v is DBNull) return "\\N";
        if (v is bool) return tk == "bool" ? ((bool)v ? "t" : "f") : ((bool)v ? "1" : "0");
        if (v is DateTime)
        {
            var d = RoundMicro((DateTime)v);
            return tk == "date" ? d.ToString("yyyy-MM-dd", Inv) : d.ToString("yyyy-MM-dd HH:mm:ss.ffffff", Inv);
        }
        if (v is DateTimeOffset)
        {
            var o = (DateTimeOffset)v;
            if (tk != "tstz") return RoundMicro(o.UtcDateTime).ToString(tk == "date" ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss.ffffff", Inv);
            return RoundMicro(o.DateTime).ToString("yyyy-MM-dd HH:mm:ss.ffffff", Inv) + o.ToString("zzz", Inv);
        }
        if (v is TimeSpan) { var t = new TimeSpan(RoundTicks(((TimeSpan)v).Ticks)); return t.ToString("hh\\:mm\\:ss\\.ffffff", Inv); }
        if (v is byte[]) return "\\\\x" + Hex((byte[])v);
        if (v is Guid) return ((Guid)v).ToString("D");
        if (v is double) return ((double)v).ToString("R", Inv);
        if (v is float) return ((float)v).ToString("R", Inv);
        if (v is decimal) return ((decimal)v).ToString(Inv);
        return EscapeCopy(Convert.ToString(v, Inv));
    }

    public static long WritePgCopy(SqlDataReader r, string path, string[] tKinds)
    {
        long n = 0;
        using (var w = new StreamWriter(path, false, new UTF8Encoding(false), 1 << 20))
        {
            var sb = new StringBuilder();
            while (r.Read())
            {
                sb.Clear();
                for (int i = 0; i < tKinds.Length; i++) { if (i > 0) sb.Append('\t'); sb.Append(r.IsDBNull(i) ? "\\N" : PgText(r.GetValue(i), tKinds[i])); }
                sb.Append('\n');
                w.Write(sb.ToString());
                n++;
            }
        }
        return n;
    }

    // ---------------- PostgreSQL COPY text -> .NET value
    public static string Unescape(string f)
    {
        if (f == "\\N") return null;
        if (f.IndexOf('\\') < 0) return f;
        var sb = new StringBuilder(f.Length);
        for (int i = 0; i < f.Length; i++)
        {
            char c = f[i];
            if (c != '\\' || i == f.Length - 1) { sb.Append(c); continue; }
            char n = f[++i];
            switch (n)
            {
                case 'b': sb.Append('\b'); break;
                case 'f': sb.Append('\f'); break;
                case 'n': sb.Append('\n'); break;
                case 'r': sb.Append('\r'); break;
                case 't': sb.Append('\t'); break;
                case 'v': sb.Append('\v'); break;
                default: sb.Append(n); break;
            }
        }
        return sb.ToString();
    }

    static readonly string[] TsFormats = { "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss.FFFFFFF" };
    static readonly string[] TzFormats = { "yyyy-MM-dd HH:mm:sszz", "yyyy-MM-dd HH:mm:ss.FFFFFFFzz", "yyyy-MM-dd HH:mm:sszzz", "yyyy-MM-dd HH:mm:ss.FFFFFFFzzz" };

    public static object ParsePg(string s, string kind)
    {
        if (s == null) return DBNull.Value;
        switch (kind)
        {
            case "int": { long x; if (long.TryParse(s, NumberStyles.Integer, Inv, out x)) return x; return s; }
            case "dec": { decimal x; if (decimal.TryParse(s, NumberStyles.Float, Inv, out x)) return x; return s; }
            case "f8": { double x; if (double.TryParse(s, NumberStyles.Float, Inv, out x)) return x; return s; }
            case "f4": { float x; if (float.TryParse(s, NumberStyles.Float, Inv, out x)) return x; return s; }
            case "bool": return s == "t" || s == "true" || s == "1";
            case "date": { DateTime x; if (DateTime.TryParseExact(s, "yyyy-MM-dd", Inv, DateTimeStyles.None, out x)) return x; return s; }
            case "ts": { DateTime x; if (DateTime.TryParseExact(s, TsFormats, Inv, DateTimeStyles.None, out x)) return x; return s; }
            case "tstz": { DateTimeOffset x; if (DateTimeOffset.TryParseExact(s, TzFormats, Inv, DateTimeStyles.None, out x)) return x; return s; }
            case "time": { TimeSpan x; if (TimeSpan.TryParse(s, Inv, out x)) return x; return s; }
            case "uuid": { Guid x; if (Guid.TryParse(s, out x)) return x; return s; }
            case "bytes":
            {
                if (s.StartsWith("\\x"))
                {
                    int n = (s.Length - 2) / 2; var b = new byte[n];
                    for (int i = 0; i < n; i++) b[i] = Convert.ToByte(s.Substring(2 + i * 2, 2), 16);
                    return b;
                }
                return Encoding.UTF8.GetBytes(s);
            }
            default: return s;
        }
    }

    // Adjusts a value to the target SQL Server column kind.
    public static object ToTarget(object v, string tk)
    {
        if (v is DBNull) return v;
        switch (tk)
        {
            case "ts": case "date": if (v is DateTimeOffset) return ((DateTimeOffset)v).UtcDateTime; break;
            case "tstz": if (v is DateTime) return new DateTimeOffset(DateTime.SpecifyKind((DateTime)v, DateTimeKind.Utc)); break;
            case "bool": if (v is long) return (long)v != 0; break;
            case "int": if (v is bool) return (bool)v ? 1L : 0L; break;
            case "uuid": if (v is string) { Guid g; if (Guid.TryParse((string)v, out g)) return g; } break;
            case "str": if (!(v is string)) return Norm(v); break;
        }
        return v;
    }

    public static long LoadPgFile(string path, string[] sKinds, string[] tKinds, string[] cols, SqlBulkCopy bc, int batch)
    {
        var dt = new DataTable();
        foreach (var c in cols) dt.Columns.Add(c, typeof(object));
        long n = 0;
        using (var rd = new StreamReader(path, new UTF8Encoding(false)))
        {
            string line;
            while ((line = rd.ReadLine()) != null)
            {
                var f = line.Split('\t');
                var row = dt.NewRow();
                for (int i = 0; i < cols.Length; i++) row[i] = ToTarget(ParsePg(Unescape(f[i]), sKinds[i]), tKinds[i]);
                dt.Rows.Add(row); n++;
                if (dt.Rows.Count >= batch) { bc.WriteToServer(dt); dt.Clear(); }
            }
        }
        if (dt.Rows.Count > 0) bc.WriteToServer(dt);
        return n;
    }

    // ---------------- row fingerprints: key -> hash of all values (keyCount = 0: multiset of rows)
    static void AddRow(Dictionary<string, string> d, MD5 md5, string key, StringBuilder all, int keyCount)
    {
        string h = Convert.ToBase64String(md5.ComputeHash(Encoding.UTF8.GetBytes(all.ToString())));
        if (keyCount > 0) { d[key] = h; return; }
        int k = 1; while (d.ContainsKey(h + "#" + k)) k++;
        d[h + "#" + k] = h;
    }

    public static Dictionary<string, string> HashReader(SqlDataReader r, int keyCount)
    {
        var d = new Dictionary<string, string>(StringComparer.Ordinal);
        var md5 = MD5.Create(); var all = new StringBuilder(); var key = new StringBuilder();
        while (r.Read())
        {
            all.Clear(); key.Clear();
            for (int i = 0; i < r.FieldCount; i++)
            {
                string s = Norm(r.GetValue(i));
                if (i < keyCount) { if (i > 0) key.Append('|'); key.Append(s); }
                all.Append(s).Append('\u001f');
            }
            AddRow(d, md5, key.ToString(), all, keyCount);
        }
        return d;
    }

    public static Dictionary<string, string> HashPgFile(string path, string[] kinds, int keyCount)
    {
        var d = new Dictionary<string, string>(StringComparer.Ordinal);
        var md5 = MD5.Create(); var all = new StringBuilder(); var key = new StringBuilder();
        using (var rd = new StreamReader(path, new UTF8Encoding(false)))
        {
            string line;
            while ((line = rd.ReadLine()) != null)
            {
                var f = line.Split('\t');
                all.Clear(); key.Clear();
                for (int i = 0; i < kinds.Length; i++)
                {
                    string s = Norm(ParsePg(Unescape(f[i]), kinds[i]));
                    if (i < keyCount) { if (i > 0) key.Append('|'); key.Append(s); }
                    all.Append(s).Append('\u001f');
                }
                AddRow(d, md5, key.ToString(), all, keyCount);
            }
        }
        return d;
    }
}
"@
}

# ================================================================ type and default translation

function Get-MsKind([string]$t) {
    switch -regex ($t) {
        '^(bigint|int|smallint|tinyint)$' { return "int" }
        '^(decimal|numeric|money|smallmoney)$' { return "dec" }
        '^float$' { return "f8" }
        '^real$' { return "f4" }
        '^bit$' { return "bool" }
        '^date$' { return "date" }
        '^(datetime|datetime2|smalldatetime)$' { return "ts" }
        '^datetimeoffset$' { return "tstz" }
        '^time$' { return "time" }
        '^uniqueidentifier$' { return "uuid" }
        '^(binary|varbinary|image|timestamp|hierarchyid|geography|geometry)$' { return "bytes" }
        default { return "str" }
    }
}
function Get-PgKind([string]$t) {
    switch -regex ($t) {
        '^(int2|int4|int8|oid)$' { return "int" }
        '^(numeric|money)$' { return "dec" }
        '^float4$' { return "f4" }
        '^float8$' { return "f8" }
        '^bool$' { return "bool" }
        '^date$' { return "date" }
        '^timestamp$' { return "ts" }
        '^timestamptz$' { return "tstz" }
        '^time$' { return "time" }
        '^uuid$' { return "uuid" }
        '^bytea$' { return "bytes" }
        default { return "str" }
    }
}
# SELECT expression that reads a column in a form the copier understands.
function Get-MsSel($c) {
    if ($c.Type -in 'hierarchyid', 'geography', 'geometry') { return "CAST(" + (QN $c.Name) + " AS varbinary(max))" }
    if ($c.Type -eq 'sql_variant') { return "CAST(" + (QN $c.Name) + " AS nvarchar(4000))" }
    return (QN $c.Name)
}
function Get-PgSel($c) {
    if ($c.Type -eq 'money') { return (PgQN $c.Name) + "::numeric" }
    if ((Get-PgKind $c.Type) -eq 'str' -and $c.Type -notin 'text', 'varchar', 'bpchar', 'name', 'citext', 'xml', 'json', 'jsonb') { return (PgQN $c.Name) + "::text" }
    return (PgQN $c.Name)
}

# SQL Server column -> PostgreSQL. Returns @{ TypeSql; Kind; Note }
function Convert-MsTypeToPg($c) {
    $t = $c.Type; $note = $null
    $sc = [Math]::Min([int]$c.Scale, 6)
    switch -regex ($t) {
        '^bigint$' { $ty = "bigint" }
        '^int$' { $ty = "integer" }
        '^(smallint|tinyint)$' { $ty = "smallint" }
        '^bit$' { $ty = "boolean" }
        '^(decimal|numeric)$' { $ty = "numeric($($c.Prec),$($c.Scale))" }
        '^money$' { $ty = "numeric(19,4)" }
        '^smallmoney$' { $ty = "numeric(10,4)" }
        '^float$' { $ty = "double precision" }
        '^real$' { $ty = "real" }
        '^date$' { $ty = "date" }
        '^datetime$' { $ty = "timestamp(3)" }
        '^smalldatetime$' { $ty = "timestamp(0)" }
        '^datetime2$' { $ty = "timestamp($sc)"; if ($c.Scale -gt 6) { $note = "datetime2($($c.Scale)) -> timestamp(6): values are rounded to microseconds" } }
        '^datetimeoffset$' { $ty = "timestamptz($sc)"; $note = "datetimeoffset -> timestamptz: PostgreSQL stores the moment in UTC and doesn't keep the original offset" }
        '^time$' { $ty = "time($sc)" }
        '^n?char$' { $len = if ($t -eq 'nchar') { $c.MaxLen / 2 } else { $c.MaxLen }; $ty = "character($len)" }
        '^n?varchar$' { if ($c.MaxLen -eq -1) { $ty = "text" } else { $len = if ($t -eq 'nvarchar') { $c.MaxLen / 2 } else { $c.MaxLen }; $ty = "varchar($len)" } }
        '^n?text$' { $ty = "text" }
        '^xml$' { $ty = "xml" }
        '^uniqueidentifier$' { $ty = "uuid" }
        '^(binary|varbinary|image|timestamp)$' { $ty = "bytea" }
        '^(hierarchyid|geography|geometry)$' { $ty = "bytea"; $note = "$t is copied as raw bytes (bytea)" }
        '^sql_variant$' { $ty = "text"; $note = "sql_variant is copied as text" }
        default { $ty = "text"; $note = "unknown type $t copied as text" }
    }
    if ($c.Identity -and $t -in 'decimal', 'numeric') { $ty = "bigint" }
    return @{ TypeSql = $ty; Kind = (Get-PgKind ($ty -replace '\(.*$', '' -replace '^integer$', 'int4' -replace '^bigint$', 'int8' -replace '^smallint$', 'int2' -replace '^boolean$', 'bool' -replace '^double precision$', 'float8' -replace '^real$', 'float4' -replace '^timestamptz$', 'timestamptz' -replace '^character$', 'bpchar')); Note = $note }
}

# PostgreSQL column -> SQL Server. $isKey: used in a primary key / index / foreign key (no (max) types there).
function Convert-PgTypeToMs($c, [bool]$isKey) {
    $t = $c.Type; $ts = $c.TypeSql; $note = $null
    $len = if ($ts -match '\((\d+)\)') { [int]$Matches[1] } else { $null }
    switch -regex ($t) {
        '^int2$' { $ty = "smallint" }
        '^int4$' { $ty = "int" }
        '^(int8|oid)$' { $ty = "bigint" }
        '^numeric$' {
            if ($ts -match 'numeric\((\d+),(\d+)\)') { $p = [Math]::Min([int]$Matches[1], 38); $s = [Math]::Min([int]$Matches[2], $p); $ty = "decimal($p,$s)"; if ([int]$Matches[1] -gt 38) { $note = "numeric precision $($Matches[1]) reduced to 38" } }
            else { $ty = "decimal(38,10)"; $note = "numeric without precision -> decimal(38,10): values with more than 10 decimals are rounded" }
        }
        '^float4$' { $ty = "real" }
        '^float8$' { $ty = "float" }
        '^money$' { $ty = "money" }
        '^bool$' { $ty = "bit" }
        '^date$' { $ty = "date" }
        '^timestamp$' { $ty = "datetime2($(if ($null -ne $len) { [Math]::Min($len, 7) } else { 6 }))" }
        '^timestamptz$' { $ty = "datetimeoffset($(if ($null -ne $len) { [Math]::Min($len, 7) } else { 6 }))" }
        '^time$' { $ty = "time($(if ($null -ne $len) { [Math]::Min($len, 7) } else { 6 }))" }
        '^timetz$' { $ty = "nvarchar(50)"; $note = "time with time zone copied as text" }
        '^interval$' { $ty = "nvarchar(100)"; $note = "interval copied as text" }
        '^varchar$' { if ($null -ne $len -and $len -le 4000) { $ty = "nvarchar($len)" } elseif ($isKey) { $ty = "nvarchar(450)" } else { $ty = "nvarchar(max)" } }
        '^bpchar$' { if ($null -ne $len -and $len -le 4000) { $ty = "nchar($len)" } else { $ty = "nvarchar(max)" } }
        '^(text|citext|name)$' { if ($isKey) { $ty = "nvarchar(450)"; $note = "text used in a key -> nvarchar(450)" } else { $ty = "nvarchar(max)" } }
        '^uuid$' { $ty = "uniqueidentifier" }
        '^bytea$' { if ($isKey) { $ty = "varbinary(900)" } else { $ty = "varbinary(max)" } }
        '^(json|jsonb)$' { $ty = "nvarchar(max)"; $note = "$t copied as text (nvarchar(max))" }
        '^xml$' { $ty = "xml" }
        '^(inet|cidr|macaddr|macaddr8)$' { $ty = "nvarchar(64)" }
        default {
            $ty = if ($isKey) { "nvarchar(450)" } else { "nvarchar(max)" }
            $note = $(if ($t.StartsWith("_")) { "array type $ts copied as text" } else { "type $ts copied as text" })
        }
    }
    return @{ TypeSql = $ty; Kind = (Get-MsKind ($ty -replace '\(.*$', '')); Note = $note }
}

function Remove-OuterParens([string]$s) {
    $s = $s.Trim()
    while ($s.StartsWith("(") -and $s.EndsWith(")")) {
        $depth = 0; $ok = $true
        for ($i = 0; $i -lt $s.Length - 1; $i++) { if ($s[$i] -eq '(') { $depth++ } elseif ($s[$i] -eq ')') { $depth--; if ($depth -eq 0) { $ok = $false; break } } }
        if (-not $ok) { break }
        $s = $s.Substring(1, $s.Length - 2).Trim()
    }
    return $s
}

# Returns the translated default, or $null (with a note) if it can't be translated.
function Convert-MsDefaultToPg([string]$def, [string]$pgType) {
    $d = Remove-OuterParens $def
    if ($d -match '^-?\d+(\.\d+)?$') { if ($pgType -eq 'boolean') { return $(if ([double]$d -ne 0) { "true" } else { "false" }) } else { return $d } }
    if ($d -match "^N?'((?:[^']|'')*)'$") { return "'" + $Matches[1] + "'" }
    if ($d -match '^(getdate|getutcdate|sysdatetime|sysutcdatetime|sysdatetimeoffset|current_timestamp)(\(\))?$') { if ($pgType -eq 'date') { return "CURRENT_DATE" } else { return "now()" } }
    if ($d -match '^(newid|newsequentialid)\(\)$') { return "gen_random_uuid()" }
    if ($d -match '^convert\(\[?bit\]?,\s*\(?([01])\)?\)$') { return $(if ($Matches[1] -eq '1') { "true" } else { "false" }) }
    return $null
}
function Convert-PgDefaultToMs([string]$def, [string]$msType) {
    $d = $def.Trim()
    $d = [regex]::Replace($d, "::[a-zA-Z_ \[\]""\.]+(\(\d+(,\d+)?\))?(\[\])?$", "")
    $d = Remove-OuterParens $d
    if ($d -match '^(true|false)$') { return $(if ($d -eq 'true') { "((1))" } else { "((0))" }) }
    if ($d -match '^-?\d+(\.\d+)?$') { return "(($d))" }
    if ($d -match "^'((?:[^']|'')*)'$") { return "(N'" + $Matches[1] + "')" }
    if ($d -match '^(now\(\)|current_timestamp|localtimestamp|statement_timestamp\(\)|transaction_timestamp\(\)|timezone\(.*now\(\)\))$') {
        if ($msType -like 'datetimeoffset*') { return "(sysdatetimeoffset())" }
        if ($msType -eq 'date') { return "(CONVERT(date, getdate()))" }
        return "(sysdatetime())"
    }
    if ($d -match '^current_date$') { return "(CONVERT(date, getdate()))" }
    if ($d -match '^(gen_random_uuid|uuid_generate_v4)\(\)$') { return "(newid())" }
    return $null
}

# ================================================================ reading both sides

function Get-NameKey([string]$n) { return ($n.ToLower() -replace '[_\s]', '') }

function Get-SideIndexes($side) {
    $list = @()
    if ($side.Engine -eq "mssql") {
        $rows = Invoke-Query $side.Cs @"
SELECT s.name AS S, t.name AS T, i.name AS I, i.is_unique AS U, i.filter_definition AS F, c.name AS C, ic.is_descending_key AS Dsc, ic.is_included_column AS Inc
FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = i.object_id AND c.column_id = ic.column_id
WHERE t.is_ms_shipped = 0 AND i.is_primary_key = 0 AND i.type IN (1, 2) AND i.is_hypothetical = 0
ORDER BY s.name, t.name, i.name, ic.is_included_column, ic.key_ordinal, ic.index_column_id
"@
        foreach ($g in ($rows.Rows | Group-Object { "$($_.S)|$($_.T)|$($_.I)" })) {
            $f = $g.Group[0]
            $list += [pscustomobject]@{ Table = "$($f.S).$($f.T)"; Name = $f.I; Unique = [bool]$f.U; Partial = [bool](NZ $f.F); Filter = (NZ $f.F); Expr = $false
                Cols = @($g.Group | Where-Object { -not $_.Inc } | ForEach-Object { $_.C }); Desc = @($g.Group | Where-Object { -not $_.Inc } | ForEach-Object { [bool]$_.Dsc })
                Include = @($g.Group | Where-Object { $_.Inc } | ForEach-Object { $_.C }) }
        }
    }
    else {
        $rows = Invoke-PgQuery $side.Pg @"
SELECT n.nspname, t.relname, i.relname, ix.indisunique, ix.indnkeyatts,
       array_to_string(ARRAY(SELECT COALESCE(a.attname, '') FROM unnest(ix.indkey) WITH ORDINALITY k(attnum, ord) LEFT JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum ORDER BY k.ord), chr(31)),
       ix.indexprs IS NOT NULL, ix.indpred IS NOT NULL, ix.indoption::text, COALESCE(pg_get_expr(ix.indpred, ix.indrelid), '')
FROM pg_index ix JOIN pg_class t ON t.oid = ix.indrelid JOIN pg_class i ON i.oid = ix.indexrelid JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE NOT ix.indisprimary AND $PgUserSchemas;
"@
        foreach ($r in $rows) {
            $all = @($r[5].Split([char]31)); $nk = [int]$r[4]
            $opts = @($r[8].Split(' ') | Where-Object { $_ } | ForEach-Object { ([int]$_ -band 1) -eq 1 })
            $list += [pscustomobject]@{ Table = "$($r[0]).$($r[1])"; Name = $r[2]; Unique = ($r[3] -eq 't'); Partial = ($r[7] -eq 't'); Filter = $r[9]; Expr = ($r[6] -eq 't' -or ($all -contains ''))
                Cols = @($all | Select-Object -First $nk); Desc = @($opts | Select-Object -First $nk); Include = @($all | Select-Object -Skip $nk) }
        }
    }
    return , $list
}

function Get-SideFks($side) {
    $list = @()
    if ($side.Engine -eq "mssql") {
        foreach ($fk in $side.Meta.Fks) {
            $cc = @([regex]::Matches($fk.ChildCols, '\[((?:[^\]]|\]\])+)\]') | ForEach-Object { $_.Groups[1].Value.Replace(']]', ']') })
            $pc = @([regex]::Matches($fk.ParentCols, '\[((?:[^\]]|\]\])+)\]') | ForEach-Object { $_.Groups[1].Value.Replace(']]', ']') })
            $list += [pscustomobject]@{ Name = $fk.Name; Child = $fk.Child; Parent = $fk.Parent; ChildCols = $cc; ParentCols = $pc; OnDel = $fk.OnDel.Replace('_', ' '); OnUpd = $fk.OnUpd.Replace('_', ' ') }
        }
    }
    else {
        $act = @{ a = "NO ACTION"; r = "NO ACTION"; c = "CASCADE"; n = "SET NULL"; d = "SET DEFAULT" }
        $rows = Invoke-PgQuery $side.Pg @"
SELECT con.conname, cn.nspname || '.' || cc.relname, pn.nspname || '.' || pc.relname,
       array_to_string(ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(n, o) JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.n ORDER BY k.o), chr(31)),
       array_to_string(ARRAY(SELECT a.attname FROM unnest(con.confkey) WITH ORDINALITY k(n, o) JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.n ORDER BY k.o), chr(31)),
       con.confdeltype, con.confupdtype
FROM pg_constraint con
JOIN pg_class cc ON cc.oid = con.conrelid JOIN pg_namespace cn ON cn.oid = cc.relnamespace
JOIN pg_class pc ON pc.oid = con.confrelid JOIN pg_namespace pn ON pn.oid = pc.relnamespace
WHERE con.contype = 'f';
"@
        foreach ($r in $rows) {
            $list += [pscustomobject]@{ Name = $r[0]; Child = $r[1]; Parent = $r[2]; ChildCols = @($r[3].Split([char]31)); ParentCols = @($r[4].Split([char]31)); OnDel = $act[$r[5]]; OnUpd = $act[$r[6]] }
        }
    }
    return , $list
}

function Get-SideModules($side) {
    if ($side.Engine -eq "mssql") {
        return @((Invoke-Query $side.Cs "SELECT CAST(o.type_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT + N' ' + SCHEMA_NAME(o.schema_id) + N'.' + o.name AS N FROM sys.objects o WHERE o.is_ms_shipped = 0 AND o.type IN ('V','P','FN','IF','TF','TR') ORDER BY 1").Rows | ForEach-Object { $_.N })
    }
    return @((Invoke-PgQuery $side.Pg @"
SELECT 'VIEW ' || n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('v','m') AND $PgUserSchemas
UNION ALL SELECT 'FUNCTION ' || n.nspname || '.' || p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE $PgUserSchemas AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
UNION ALL SELECT 'TRIGGER ' || t.tgname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE NOT t.tgisinternal AND $PgUserSchemas;
"@) | ForEach-Object { $_[0] })
}

function Open-Side([string]$label, $conn) {
    $engine = Get-DbEngine $conn.ConnectionString
    Write-Host "  Reading $label ($($conn.Name), $(Get-EngineLabel $engine))..."
    $err = Test-DbConnection $conn.ConnectionString
    if ($err) { throw "Can't connect to $($conn.Name): $err" }
    $side = [pscustomobject]@{ Label = $label; Name = $conn.Name; Conn = $conn; Cs = $conn.ConnectionString; Engine = $engine; Pg = $null; Meta = $null; Indexes = @(); Fks = @(); Modules = @() }
    if ($engine -eq "pg") { $side.Pg = Get-PgConn $conn.ConnectionString; $side.Meta = Get-PgMeta $conn.ConnectionString }
    else { $side.Meta = Get-DbMeta $conn.ConnectionString }
    $side.Indexes = Get-SideIndexes $side
    $side.Fks = Get-SideFks $side
    $side.Modules = Get-SideModules $side
    return $side
}

function TQ($side, [string]$schema, [string]$name) { if ($side.Engine -eq "pg") { return (PgQN $schema) + "." + (PgQN $name) } else { return (QN $schema) + "." + (QN $name) } }
function CQ($side, [string]$name) { if ($side.Engine -eq "pg") { return PgQN $name } else { return QN $name } }

# ================================================================ planning

# One entry per source table: where it goes and how each column is read/written.
function New-CreatePlan($src, $tgt, $notes) {
    $pairs = @()
    $keyCols = @{}   # "table|column" used in PK / index / FK (no (max) types allowed there in SQL Server)
    foreach ($t in $src.Meta.Tables.Values) { foreach ($k in $t.Pk) { $keyCols["$($t.Full)|$k"] = $true } }
    foreach ($ix in $src.Indexes) { foreach ($k in @($ix.Cols) + @($ix.Include)) { $keyCols["$($ix.Table)|$k"] = $true } }
    foreach ($fk in $src.Fks) { foreach ($k in $fk.ChildCols) { $keyCols["$($fk.Child)|$k"] = $true }; foreach ($k in $fk.ParentCols) { $keyCols["$($fk.Parent)|$k"] = $true } }

    foreach ($full in ($src.Meta.Tables.Keys | Sort-Object)) {
        $s = $src.Meta.Tables[$full]
        $tSchema = if ($tgt.Engine -eq "pg" -and $s.Schema -eq "dbo") { "public" } elseif ($tgt.Engine -eq "mssql" -and $s.Schema -eq "public") { "dbo" } else { $s.Schema }
        $existing = $tgt.Meta.Tables.Values | Where-Object { (Get-NameKey $_.Name) -eq (Get-NameKey $s.Name) -and (Get-NameKey $_.Schema) -eq (Get-NameKey $tSchema) } | Select-Object -First 1
        $ordered = @(@($s.Pk | ForEach-Object { $s.Col[$_] }) + @($s.Columns | Where-Object { $s.Pk -notcontains $_.Name }))
        $cols = @()
        foreach ($c in $ordered) {
            $isKey = [bool]$keyCols["$full|$($c.Name)"]
            if ($src.Engine -eq "mssql") {
                $m = Convert-MsTypeToPg $c
                $def = $null
                if ($c.Default) { $def = Convert-MsDefaultToPg $c.Default $m.TypeSql; if (-not $def) { $notes.Add("$full.$($c.Name): default $($c.Default) not translated - add it by hand if needed") } }
                $ident = $c.Identity -and $m.TypeSql -in 'integer', 'bigint', 'smallint'
                $sKind = Get-MsKind $c.Type; $sSel = Get-MsSel $c
            }
            else {
                $m = Convert-PgTypeToMs $c $isKey
                $def = $null
                $ident = ($c.Identity -or $c.Default -match '^nextval\(') -and $c.Type -in 'int2', 'int4', 'int8'
                if ($c.Default -and $c.Default -notmatch '^nextval\(') { $def = Convert-PgDefaultToMs $c.Default $m.TypeSql; if (-not $def) { $notes.Add("$full.$($c.Name): default $($c.Default) not translated - add it by hand if needed") } }
                $sKind = Get-PgKind $c.Type; $sSel = Get-PgSel $c
            }
            if ($m.Note) { $notes.Add("$full.$($c.Name): $($m.Note)") }
            if ($c.Computed) { $notes.Add("$full.$($c.Name): computed/generated column copied as a normal column (formula not translated)") }
            $cols += [pscustomobject]@{ S = $c.Name; T = $c.Name; SSel = $sSel; SKind = $sKind; TKind = $m.Kind; TypeSql = $m.TypeSql; Nullable = $c.Nullable; Identity = $ident; IdentityAlways = $false; Default = $def }
        }
        $pairs += [pscustomobject]@{ Src = $s; SrcFull = $full; TSchema = $tSchema; TName = $s.Name; TFull = "$tSchema.$($s.Name)"; Existing = $existing; Cols = $cols; KeyCount = $s.Pk.Count; PkName = $s.PkName; Skip = $false; Note = "" }
    }
    return , $pairs
}

function New-ExistingPlan($src, $tgt, $notes) {
    $pairs = @()
    foreach ($full in ($src.Meta.Tables.Keys | Sort-Object)) {
        $s = $src.Meta.Tables[$full]
        $cands = @($tgt.Meta.Tables.Values | Where-Object { (Get-NameKey $_.Name) -eq (Get-NameKey $s.Name) })
        if ($cands.Count -gt 1) { $pref = @($cands | Where-Object { $_.Schema -in 'dbo', 'public' }); if ($pref.Count -eq 1) { $cands = $pref } }
        if ($cands.Count -ne 1) {
            $pairs += [pscustomobject]@{ Src = $s; SrcFull = $full; TSchema = $null; TName = $null; TFull = $null; Existing = $null; Cols = @(); KeyCount = 0; PkName = $null; Skip = $true; Note = $(if ($cands.Count) { "several matching tables in target" } else { "no matching table in target" }) }
            continue
        }
        $t = $cands[0]
        $tPkKeys = @($t.Pk | ForEach-Object { Get-NameKey $_ })
        $sPkKeys = @($s.Pk | ForEach-Object { Get-NameKey $_ })
        $keyOk = $s.Pk.Count -gt 0 -and ($sPkKeys -join ',') -eq ($tPkKeys -join ',')
        $ordered = @(@($s.Pk | ForEach-Object { $s.Col[$_] }) + @($s.Columns | Where-Object { $s.Pk -notcontains $_.Name }))
        $cols = @(); $missing = @()
        foreach ($c in $ordered) {
            if ($c.Computed) { continue }
            $tc = $t.Columns | Where-Object { (Get-NameKey $_.Name) -eq (Get-NameKey $c.Name) } | Select-Object -First 1
            if (-not $tc) { $missing += $c.Name; continue }
            if ($tc.Computed -or ($tc.Type -eq 'timestamp' -and $tgt.Engine -eq 'mssql')) { continue }
            $sKind = if ($src.Engine -eq "mssql") { Get-MsKind $c.Type } else { Get-PgKind $c.Type }
            $tKind = if ($tgt.Engine -eq "mssql") { Get-MsKind $tc.Type } else { Get-PgKind $tc.Type }
            $sSel = if ($src.Engine -eq "mssql") { Get-MsSel $c } else { Get-PgSel $c }
            $tIdent = $tc.Identity -or ($tgt.Engine -eq "pg" -and $tc.Default -match '^nextval\(')
            $cols += [pscustomobject]@{ S = $c.Name; T = $tc.Name; SSel = $sSel; SKind = $sKind; TKind = $tKind; TypeSql = $null; Nullable = $tc.Nullable; Identity = $tIdent; IdentityAlways = [bool]($tc.PSObject.Properties['IdentityAlways'] -and $tc.IdentityAlways); Default = $null }
        }
        if ($missing.Count) { $notes.Add("$full -> $($t.Full): source column(s) not in target, not copied: $($missing -join ', ')") }
        $mapped = @($cols | ForEach-Object { Get-NameKey $_.T })
        $required = @($t.Columns | Where-Object { $mapped -notcontains (Get-NameKey $_.Name) -and -not $_.Nullable -and -not $_.Default -and -not $_.Identity -and -not $_.Computed })
        $p = [pscustomobject]@{ Src = $s; SrcFull = $full; TSchema = $t.Schema; TName = $t.Name; TFull = $t.Full; Existing = $t; Cols = $cols; KeyCount = $(if ($keyOk) { $s.Pk.Count } else { 0 }); PkName = $null; Skip = $false; Note = "" }
        if ($required.Count) { $p.Skip = $true; $p.Note = "target requires column(s) the source doesn't have: $(($required | ForEach-Object Name) -join ', ')" }
        elseif (-not $keyOk) { $p.Note = "primary keys don't match - only 'replace' works and rows are checked without keys" }
        $pairs += $p
    }
    return , $pairs
}

# ================================================================ DDL for the target

# Translates a simple index filter ("[Col] IS NOT NULL AND [X] = 1" / "(""col"" IS NOT NULL)") between dialects, or returns $null.
function Convert-IndexFilter([string]$filter, [string]$toEngine) {
    $f = $filter -replace '::[a-zA-Z_ ]+', ''
    $ident = '(\[[^\]]+\]|"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)'
    $atom = "\(*\s*$ident\s*(IS\s+NOT\s+NULL|IS\s+NULL|(=|<>|!=|<|>|<=|>=)\s*(-?\d+(\.\d+)?|N?'[^']*'|true|false))\s*\)*"
    if ($f -notmatch "^\s*$atom(\s+(AND|OR)\s+$atom)*\s*$") { return $null }
    if ($toEngine -eq "pg") { return ([regex]::Replace($f, '\[([^\]]+)\]', { param($m) PgQN $m.Groups[1].Value }) -replace "N'", "'") }
    $f = [regex]::Replace($f, '"([^"]+)"', { param($m) QN $m.Groups[1].Value })
    return ($f -replace '(?i)\btrue\b', '1' -replace '(?i)\bfalse\b', '0')
}

function Get-UniqueName($used, [string]$name, [string]$table) {
    $n = $name
    if ($used.Contains($n.ToLower())) { $n = "${name}_$table" }
    $i = 2; while ($used.Contains($n.ToLower())) { $n = "${name}_$i"; $i++ }
    [void]$used.Add($n.ToLower())
    return $n
}

function Get-CreateDdl($pairs, $src, $tgt, $notes) {
    $pre = New-Object System.Collections.Generic.List[string]    # schemas + tables (before data)
    $post = New-Object System.Collections.Generic.List[string]   # indexes + foreign keys (after data)
    $used = [System.Collections.Generic.HashSet[string]]::new()
    $byFull = @{}; foreach ($p in $pairs) { if (-not $p.Skip) { $byFull[$p.SrcFull] = $p } }
    foreach ($sch in ($byFull.Values | ForEach-Object { $_.TSchema } | Sort-Object -Unique)) {
        if ($tgt.Meta.Schemas[$sch]) { continue }
        if ($tgt.Engine -eq "pg") { $pre.Add("CREATE SCHEMA IF NOT EXISTS " + (PgQN $sch) + ";") }
        else { $pre.Add("IF SCHEMA_ID(" + (SqlStr $sch) + ") IS NULL EXEC(N'CREATE SCHEMA " + (QN $sch).Replace("'", "''") + "');") }
    }
    foreach ($p in ($byFull.Values | Sort-Object TFull)) {
        $lines = foreach ($c in $p.Cols) {
            $x = "    " + (CQ $tgt $c.T) + " " + $c.TypeSql
            if ($c.Identity) { if ($tgt.Engine -eq "pg") { $x += " GENERATED BY DEFAULT AS IDENTITY" } else { $x += " IDENTITY(1,1)" } }
            if ($c.Nullable -and -not ($p.Src.Pk -contains $c.S)) { $x += $(if ($tgt.Engine -eq "mssql") { " NULL" } else { "" }) } else { $x += " NOT NULL" }
            if ($c.Default -and -not $c.Identity) { $x += " DEFAULT " + $c.Default }
            $x
        }
        $lines = @($lines)
        if ($p.KeyCount) {
            $pk = Get-UniqueName $used $(if ($p.PkName) { $p.PkName } else { "PK_$($p.TName)" }) $p.TName
            $lines += "    CONSTRAINT " + (CQ $tgt $pk) + " PRIMARY KEY (" + (($p.Src.Pk | ForEach-Object { CQ $tgt $_ }) -join ", ") + ")"
        }
        $pre.Add("CREATE TABLE " + (TQ $tgt $p.TSchema $p.TName) + " (`n" + ($lines -join ",`n") + "`n);")
    }
    foreach ($ix in $src.Indexes) {
        $p = $byFull[$ix.Table]; if (-not $p) { continue }
        if ($ix.Expr) { $notes.Add("$($ix.Table): index $($ix.Name) uses an expression - not copied"); continue }
        $name = Get-UniqueName $used $ix.Name $p.TName
        $cols = for ($i = 0; $i -lt $ix.Cols.Count; $i++) { (CQ $tgt $ix.Cols[$i]) + $(if ($ix.Desc[$i]) { " DESC" } else { "" }) }
        $sql = "CREATE " + $(if ($ix.Unique) { "UNIQUE " } else { "" }) + "INDEX " + (CQ $tgt $name) + " ON " + (TQ $tgt $p.TSchema $p.TName) + " (" + (@($cols) -join ", ") + ")"
        if ($ix.Include.Count) { $sql += " INCLUDE (" + (($ix.Include | ForEach-Object { CQ $tgt $_ }) -join ", ") + ")" }
        $where = @()
        if ($ix.Partial) {
            $wf = Convert-IndexFilter $ix.Filter $tgt.Engine
            if ($wf) { $where += "($wf)" }
            elseif ($ix.Unique) { $notes.Add("$($ix.Table): unique index $($ix.Name) has a filter that can't be translated ($($ix.Filter)) - not copied"); continue }
            else { $notes.Add("$($ix.Table): index $($ix.Name) has a filter that can't be translated - copied without it") }
        }
        # NULL handling of unique indexes differs: SQL Server allows one NULL, PostgreSQL many.
        if ($ix.Unique -and $tgt.Engine -eq "mssql") {
            $nullable = @($ix.Cols | Where-Object { $p.Src.Col[$_].Nullable })
            if ($nullable.Count) { $where += (($nullable | ForEach-Object { (QN $_) + " IS NOT NULL" }) -join " AND ") }
        }
        if ($where.Count) { $sql += " WHERE " + ($where -join " AND ") }
        $post.Add("$sql;")
    }
    foreach ($fk in $src.Fks) {
        $c = $byFull[$fk.Child]; $pa = $byFull[$fk.Parent]
        if (-not $c -or -not $pa) { continue }
        $name = Get-UniqueName $used $fk.Name $c.TName
        $post.Add("ALTER TABLE " + (TQ $tgt $c.TSchema $c.TName) + " ADD CONSTRAINT " + (CQ $tgt $name) + " FOREIGN KEY (" + (($fk.ChildCols | ForEach-Object { CQ $tgt $_ }) -join ", ") + ") REFERENCES " + (TQ $tgt $pa.TSchema $pa.TName) + " (" + (($fk.ParentCols | ForEach-Object { CQ $tgt $_ }) -join ", ") + ") ON DELETE $($fk.OnDel) ON UPDATE $($fk.OnUpd);")
    }
    return @{ Pre = $pre; Post = $post }
}

# ================================================================ moving data

function Get-SrcSelect($src, $p) { return "SELECT " + (($p.Cols | ForEach-Object { $_.SSel }) -join ", ") + " FROM " + (TQ $src $p.Src.Schema $p.Src.Name) }

# PostgreSQL: export several SELECTs to COPY text files in one psql session.
function Export-PgFiles($pg, $jobs) {
    if (-not @($jobs).Count) { return }
    $script = New-TempFile ".sql"
    $lines = @("SET TIME ZONE 'UTC';", "SET DateStyle = ISO;", "SET extra_float_digits = 3;", "SET IntervalStyle = iso_8601;")
    foreach ($j in $jobs) { $lines += "\copy (" + $j.Sql + ") TO '" + $j.File.Replace('\', '/').Replace("'", "''") + "'" }
    [IO.File]::WriteAllText($script, ($lines -join "`n") + "`n", $Utf8NoBom)
    try { [void](Invoke-PgScript $pg $script) } finally { Remove-Item $script -ErrorAction SilentlyContinue }
}

function Invoke-CopyToPg($src, $tgt, $pairs, $ddl, [string]$mode, [string]$work) {
    $active = @($pairs | Where-Object { -not $_.Skip })
    $sb = New-Object System.Collections.Generic.List[string]
    $sb.Add("SET client_encoding = 'UTF8';"); $sb.Add("SET TIME ZONE 'UTC';"); $sb.Add("BEGIN;")
    if ($ddl) { foreach ($s in $ddl.Pre) { $sb.Add($s) } }
    # read every source table into a COPY file
    $i = 0
    foreach ($p in $active) {
        $i++
        Write-Progress -Activity "Reading $($src.Name)" -Status "$($p.SrcFull) ($i of $($active.Count))" -PercentComplete ($i * 100 / $active.Count)
        $p | Add-Member -NotePropertyName File -NotePropertyValue (Join-Path $work "t$i.tsv") -Force
        $conn = New-Object System.Data.SqlClient.SqlConnection $src.Cs; $conn.Open()
        try {
            $cmd = $conn.CreateCommand(); $cmd.CommandTimeout = 0; $cmd.CommandText = Get-SrcSelect $src $p
            $r = $cmd.ExecuteReader()
            $n = [XEngine]::WritePgCopy($r, $p.File, [string[]]@($p.Cols | ForEach-Object { $_.TKind }))
            $r.Close()
        } finally { $conn.Close() }
        $p | Add-Member -NotePropertyName Rows -NotePropertyValue $n -Force
    }
    Write-Progress -Activity "Reading" -Completed
    $order = [string[]](Get-TableOrder $tgt.Meta @($active | Where-Object Existing | ForEach-Object { $_.Existing.Full }))
    if ($mode -eq "replace") {
        for ($j = $order.Count - 1; $j -ge 0; $j--) { $p = $active | Where-Object { $_.Existing -and $_.Existing.Full -eq $order[$j] }; $sb.Add("DELETE FROM " + (TQ $tgt $p.TSchema $p.TName) + ";") }
    }
    # parent tables first for existing tables (their foreign keys are already in place)
    $loadOrder = @($active | Sort-Object { $idx = [array]::IndexOf($order, $(if ($_.Existing) { $_.Existing.Full } else { "" })); if ($idx -lt 0) { 0 } else { $idx } })
    foreach ($p in $loadOrder) {
        $tq = TQ $tgt $p.TSchema $p.TName
        $cl = ($p.Cols | ForEach-Object { PgQN $_.T }) -join ", "
        $file = $p.File.Replace('\', '/').Replace("'", "''")
        $always = @($p.Cols | Where-Object IdentityAlways).Count -gt 0
        if ($mode -eq "add" -or $always) {
            $over = if (@($p.Cols | Where-Object Identity).Count) { " OVERRIDING SYSTEM VALUE" } else { "" }
            $sb.Add("CREATE TEMP TABLE _xcopy AS SELECT $cl FROM $tq WITH NO DATA;")
            $sb.Add("\copy _xcopy ($cl) FROM '$file'")
            $where = ""
            if ($mode -eq "add") { $where = " WHERE NOT EXISTS (SELECT 1 FROM $tq t WHERE " + ((@($p.Cols | Select-Object -First $p.KeyCount) | ForEach-Object { "t." + (PgQN $_.T) + " = s." + (PgQN $_.T) }) -join " AND ") + ")" }
            $sb.Add("INSERT INTO $tq ($cl)$over SELECT $cl FROM _xcopy s$where;")
            $sb.Add("DROP TABLE _xcopy;")
        }
        else { $sb.Add("\copy $tq ($cl) FROM '$file'") }
        foreach ($c in ($p.Cols | Where-Object Identity)) {
            $sb.Add("SELECT setval(pg_get_serial_sequence(" + (PgStr $tq) + ", " + (PgStr $c.T) + "), m) FROM (SELECT max(" + (PgQN $c.T) + ") AS m FROM $tq) x WHERE m IS NOT NULL;")
        }
    }
    if ($ddl) { foreach ($s in $ddl.Post) { $sb.Add($s) } }
    $sb.Add("COMMIT;")
    $script = Join-Path $work "load.sql"
    [IO.File]::WriteAllText($script, ($sb -join "`n") + "`n", $Utf8NoBom)
    Write-Host "  Writing to $($tgt.Name) in one transaction..."
    try { [void](Invoke-PgScript $tgt.Pg $script) }
    catch { throw "Copy failed and was rolled back - $($tgt.Name) is unchanged. Reason: $($_.Exception.Message)" }
}

function Invoke-CopyToMs($src, $tgt, $pairs, $ddl, [string]$mode, [string]$work) {
    $active = @($pairs | Where-Object { -not $_.Skip })
    $i = 0; $jobs = @()
    foreach ($p in $active) {
        $i++
        $p | Add-Member -NotePropertyName File -NotePropertyValue (Join-Path $work "t$i.tsv") -Force
        $jobs += @{ Sql = (Get-SrcSelect $src $p); File = $p.File }
    }
    Write-Host "  Reading $($src.Name)..."
    Export-PgFiles $src.Pg $jobs
    $conn = New-Object System.Data.SqlClient.SqlConnection $tgt.Cs; $conn.Open()
    $tx = $conn.BeginTransaction()
    try {
        function TxExec([string]$sql) { $cmd = $conn.CreateCommand(); $cmd.Transaction = $tx; $cmd.CommandTimeout = 0; $cmd.CommandText = $sql; return $cmd.ExecuteNonQuery() }
        if ($ddl) { foreach ($s in $ddl.Pre) { [void](TxExec $s) } }
        $order = [string[]](Get-TableOrder $tgt.Meta @($active | Where-Object Existing | ForEach-Object { $_.Existing.Full }))
        if ($mode -eq "replace") {
            for ($j = $order.Count - 1; $j -ge 0; $j--) { $p = $active | Where-Object { $_.Existing -and $_.Existing.Full -eq $order[$j] }; [void](TxExec ("DELETE FROM " + (TQ $tgt $p.TSchema $p.TName) + ";")) }
        }
        $loadOrder = @($active | Sort-Object { $idx = [array]::IndexOf($order, $(if ($_.Existing) { $_.Existing.Full } else { "" })); if ($idx -lt 0) { 0 } else { $idx } })
        $k = 0
        foreach ($p in $loadOrder) {
            $k++
            Write-Progress -Activity "Writing to $($tgt.Name)" -Status "$($p.TFull) ($k of $($loadOrder.Count))" -PercentComplete ($k * 100 / $loadOrder.Count)
            $tq = TQ $tgt $p.TSchema $p.TName
            $tcols = [string[]]@($p.Cols | ForEach-Object { $_.T })
            $hasId = @($p.Cols | Where-Object Identity).Count -gt 0
            $dest = $tq
            if ($mode -eq "add") {
                [void](TxExec ("SELECT TOP 0 " + (($tcols | ForEach-Object { QN $_ }) -join ", ") + " INTO #xcopy FROM $tq;"))
                $dest = "#xcopy"
            }
            $opt = [System.Data.SqlClient.SqlBulkCopyOptions]::KeepIdentity -bor [System.Data.SqlClient.SqlBulkCopyOptions]::KeepNulls
            if ($p.Existing -and $mode -ne "add") { $opt = $opt -bor [System.Data.SqlClient.SqlBulkCopyOptions]::CheckConstraints }
            $bc = [System.Data.SqlClient.SqlBulkCopy]::new($conn, $opt, $tx)
            try {
                $bc.DestinationTableName = $dest; $bc.BulkCopyTimeout = 0; $bc.BatchSize = 5000
                foreach ($c in $tcols) { [void]$bc.ColumnMappings.Add($c, $c) }
                $n = [XEngine]::LoadPgFile($p.File, [string[]]@($p.Cols | ForEach-Object { $_.SKind }), [string[]]@($p.Cols | ForEach-Object { $_.TKind }), $tcols, $bc, 5000)
            } finally { $bc.Close() }
            $p | Add-Member -NotePropertyName Rows -NotePropertyValue $n -Force
            if ($hasId -and $mode -ne "add" -and $n -gt 0) { [void](TxExec ("DBCC CHECKIDENT (" + (SqlStr $tq) + ", RESEED) WITH NO_INFOMSGS;")) }
            if ($mode -eq "add") {
                $cl = ($tcols | ForEach-Object { QN $_ }) -join ", "
                $on = (@($tcols | Select-Object -First $p.KeyCount) | ForEach-Object { "t." + (QN $_) + " = s." + (QN $_) }) -join " AND "
                $sql = "INSERT INTO $tq ($cl) SELECT $cl FROM #xcopy s WHERE NOT EXISTS (SELECT 1 FROM $tq t WHERE $on);"
                if ($hasId) { $sql = "SET IDENTITY_INSERT $tq ON; $sql SET IDENTITY_INSERT $tq OFF;" }
                [void](TxExec "$sql DROP TABLE #xcopy;")
                if ($hasId) { [void](TxExec ("DBCC CHECKIDENT (" + (SqlStr $tq) + ", RESEED) WITH NO_INFOMSGS;")) }
            }
        }
        Write-Progress -Activity "Writing" -Completed
        if ($ddl) {
            foreach ($s in $ddl.Post) {
                try { [void](TxExec $s) }
                catch {
                    if ($s -match 'FOREIGN KEY' -and $s -match 'ON (DELETE|UPDATE) (CASCADE|SET NULL|SET DEFAULT)') {
                        # SQL Server refuses some cascade paths that PostgreSQL allows: keep the key, drop the cascade.
                        $s2 = [regex]::Replace($s, 'ON DELETE [A-Z ]+ ON UPDATE [A-Z ]+;$', 'ON DELETE NO ACTION ON UPDATE NO ACTION;')
                        [void](TxExec $s2)
                        Write-Host "  Note: SQL Server doesn't allow this cascade, created without it: $(($s -split ' ADD CONSTRAINT ')[1].Split(' ')[0])" -ForegroundColor Yellow
                    }
                    else { throw }
                }
            }
        }
        $tx.Commit()
    }
    catch {
        try { $tx.Rollback() } catch { }
        throw "Copy failed and was rolled back - $($tgt.Name) is unchanged. Reason: $($_.Exception.Message)"
    }
    finally { $conn.Close() }
}

# ================================================================ verification

function Get-SideHashes($side, $p, [string]$which, [string]$work, [int]$n) {
    if ($which -eq "src") { $sels = @($p.Cols | ForEach-Object { $_.SSel }); $kinds = @($p.Cols | ForEach-Object { $_.SKind }); $from = TQ $side $p.Src.Schema $p.Src.Name }
    else {
        $tt = if ($p.Existing) { $p.Existing } else { $null }
        $sels = @($p.Cols | ForEach-Object {
                $tc = if ($tt) { $tt.Col[$_.T] } else { $null }
                if ($side.Engine -eq "pg") { if ($tc) { Get-PgSel $tc } elseif ($_.TKind -eq 'str' -and $_.TypeSql -notmatch '^(text|varchar|character|xml)') { (PgQN $_.T) + "::text" } else { PgQN $_.T } }
                else { if ($tc) { Get-MsSel $tc } else { QN $_.T } }
            })
        $kinds = @($p.Cols | ForEach-Object { $_.TKind }); $from = TQ $side $p.TSchema $p.TName
    }
    $sql = "SELECT " + ($sels -join ", ") + " FROM " + $from
    if ($side.Engine -eq "pg") {
        $f = Join-Path $work "v_${which}_$n.tsv"
        Export-PgFiles $side.Pg @(@{ Sql = $sql; File = $f })
        return , ([XEngine]::HashPgFile($f, [string[]]$kinds, $p.KeyCount))
    }
    $conn = New-Object System.Data.SqlClient.SqlConnection $side.Cs; $conn.Open()
    try { $cmd = $conn.CreateCommand(); $cmd.CommandTimeout = 0; $cmd.CommandText = $sql; $r = $cmd.ExecuteReader(); $d = [XEngine]::HashReader($r, $p.KeyCount); $r.Close(); return , $d }
    finally { $conn.Close() }
}

function Test-Copy($src, $tgt, $pairs, [string]$mode, [string]$work) {
    Write-Host ""
    Write-Host "Verifying every row..."
    $bad = 0; $n = 0; $total = 0
    $active = @($pairs | Where-Object { -not $_.Skip })
    foreach ($p in $active) {
        $n++
        Write-Progress -Activity "Verifying" -Status "$($p.SrcFull) ($n of $($active.Count))" -PercentComplete ($n * 100 / $active.Count)
        $hs = Get-SideHashes $src $p "src" $work $n
        $ht = Get-SideHashes $tgt $p "tgt" $work $n
        $missing = 0; $diff = 0; $extra = 0; $h = $null
        foreach ($k in $hs.Keys) { if ($ht.TryGetValue($k, [ref]$h)) { if ($h -ne $hs[$k]) { $diff++ } } else { $missing++ } }
        if ($mode -ne "add") { foreach ($k in $ht.Keys) { if (-not $hs.ContainsKey($k)) { $extra++ } } }
        $total += $hs.Count
        if ($missing + $diff + $extra) {
            $bad++
            Write-Host ("  {0,-40} {1} missing, {2} different, {3} extra" -f $p.TFull, $missing, $diff, $extra) -ForegroundColor Yellow
        }
    }
    Write-Progress -Activity "Verifying" -Completed
    if ($bad -eq 0) { Write-Host "  Verified: all $($active.Count) tables match ($total rows)." -ForegroundColor Green }
    else { Write-Host "  $bad table(s) differ - see above. If rows were added to the source meanwhile, that's expected." -ForegroundColor Yellow }
}

# ================================================================ main

function Invoke-CrossCopy {
    $sConn = Select-Connections "Copy FROM which database?" -Single
    if (-not $sConn) { return }
    $sEngine = Get-DbEngine $sConn.ConnectionString
    $tEngine = if ($sEngine -eq "pg") { "mssql" } else { "pg" }
    $tConn = Select-Connections "Copy TO which $(Get-EngineLabel $tEngine) database?" -Single -Engine $tEngine
    if (-not $tConn) { return }
    $cfg = Read-Config

    Write-Step "Reading both databases"
    $src = Open-Side "source" $sConn
    $tgt = Open-Side "target" $tConn
    Write-Host ("  Source {0}: {1} tables.  Target {2}: {3} tables." -f $src.Name, $src.Meta.Tables.Count, $tgt.Name, $tgt.Meta.Tables.Count)

    Write-Host ""
    Write-Host "How do you want to copy?" -ForegroundColor Yellow
    Write-Host "  1. Create the tables in $($tgt.Name) and copy the data   (target shouldn't have these tables yet)"
    Write-Host "  2. Copy the data into tables that already exist in $($tgt.Name)   (e.g. created by the app / EF migrations)"
    $m = Ask ">"
    $notes = New-Object System.Collections.Generic.List[string]
    $mode = "create"; $ddl = $null

    if ($m -eq "1") {
        $pairs = New-CreatePlan $src $tgt $notes
        $conflicts = @($pairs | Where-Object Existing)
        if ($conflicts.Count) {
            Write-Host ""
            Write-Host "$($conflicts.Count) of these tables already exist in $($tgt.Name):" -ForegroundColor Yellow
            $conflicts | Select-Object -First 15 | ForEach-Object { Write-Host "  $($_.Existing.Full)" }
            if ($conflicts.Count -gt 15) { Write-Host "  ..." }
            Write-Host "  1. Skip those tables"
            Write-Host "  2. Cancel (then use option 2 'copy into existing tables', or empty the target first)"
            if ((Ask ">") -ne "1") { Write-Host "Cancelled."; return }
            foreach ($c in $conflicts) { $c.Skip = $true; $c.Note = "already exists in target - skipped" }
        }
        $ddl = Get-CreateDdl $pairs $src $tgt $notes
    }
    elseif ($m -eq "2") {
        $pairs = New-ExistingPlan $src $tgt $notes
        Write-Host ""
        Write-Host "What should happen to the data already in those tables?" -ForegroundColor Yellow
        Write-Host "  1. Replace it  (delete all rows in the matched tables, then copy everything)"
        Write-Host "  2. Keep it, only add rows that are missing  (matched by primary key)"
        $mode = if ((Ask ">") -eq "2") { "add" } else { "replace" }
        if ($mode -eq "add") { foreach ($p in ($pairs | Where-Object { -not $_.Skip -and $_.KeyCount -eq 0 })) { $p.Skip = $true; $p.Note = "no matching primary key - can't tell which rows are missing" } }
    }
    else { Write-Host "Cancelled."; return }

    # ---- plan
    Write-Step "Plan: $($src.Name) ($(Get-EngineLabel $src.Engine)) -> $($tgt.Name) ($(Get-EngineLabel $tgt.Engine))"
    $pairs | ForEach-Object { [pscustomobject]@{ "Source table" = $_.SrcFull; "Target table" = $(if ($_.Skip) { "-" } else { $_.TFull }); Rows = $_.Src.Rows; Note = $(if ($_.Skip) { "SKIPPED: " + $_.Note } else { $_.Note }) } } |
        Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    $active = @($pairs | Where-Object { -not $_.Skip })
    if ($active.Count -eq 0) { Write-Host "Nothing to copy." -ForegroundColor Yellow; return }
    if ($ddl) { Write-Host ("  Will create {0} tables, then {1} indexes/foreign keys after the data." -f @($ddl.Pre | Where-Object { $_ -like 'CREATE TABLE*' }).Count, $ddl.Post.Count) }
    Write-Host ("  Mode: " + $(switch ($mode) { "create" { "create tables + copy" } "replace" { "replace the data in existing tables" } "add" { "add missing rows to existing tables" } }))
    if ($src.Modules.Count) {
        Write-Host ""
        Write-Host "Not copied (written in a different SQL dialect - recreate by hand if needed):" -ForegroundColor Yellow
        $src.Modules | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
        if ($src.Modules.Count -gt 20) { Write-Host "  ... ($($src.Modules.Count) in total)" }
    }
    if ($notes.Count) {
        Write-Host ""
        Write-Host "Things to know:" -ForegroundColor Yellow
        foreach ($g in ($notes | Group-Object { $x = $_ -split ': ', 2; if ($x.Count -gt 1) { $x[1] } else { $_ } } | Sort-Object Count -Descending)) {
            $where = @($g.Group | ForEach-Object { ($_ -split ': ', 2)[0] })
            $list = ($where | Select-Object -First 3) -join ", "; if ($where.Count -gt 3) { $list += ", ... ($($where.Count) in total)" }
            Write-Host "  - $($g.Name)"; Write-Host "      $list" -ForegroundColor DarkGray
        }
        Write-Host "  (full list in the report file)" -ForegroundColor DarkGray
    }
    if ($src.Engine -eq "mssql") { Write-Host "  - Text in PostgreSQL is case-sensitive: 'abc' and 'ABC' are different values there (they are equal in SQL Server)." -ForegroundColor DarkGray }
    else { Write-Host "  - Text in SQL Server is usually case-insensitive: values that differ only in upper/lower case can clash in unique columns." -ForegroundColor DarkGray }
    $repDir = Join-Path $cfg.outputFolder "Copy-Reports"
    New-Item -ItemType Directory -Force -Path $repDir | Out-Null
    $rep = Join-Path $repDir ("{0}_to_{1}_{2}.txt" -f (Get-SafeName $src.Name), (Get-SafeName $tgt.Name), (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    $repText = @("Copy $($src.Name) -> $($tgt.Name), mode $mode", "") + @($pairs | ForEach-Object { "{0} -> {1} {2}" -f $_.SrcFull, $_.TFull, $(if ($_.Skip) { "SKIPPED: " + $_.Note } else { $_.Note }) }) + @("", "Notes:") + @($notes) + @("", "Not copied:") + @($src.Modules)
    if ($ddl) { $repText += @("", "-- target DDL (before data)") + @($ddl.Pre) + @("", "-- target DDL (after data)") + @($ddl.Post) }
    [IO.File]::WriteAllLines($rep, [string[]]$repText)
    Write-Host "  Full plan saved: $rep" -ForegroundColor DarkGray

    # ---- backup + confirm
    if ((@($tgt.Meta.Tables.Keys).Count) -gt 0) {
        Write-Host ""
        Write-Host "Back up $($tgt.Name) first?" -ForegroundColor Yellow
        $f1 = if ($tgt.Engine -eq "pg") { "dump" } else { "sql" }
        Write-Host "  1. Yes, as .$f1  (recommended)"
        Write-Host "  2. No"
        if ((Ask ">") -eq "1") {
            try { $bk = Invoke-Backup $cfg $tgt.Conn $f1; Write-Host "  Backup: $($bk.FullName)" -ForegroundColor Green }
            catch { Write-Host "  Backup failed: $($_.Exception.Message)" -ForegroundColor Red; if (-not (Confirm-Yes "Continue WITHOUT a backup?")) { Write-Host "Cancelled - nothing changed."; return } }
        }
    }
    Write-Host ""
    if ((Ask "Type YES to copy $($active.Count) table(s) into $($tgt.Name)") -cne "YES") { Write-Host "Cancelled - nothing changed."; return }

    # ---- copy + verify
    $work = Join-Path ([IO.Path]::GetTempPath()) ("xcopy_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $started = Get-Date
        if ($tgt.Engine -eq "pg") { Invoke-CopyToPg $src $tgt $pairs $ddl $mode $work } else { Invoke-CopyToMs $src $tgt $pairs $ddl $mode $work }
        $rows = ($active | ForEach-Object { $_.Rows } | Measure-Object -Sum).Sum
        Write-Host ("  Copied {0} rows into {1} table(s) in {2}s." -f $rows, $active.Count, [int]((Get-Date) - $started).TotalSeconds) -ForegroundColor Green
        if ($mode -ne "create") { $tgt.Meta = if ($tgt.Engine -eq "pg") { Get-PgMeta $tgt.Cs } else { Get-DbMeta $tgt.Cs } }
        Test-Copy $src $tgt $pairs $mode $work
    }
    finally { Get-ChildItem -LiteralPath $work -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue }
}

try {
    do {
        Clear-Host
        Write-Banner "COPY ACROSS ENGINES  (SQL Server <-> PostgreSQL)"
        try { Invoke-CrossCopy }
        catch {
            if ($_.Exception.Message -eq "No more input - stopping.") { throw }
            Write-Host ""
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host ""
    } while (Confirm-Yes "Copy another database?")
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to close" | Out-Null
}
