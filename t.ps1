<#
.SYNOPSIS
    Point-in-time and historical scale sampling for an Azure compute estate.

.DESCRIPTION
    Two things, and they answer different questions.

    Part one is a snapshot of what is running right now, broken down the ways
    that matter for a desktop estate: ephemeral against managed, by size, and by
    subscription. Run it repeatedly through a day and the shape of the ramp
    emerges.

    Part two reads Azure Resource Graph's change history, which retains roughly
    fourteen days. Power state transitions are *not* recorded there - power
    state is a runtime property rather than a template one - but virtual machine
    **creation and deletion are**. That matters for any estate whose pooled
    hosts are created on demand and deleted on shutdown, because in that model a
    create is a scale-out and a delete is a scale-in. One run then yields two
    weeks of scaling behaviour rather than a single reading.

    Every run also emits a single comma separated TREND line. Collect those from
    several runs and they stack into a table without any further work.

.NOTES
    Read-only. Aggregated in-query. Designed for Azure Cloud Shell:

        irm https://raw.githubusercontent.com/<owner>/<repo>/main/t.ps1 | iex
#>

[CmdletBinding()]
param(
    # IANA time zone used for local time and for hour-of-day bucketing.
    # Brisbane is deliberate: it is UTC+10 all year and has no daylight saving,
    # so hour-of-day comparisons stay honest across the whole retention window.
    [string] $TimeZone = 'Australia/Brisbane',

    # Skip the fourteen day history and report only the current snapshot.
    [switch] $NowOnly
)

$ErrorActionPreference = 'Stop'

function Invoke-Graph {
    param([string] $Query)
    try {
        return @(Search-AzGraph -Query $Query -First 1000 -ErrorAction Stop)
    }
    catch {
        Write-Host "  Query failed: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

function Write-Head {
    param([string] $Title, [string] $Why)
    Write-Host ''
    Write-Host ('-' * 76) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    if ($Why) { Write-Host "  $Why" -ForegroundColor DarkGray }
    Write-Host ('-' * 76) -ForegroundColor DarkCyan
}

if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
    Write-Host 'Az.ResourceGraph is not available in this session.' -ForegroundColor Red
    return
}
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Write-Host 'Not signed in. Run Connect-AzAccount first.' -ForegroundColor Red
    return
}

# ------------------------------------------------------------------ the clock

$utc = (Get-Date).ToUniversalTime()
try {
    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
}
catch {
    Write-Host "  Unknown time zone '$TimeZone', falling back to UTC." -ForegroundColor Yellow
    $tz = [System.TimeZoneInfo]::Utc
}
$local = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz)
$offsetHours = [int]$tz.GetUtcOffset($utc).TotalHours

Write-Host ''
Write-Host 'Estate scale sampler' -ForegroundColor White
Write-Host "  Local : $($local.ToString('yyyy-MM-dd HH:mm')) ($TimeZone, UTC+$offsetHours)" -ForegroundColor Gray
Write-Host "  UTC   : $($utc.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Gray
Write-Host "  Day   : $($local.DayOfWeek)" -ForegroundColor Gray

# ----------------------------------------------------------------- 1. headline

Write-Head 'Right now' 'Everything, split by how the machine is provisioned.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend diff = tostring(properties.storageProfile.osDisk.diffDiskSettings.option)
| extend model = iff(isnotempty(diff), 'Ephemeral', 'Managed')
| extend state = tostring(properties.extended.instanceView.powerState.displayStatus)
| summarize Total = count(),
            Running = countif(state =~ 'VM running'),
            Deallocated = countif(state =~ 'VM deallocated'),
            Stopped = countif(state =~ 'VM stopped') by model
| extend RunningPct = round(100.0 * Running / Total, 0)
| order by Total desc
'@

if ($rows.Count -eq 0) {
    Write-Host '  No virtual machines visible.' -ForegroundColor Yellow
    return
}

