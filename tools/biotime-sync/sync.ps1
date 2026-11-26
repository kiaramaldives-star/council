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
  $candidates = @(); $bearer = $null
  foreach ($ep in '/jwt-api-token-auth/', '/api-token-auth/') {
    try {
      $r = Invoke-RestMethod -Method Post -Uri ($cfg['BIOTIME_URL'] + $ep) -ContentType 'application/json' -Body $body -TimeoutSec 30
      $tok = $r.token
      if (-not $tok -and $r.data) { $tok = $r.data.token }
      if (-not $tok -and $r.access) { $tok = $r.access }
      if ($tok) {
        $tok = [string]$tok
        if ($ep -like '*jwt*') { $candidates += @(('JWT ' + $tok)); $bearer = 'Bearer ' + $tok }
        else { $candidates = @(('Token ' + $tok)) + $candidates }
      }
    } catch {}
  }
  if ($bearer) { $candidates += @($bearer) }
  if ($candidates.Count -eq 0) { throw "ZKBio Time login failed. Check BIOTIME_USER and BIOTIME_PASSWORD in config.txt." }
  # Find the header format this ZKBio Time version accepts
  $testPaths = @('/personnel/api/employees/?page_size=1', '/iclock/api/transactions/?page_size=1', '/iclock/api/terminals/?page_size=1')
  foreach ($a in $candidates) {
    foreach ($tp in $testPaths) {
      try {
        $resp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri ($cfg['BIOTIME_URL'] + $tp) -Headers @{ Authorization = $a } -MaximumRedirection 0 -TimeoutSec 30 -ErrorAction Stop
        $ct = ([string]$resp.Content).TrimStart()
        if ([int]$resp.StatusCode -eq 200 -and ($ct.StartsWith('{') -or $ct.StartsWith('['))) {
          Write-Host ('Login OK (' + $a.Split(' ')[0] + ', ' + $tp.Split('?')[0] + ')')
          return $a
        }
        $snip = $ct; if ($snip.Length -gt 90) { $snip = $snip.Substring(0, 90) }
        $snip = ($snip -replace '\s+', ' ')
        Write-Host ('  try ' + $a.Split(' ')[0] + ' ' + $tp.Split('?')[0] + ' -> ' + $resp.StatusCode + ' ' + $resp.Headers['Location'] + ' ' + $snip)
      } catch {
        $code = ''; $loc = ''
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode; $loc = $_.Exception.Response.Headers['Location'] }
        $det = ''; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $det = $_.ErrorDetails.Message }
        $det = ($det -replace '\s+', ' ')
        if ($det.Length -gt 160) { $det = $det.Substring(0, 160) }
        Write-Host ('  try ' + $a.Split(' ')[0] + ' ' + $tp.Split('?')[0] + ' -> ' + $code + ' ' + $loc + ' ' + $det)
      }
    }
  }
  throw "Logged in to ZKBio Time, but it refused the API token. Make sure this ZKBio Time user is a superuser / has API permission."
}

# Prints the shape of a ZKBio Time reply (keys, counts) to help diagnose
function Show-Shape($cfg, $auth, $path) {
  try {
    $raw = (Invoke-WebRequest -UseBasicParsing -Method Get -Uri ($cfg['BIOTIME_URL'] + $path) -Headers @{ Authorization = $auth } -TimeoutSec 60).Content
    $txt = [string]$raw
    $txt = ($txt -replace '\s+', ' ')
    $short = $txt; if ($short.Length -gt 260) { $short = $short.Substring(0, 260) + '...' }
    Write-Host ('  reply ' + $path.Split('?')[0] + ' (' + $txt.Length + ' chars): ' + $short)
  } catch { Write-Host ('  reply ' + $path.Split('?')[0] + ' failed: ' + $_.Exception.Message) }
}

# Downloads a ZKBio Time reply as UTF-8 and parses it with a strict JSON reader
# (Windows PowerShell's own reader fails on some ZKBio Time replies)
Add-Type -AssemblyName System.Web.Extensions
function Get-Json($url, $auth) {
  $resp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $url -Headers @{ Authorization = $auth } -TimeoutSec 120
  $txt = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
  $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $ser.MaxJsonLength = 2147483647
  return $ser.DeserializeObject($txt)
}

# Reads every page of a ZKBio Time list (handles both "data" and "results" styles)
function Get-BioPages($cfg, $auth, $path) {
  $items = New-Object System.Collections.ArrayList
  $url = $cfg['BIOTIME_URL'] + $path
  $guard = 0
  while ($url -and $guard -lt 400) {
    $guard++
    $r = Get-Json $url $auth
    $rows = $null
    if ($r -is [array]) { $rows = $r }
    elseif ($r.ContainsKey('data') -and $r['data'] -is [array]) { $rows = $r['data'] }
    elseif ($r.ContainsKey('results') -and $r['results'] -is [array]) { $rows = $r['results'] }
    elseif ($r.ContainsKey('data') -and $r['data'] -is [System.Collections.IDictionary] -and $r['data'].ContainsKey('data')) { $rows = $r['data']['data'] }
    if ($rows) { foreach ($x in $rows) { [void]$items.Add($x) } }
    $next = $null
    if (-not ($r -is [array]) -and $r.ContainsKey('next')) { $next = [string]$r['next'] }
    if ($next -and $next -notmatch '^https?://') { $next = $cfg['BIOTIME_URL'] + $next }
    elseif ($next -and $next -match '^https?://[^/]+(/.*)$') { $next = $cfg['BIOTIME_URL'] + $Matches[1] }
    $url = $next
  }
  return ,$items
}

function Val($o, $k) { if ($o -is [System.Collections.IDictionary]) { if ($o.ContainsKey($k)) { return $o[$k] } else { return $null } } return $o.$k }

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
    $name = (@((Val $e 'first_name'), (Val $e 'last_name')) | Where-Object { $_ }) -join ' '
    $d = Val $e 'department'; $dept = $null
    if ($d -is [System.Collections.IDictionary]) { $dept = [string](Val $d 'dept_name') } elseif ($d) { $dept = [string]$d }
    $emps += @{ emp_code = [string](Val $e 'emp_code'); name = $name; department = $dept; hire_date = [string](Val $e 'hire_date') }
  }

  $q = '/iclock/api/transactions/?page_size=500&start_time=' + [uri]::EscapeDataString($start)
  $list = Get-BioPages $cfg $auth $q
  $punches = @()
  $latest = $null
  foreach ($t in $list) {
    $ec = [string](Val $t 'emp_code'); $pt = [string](Val $t 'punch_time')
    if (-not $ec -or -not $pt) { continue }
    $punches += @{
      emp_code = $ec; punch_time = $pt; punch_state = [string](Val $t 'punch_state')
      terminal_sn = [string](Val $t 'terminal_sn'); terminal_alias = [string](Val $t 'terminal_alias'); verify_type = [string](Val $t 'verify_type_display')
    }
    if (-not $latest -or $pt -gt $latest) { $latest = $pt }
  }

  if ($emps.Count -eq 0) {
    Show-Shape $cfg $auth '/personnel/api/employees/?page_size=2'
    Show-Shape $cfg $auth ('/iclock/api/transactions/?page_size=2&start_time=' + [uri]::EscapeDataString($start))
    Show-Shape $cfg $auth '/iclock/api/transactions/?page_size=2'
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
