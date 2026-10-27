# Shared helpers for the Portfolio 5 scripts (dot-source this file).
# Runs extra PostgreSQL instances natively, one per port, under .cluster\ (git ignored).
#
#   Role              Port   Used by
#   primary           5433   replication
#   replica1          5434   replication (streaming replica of primary)
#   router            5440   sharding (postgres_fdw coordinator)
#   shard1, shard2    5441, 5442
#
# Requirements: PostgreSQL client + server binaries (set $env:PGBIN if not the default
# 'C:\Program Files\PostgreSQL\18\bin') and $env:PGPASSWORD (used as the password of
# every test instance, the same one as your .env).

$script:P5      = $PSScriptRoot
$script:Repo    = Split-Path -Parent $P5
$script:PgBin   = if ($env:PGBIN) { $env:PGBIN } else { 'C:\Program Files\PostgreSQL\18\bin' }
$script:Cluster = Join-Path $P5 '.cluster'
$script:DbUser  = if ($env:PGUSER) { $env:PGUSER } else { 'copay_admin' }
$script:Python  = if (Test-Path (Join-Path $Repo '.venv\Scripts\python.exe')) { Join-Path $Repo '.venv\Scripts\python.exe' } else { 'python' }
if (-not $env:PGPASSWORD) { throw 'Set $env:PGPASSWORD first (see docs/SETUP_WINDOWS.md).' }
if (-not (Test-Path (Join-Path $PgBin 'initdb.exe'))) { throw "initdb.exe not found in $PgBin. Set `$env:PGBIN." }
$env:Path = "$PgBin;$env:Path"
$env:PGOPTIONS = '-c client_min_messages=warning'
New-Item -ItemType Directory -Force $Cluster | Out-Null

function Get-NodeDir([string]$Name) { Join-Path $Cluster $Name }

function New-Node {
    param([string]$Name, [int]$Port, [string[]]$Conf = @())
    $dir = Get-NodeDir $Name
    if (Test-Path $dir) { throw "$dir already exists. Run cleanup.ps1 first." }
    $pw = Join-Path $env:TEMP "copay_p5_$Name.pw"
    Set-Content -Path $pw -Value $env:PGPASSWORD -Encoding ascii
    & initdb -D $dir -U $DbUser --pwfile=$pw -A scram-sha-256 -E UTF8 | Out-Null
    Remove-Item $pw -ErrorAction SilentlyContinue
    $base = @("port = $Port", "listen_addresses = 'localhost'", 'wal_level = replica',
              'max_wal_senders = 10', 'max_replication_slots = 10', 'hot_standby = on')
    Add-Content -Path (Join-Path $dir 'postgresql.conf') -Value ($base + $Conf)
}

function Start-Node {
    param([string]$Name, [int]$Port)
    $dir = Get-NodeDir $Name
    Start-Process -FilePath (Join-Path $PgBin 'postgres.exe') -ArgumentList @('-D', "`"$dir`"") `
        -WindowStyle Hidden -RedirectStandardError (Join-Path $Cluster "$Name.log") | Out-Null
    for ($i = 0; $i -lt 60; $i++) {
        & pg_isready -h localhost -p $Port -q
        if ($LASTEXITCODE -eq 0) { Write-Host "  $Name is running on port $Port"; return }
        Start-Sleep -Seconds 1
    }
    throw "$Name did not start; see $Cluster\$Name.log"
}

function Stop-Node {
    param([string]$Name)
    $dir = Get-NodeDir $Name
    if (Test-Path (Join-Path $dir 'postmaster.pid')) {
        & pg_ctl stop -D $dir -m fast -w | Out-Null
        Write-Host "  $Name stopped"
    }
}

# Run SQL text against a node; extra psql arguments allowed. Returns output lines.
function Invoke-Sql {
    param([int]$Port, [string]$Db, [string]$Sql, [string[]]$Extra = @())
    $out = & psql -X -q -h localhost -p $Port -U $DbUser -d $Db -v ON_ERROR_STOP=1 @Extra -c $Sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql failed on port ${Port}: $out" }
    $out
}

function Invoke-SqlFile {
    param([int]$Port, [string]$Db, [string]$File, [string[]]$Extra = @())
    & psql -X -q -h localhost -p $Port -U $DbUser -d $Db -v ON_ERROR_STOP=1 @Extra -f $File
    if ($LASTEXITCODE -ne 0) { throw "psql failed on port $Port for $File" }
}

# Show results of a query (formatted table) without failing the script.
function Show-Sql {
    param([int]$Port, [string]$Db, [string]$Sql)
    & psql -X -h localhost -p $Port -U $DbUser -d $Db -c $Sql 2>&1
}
