# Kondey School - ZKBio Time to staff portal sync
# Reads new fingerprint check-ins from ZKBio Time on this computer and sends them to the staff portal.
# Runs every 5 minutes from Windows Task Scheduler (see install.bat). Settings are in config.txt next to this file.

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $Here 'config.txt'
$StateFile = Join-Path $Here 'state.txt'
$LogFile = Join-Path $Here 'sync.log'

function Log($msg) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
  Write-Host $line
  try {
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) { Move-Item $LogFile ($LogFile + '.old') -Force }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
  } catch {}
}

function Read-Config {
  if (-not (Test-Path $ConfigFile)) { throw "config.txt not found next to sync.ps1" }
  $c = @{}
  foreach ($l in Get-Content $ConfigFile -Encoding UTF8) {
    $t = $l.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -gt 0) { $c[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim() }
  }
  foreach ($k in 'BIOTIME_URL', 'BIOTIME_USER', 'BIOTIME_PASSWORD', 'SYNC_KEY', 'PORTAL_URL', 'PORTAL_APIKEY') {
    if (-not $c[$k]) { throw "config.txt: $k is empty" }
  }
  $c['BIOTIME_URL'] = $c['BIOTIME_URL'].TrimEnd('/')
  $c['PORTAL_URL'] = $c['PORTAL_URL'].TrimEnd('/')
  return $c
}

function Get-BioToken($cfg) {
  $body = @{ username = $cfg['BIOTIME_USER']; password = $cfg['BIOTIME_PASSWORD'] } | ConvertTo-Json
  try {
    $r = Invoke-RestMethod -Method Post -Uri ($cfg['BIOTIME_URL'] + '/jwt-api-token-auth/') -ContentType 'application/json' -Body $body -TimeoutSec 30
    if ($r.token) { return 'JWT ' + $r.token }
  } catch {}
  $r = Invoke-RestMethod -Method Post -Uri ($cfg['BIOTIME_URL'] + '/api-token-auth/') -ContentType 'application/json' -Body $body -TimeoutSec 30
  if ($r.token) { return 'Token ' + $r.token }
  throw "ZKBio Time login failed. Check BIOTIME_USER and BIOTIME_PASSWORD in config.txt."
}

# Reads every page of a ZKBio Time list (handles both "data" and "results" styles)
function Get-BioPages($cfg, $auth, $path) {
  $items = New-Object System.Collections.ArrayList
  $url = $cfg['BIOTIME_URL'] + $path
  $guard = 0
  while ($url -and $guard -lt 200) {
    $guard++
    $r = Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = $auth } -TimeoutSec 60
    $rows = $null
    if ($r.data) { $rows = $r.data } elseif ($r.results) { $rows = $r.results }
    if ($rows) { foreach ($x in @($rows)) { [void]$items.Add($x) } }
    $next = $r.next
    if ($next -and $next -notmatch '^https?://') { $next = $cfg['BIOTIME_URL'] + $next }
    if ($next -and $next -match '^https?://[^/]+(/.*)$' -and $next -notlike ($cfg['BIOTIME_URL'] + '*')) { $next = $cfg['BIOTIME_URL'] + $Matches[1] }
    $url = $next
  }
  return ,$items
}

function Send-ToPortal($cfg, $punches, $employees) {
  $payload = @{ p_key = $cfg['SYNC_KEY']; p_punches = @($punches); p_employees = @($employees) } | ConvertTo-Json -Depth 5 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
  $r = Invoke-RestMethod -Method Post -Uri ($cfg['PORTAL_URL'] + '/rest/v1/rpc/staff_punch_ingest') `
        -Headers @{ apikey = $cfg['PORTAL_APIKEY'] } -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 60
  return $r
}

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $cfg = Read-Config

  # Where to start: last check-in sent, minus 15 minutes overlap (duplicates are ignored by the portal)
  $since = (Get-Date).AddDays(-30)
  if (Test-Path $StateFile) {
    $saved = (Get-Content $StateFile -Raw).Trim()
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($saved, 'yyyy-MM-dd HH:mm:ss', $null, 'None', [ref]$parsed)) { $since = $parsed.AddMinutes(-15) }
  }
  $start = $since.ToString('yyyy-MM-dd HH:mm:ss')

  $auth = Get-BioToken $cfg

  $emps = @()
  foreach ($e in (Get-BioPages $cfg $auth '/personnel/api/employees/?page_size=500')) {
    $name = (@($e.first_name, $e.last_name) | Where-Object { $_ }) -join ' '
    $dept = $null
    if ($e.department) { $dept = $e.department.dept_name }
    $emps += @{ emp_code = [string]$e.emp_code; name = $name; department = $dept }
  }

  $q = '/iclock/api/transactions/?page_size=500&start_time=' + [uri]::EscapeDataString($start)
  $list = Get-BioPages $cfg $auth $q
  $punches = @()
  $latest = $null
  foreach ($t in $list) {
    if (-not $t.emp_code -or -not $t.punch_time) { continue }
    $punches += @{
      emp_code = [string]$t.emp_code; punch_time = [string]$t.punch_time; punch_state = [string]$t.punch_state
      terminal_sn = [string]$t.terminal_sn; terminal_alias = [string]$t.terminal_alias; verify_type = [string]$t.verify_type_display
    }
    if (-not $latest -or ([string]$t.punch_time) -gt $latest) { $latest = [string]$t.punch_time }
  }

  # Send in batches of 1000
  $added = 0
  if ($punches.Count -eq 0) {
    $r = Send-ToPortal $cfg @() $emps
  } else {
    for ($i = 0; $i -lt $punches.Count; $i += 1000) {
      $chunk = $punches[$i..([Math]::Min($i + 999, $punches.Count - 1))]
      $empPart = @(); if ($i -eq 0) { $empPart = $emps }
      $r = Send-ToPortal $cfg $chunk $empPart
      $added += [int]$r.added
    }
  }
  if ($latest) { $l2 = $latest.Replace('T', ' '); Set-Content -Path $StateFile -Value $l2.Substring(0, [Math]::Min(19, $l2.Length)) -Encoding ASCII }
  Log ("OK  since " + $start + "  read " + $punches.Count + " check-ins, " + $added + " new, " + $emps.Count + " employees")
  exit 0
} catch {
  $msg = $_.Exception.Message
  if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $msg + ' | ' + $_.ErrorDetails.Message }
  Log ("ERROR  " + $msg)
  exit 1
}