$rows | Format-Table model, Total, Running, Deallocated, Stopped, RunningPct -AutoSize | Out-Host

$eph = $rows | Where-Object { $_.model -eq 'Ephemeral' }
$mgd = $rows | Where-Object { $_.model -eq 'Managed' }

$totalVms = ($rows | Measure-Object Total -Sum).Sum
$totalRun = ($rows | Measure-Object Running -Sum).Sum
$totalDeal = ($rows | Measure-Object Deallocated -Sum).Sum
$totalStop = ($rows | Measure-Object Stopped -Sum).Sum

Write-Host ("  {0} machines, {1} running ({2}%)" -f `
    $totalVms, $totalRun, [math]::Round(100.0 * $totalRun / $totalVms, 0)) -ForegroundColor White

# ----------------------------------------------------------------- 2. by size

Write-Head 'By size' 'Only sizes with ten or more machines. Small populations add noise, not signal.'

$sizes = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend vmSize = tostring(properties.hardwareProfile.vmSize)
| extend diff = tostring(properties.storageProfile.osDisk.diffDiskSettings.option)
| extend model = iff(isnotempty(diff), 'Ephemeral', 'Managed')
| extend state = tostring(properties.extended.instanceView.powerState.displayStatus)
| summarize Total = count(), Running = countif(state =~ 'VM running') by vmSize, model
| where Total >= 10
| extend RunningPct = round(100.0 * Running / Total, 0)
| order by Total desc
| take 25
'@

$sizes | Format-Table vmSize, model, Total, Running, RunningPct -AutoSize | Out-Host

if ($sizes.Count -eq 0) {
    Write-Host '  No size has ten or more machines, so nothing is shown here.' -ForegroundColor DarkYellow
    Write-Host '  That threshold exists to keep the signal clean on a large estate.' -ForegroundColor DarkGray
}

# --------------------------------------------------------- 3. by subscription

Write-Head 'By subscription' 'Where the running load actually sits. In a large tenant this separates one estate from another.'

$subs = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend diff = tostring(properties.storageProfile.osDisk.diffDiskSettings.option)
| extend state = tostring(properties.extended.instanceView.powerState.displayStatus)
| summarize Total = count(),
            Running = countif(state =~ 'VM running'),
            Ephemeral = countif(isnotempty(diff)) by subscriptionId
| extend RunningPct = round(100.0 * Running / Total, 0)
| where Total >= 10
| order by Total desc
| take 15
'@

$subs | Format-Table subscriptionId, Total, Running, RunningPct, Ephemeral -AutoSize | Out-Host

if ($subs.Count -eq 0) {
    Write-Host '  No subscription holds ten or more machines.' -ForegroundColor DarkYellow
}

# ------------------------------------------------------------ 4. the history

if (-not $NowOnly) {

    Write-Head 'Machine churn, last fourteen days' 'Creates and deletes. Where pooled hosts are built on demand and destroyed on shutdown, these are the scale events.'

    $window = Invoke-Graph @'
resourcechanges
| extend t = todatetime(properties.changeAttributes.timestamp)
| summarize Oldest = min(t), Newest = max(t), Records = count()
'@

    if ($window.Count -gt 0 -and $window[0].Records -gt 0) {
        Write-Host ("  Change history spans {0:yyyy-MM-dd} to {1:yyyy-MM-dd}, {2} records." -f `
            [datetime]$window[0].Oldest, [datetime]$window[0].Newest, $window[0].Records) -ForegroundColor Gray
    }

    $churnQuery = @'
resourcechanges
| extend targetType = tostring(properties.targetResourceType)
| where targetType =~ 'microsoft.compute/virtualmachines'
| extend changeType = tostring(properties.changeType)
| extend t = todatetime(properties.changeAttributes.timestamp)
| extend localT = datetime_utc_to_local(t, 'Australia/Brisbane')
| summarize Events = count() by changeType, bin(localT, 1d)
| order by localT asc
'@ -replace 'Australia/Brisbane', $TimeZone

    $churn = Invoke-Graph $churnQuery

    if ($churn.Count -eq 0) {
        Write-Host '  No virtual machine create or delete events in the retained window.' -ForegroundColor Yellow
        Write-Host '  Either the estate is static, or machines are started and stopped rather than' -ForegroundColor DarkGray
        Write-Host '  created and destroyed. Power state changes are not recorded here.' -ForegroundColor DarkGray
    }
    else {
        $churn | Select-Object @{n='Day';e={([datetime]$_.localT).ToString('yyyy-MM-dd ddd')}}, changeType, Events |
            Format-Table -AutoSize | Out-Host

        Write-Head 'Churn by hour of day' 'The ramp, reconstructed from two weeks rather than sampled once.'

        $hourQuery = @'
resourcechanges
| extend targetType = tostring(properties.targetResourceType)
| where targetType =~ 'microsoft.compute/virtualmachines'
| extend changeType = tostring(properties.changeType)
| extend t = todatetime(properties.changeAttributes.timestamp)
| extend localT = datetime_utc_to_local(t, 'Australia/Brisbane')
| extend hourOfDay = hourofday(localT)
| summarize Created = countif(changeType =~ 'Create'),
            Deleted = countif(changeType =~ 'Delete') by hourOfDay
| order by hourOfDay asc
'@ -replace 'Australia/Brisbane', $TimeZone

        $hours = Invoke-Graph $hourQuery

        if ($hours.Count -gt 0) {
            $peak = ($hours | Measure-Object Created -Maximum).Maximum
            if ($peak -lt 1) { $peak = 1 }

            foreach ($h in $hours) {
                $bar = '#' * [math]::Min(40, [int](40 * $h.Created / $peak))
                Write-Host ("  {0:00}:00  created {1,5}  deleted {2,5}  {3}" -f `
                    $h.hourOfDay, $h.Created, $h.Deleted, $bar) -ForegroundColor Gray
            }
            Write-Host ''
            Write-Host "  Hours are $TimeZone. The bar tracks creations." -ForegroundColor DarkGray
        }
    }
}

# -------------------------------------------------------------- 5. trend line

$ephTotal = if ($eph) { $eph.Total } else { 0 }
$ephRun   = if ($eph) { $eph.Running } else { 0 }
$mgdTotal = if ($mgd) { $mgd.Total } else { 0 }
$mgdRun   = if ($mgd) { $mgd.Running } else { 0 }

Write-Host ''
Write-Host ('=' * 76) -ForegroundColor DarkCyan
Write-Host '  Copy the line below. Several of them stack into a trend table.' -ForegroundColor Green
Write-Host ('=' * 76) -ForegroundColor DarkCyan
Write-Host ''
Write-Host 'TREND,localTime,dayOfWeek,totalVMs,running,deallocated,stopped,ephTotal,ephRunning,mgdTotal,mgdRunning' -ForegroundColor DarkGray
Write-Host ("TREND,{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}" -f `
    $local.ToString('yyyy-MM-dd HH:mm'), $local.DayOfWeek,
    $totalVms, $totalRun, $totalDeal, $totalStop,
    $ephTotal, $ephRun, $mgdTotal, $mgdRun) -ForegroundColor White
Write-Host ''

$topSizes = $sizes | Select-Object -First 6
if ($topSizes) {
    Write-Host 'SIZE,localTime,vmSize,model,total,running' -ForegroundColor DarkGray
    foreach ($s in $topSizes) {
        Write-Host ("SIZE,{0},{1},{2},{3},{4}" -f `
            $local.ToString('yyyy-MM-dd HH:mm'), $s.vmSize, $s.model, $s.Total, $s.Running) -ForegroundColor White
    }
}

Write-Host ''
Write-Host '  Nothing has been written or sent. Read-only throughout.' -ForegroundColor DarkGray
Write-Host ''
