<#
.SYNOPSIS
    Read-only discovery of an Azure estate, aggregated for a migration business case.

.DESCRIPTION
    Runs a set of Azure Resource Graph queries across every subscription the
    signed-in identity can see, and writes a single Markdown report.

    Everything is aggregated in the query itself, server side. No raw resource
    inventory is returned, no resource names, no subscription identifiers, and
    nothing is written outside the session it runs in. Reader is sufficient.

    Designed to be run from Azure Cloud Shell, where the Az modules are already
    present and the session is already authenticated:

        irm https://raw.githubusercontent.com/<owner>/<repo>/main/e.ps1 | iex

.NOTES
    Read-only. Every call is a GET or a Resource Graph query. Nothing is
    created, changed or deleted.
#>

[CmdletBinding()]
param(
    # Where to write the report. Defaults to the home directory of the session.
    [string] $OutputPath,

    # Skip writing a file and print to screen only.
    [switch] $NoFile
)

$ErrorActionPreference = 'Stop'
$script:Report = [System.Text.StringBuilder]::new()

# --------------------------------------------------------------- presentation

function Write-Section {
    param([string] $Title, [string] $Why)

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    if ($Why) { Write-Host "  $Why" -ForegroundColor DarkGray }
    Write-Host ('=' * 78) -ForegroundColor DarkCyan

    [void]$script:Report.AppendLine()
    [void]$script:Report.AppendLine("## $Title")
    [void]$script:Report.AppendLine()
    if ($Why) {
        [void]$script:Report.AppendLine("*$Why*")
        [void]$script:Report.AppendLine()
    }
}

function Write-Note {
    param([string] $Text)
    Write-Host "  $Text" -ForegroundColor Yellow
    [void]$script:Report.AppendLine("> $Text")
    [void]$script:Report.AppendLine()
}

<#
    Renders a result set as both a console table and a Markdown table.

    The Markdown matters because the report is the artefact that survives the
    session. Screen output is for reading now, the file is for reading later.
#>
function Write-Result {
    param(
        [object[]] $Rows,
        [string[]] $Columns,
        [string]   $EmptyMessage = 'Nothing found.'
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-Host "  $EmptyMessage" -ForegroundColor DarkYellow
        [void]$script:Report.AppendLine("_${EmptyMessage}_")
        [void]$script:Report.AppendLine()
        return
    }

    if (-not $Columns) {
        $Columns = $Rows[0].PSObject.Properties.Name |
                   Where-Object { $_ -notin 'ResourceId', 'SubscriptionId', 'TenantId' }
    }

    $Rows | Format-Table -Property $Columns -AutoSize | Out-Host

    [void]$script:Report.AppendLine('| ' + ($Columns -join ' | ') + ' |')
    [void]$script:Report.AppendLine('| ' + (($Columns | ForEach-Object { '---' }) -join ' | ') + ' |')
    foreach ($row in $Rows) {
        $cells = foreach ($c in $Columns) {
            $v = $row.$c
            if ($null -eq $v) { '' } else { ($v -as [string]) -replace '\|', '\|' }
        }
        [void]$script:Report.AppendLine('| ' + ($cells -join ' | ') + ' |')
    }
    [void]$script:Report.AppendLine()
}

# --------------------------------------------------------------- graph access

<#
    Runs one Resource Graph query across every accessible subscription.

    A failure here is never fatal. A tenant may not have a given resource type,
    or a query may hit a schema difference, and neither is a reason to abandon
    the rest of the run.
#>
function Invoke-Graph {
    param([string] $Query, [string] $Label)

    try {
        $results = Search-AzGraph -Query $Query -First 1000 -ErrorAction Stop
        return @($results)
    }
    catch {
        Write-Host "  Query failed: $($_.Exception.Message)" -ForegroundColor Red
        [void]$script:Report.AppendLine("_Query failed: $($_.Exception.Message)_")
        [void]$script:Report.AppendLine()
        return @()
    }
}

# --------------------------------------------------------------------- checks

Write-Host ''
Write-Host 'Azure estate discovery' -ForegroundColor White
Write-Host 'Read-only. Aggregated in-query. Nothing leaves this session.' -ForegroundColor DarkGray
Write-Host ''

if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
    Write-Host 'Az.ResourceGraph is not available in this session.' -ForegroundColor Red
    Write-Host 'In Cloud Shell it should already be present. Locally, run:' -ForegroundColor Yellow
    Write-Host '  Install-Module Az.ResourceGraph -Scope CurrentUser -Force' -ForegroundColor Yellow
    return
}

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Host 'Not signed in. Run Connect-AzAccount first.' -ForegroundColor Red
    return
}

$subs = @(Get-AzSubscription -ErrorAction SilentlyContinue)
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'

Write-Host "  Identity      : $($context.Account.Id)" -ForegroundColor Gray
Write-Host "  Tenant        : $($context.Tenant.Id)" -ForegroundColor Gray
Write-Host "  Subscriptions : $($subs.Count) visible" -ForegroundColor Gray
Write-Host "  As at         : $stamp" -ForegroundColor Gray

[void]$script:Report.AppendLine('# Azure estate discovery')
[void]$script:Report.AppendLine()
[void]$script:Report.AppendLine("Generated $stamp. Read-only, aggregated. Subscriptions visible: $($subs.Count).")
[void]$script:Report.AppendLine()
[void]$script:Report.AppendLine('All figures come from Azure Resource Graph and are aggregated in the query itself, so no resource names or identifiers were retrieved.')

# ------------------------------------------------------------------ 1. estate

Write-Section 'Estate at a glance' 'What actually exists, before anything is assumed about it.'

$rows = Invoke-Graph @'
Resources
| summarize Resources = count() by type
| order by Resources desc
| take 25
'@

Write-Result -Rows $rows -Columns @('type', 'Resources')

# ------------------------------------------------------- 2. compute by SKU

Write-Section 'Virtual machines by size' 'The compute fleet. This is the population any per-user cost figure is divided across.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend vmSize = tostring(properties.hardwareProfile.vmSize)
| extend osType = tostring(properties.storageProfile.osDisk.osType)
| summarize VMs = count() by vmSize, osType
| order by VMs desc
| take 40
'@

Write-Result -Rows $rows -Columns @('vmSize', 'osType', 'VMs')

$total = ($rows | Measure-Object -Property VMs -Sum).Sum
if ($total) { Write-Note "Total virtual machines in the rows above: $total" }

# ------------------------------------------------ 3. ephemeral vs managed OS

Write-Section 'Ephemeral versus managed OS disks' 'Decides whether disk tiering has anything to act on. An ephemeral host has no billed OS disk at all.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend diffOption = tostring(properties.storageProfile.osDisk.diffDiskSettings.option)
| extend osDiskModel = iff(isnotempty(diffOption), 'Ephemeral', 'Managed')
| extend vmSize = tostring(properties.hardwareProfile.vmSize)
| summarize VMs = count() by osDiskModel, vmSize
| order by VMs desc
| take 40
'@

Write-Result -Rows $rows -Columns @('osDiskModel', 'vmSize', 'VMs')

$split = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend diffOption = tostring(properties.storageProfile.osDisk.diffDiskSettings.option)
| extend osDiskModel = iff(isnotempty(diffOption), 'Ephemeral', 'Managed')
| summarize VMs = count() by osDiskModel
'@

Write-Result -Rows $split -Columns @('osDiskModel', 'VMs')

# --------------------------------------------------------- 4. VM power state

Write-Section 'Power state' 'How much of the fleet is actually running right now. Duty cycle is the whole cost argument.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend powerState = tostring(properties.extended.instanceView.powerState.displayStatus)
| summarize VMs = count() by powerState
| order by VMs desc
'@

Write-Result -Rows $rows -Columns @('powerState', 'VMs') `
    -EmptyMessage 'No power state returned. Resource Graph exposes this through the extended instance view, which is not always populated.'

# ------------------------------------------------------------- 5. VM regions

Write-Section 'Regions' 'Where the fleet sits. Relevant to in-region capacity and to any second-region conversation.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| summarize VMs = count() by location
| order by VMs desc
'@

Write-Result -Rows $rows -Columns @('location', 'VMs')

# --------------------------------------------------------- 6. VM generations

Write-Section 'SKU generation spread' 'Which hardware generations are actually in use. A generation gap at identical price is lost performance.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend vmSize = tostring(properties.hardwareProfile.vmSize)
| extend family = extract(@'^(Standard_[A-Za-z]+)', 1, vmSize)
| extend generation = extract(@'_v(\d+)$', 1, vmSize)
| extend generation = iff(isempty(generation), 'v1 or unversioned', strcat('v', generation))
| summarize VMs = count() by family, generation
| order by VMs desc
| take 40
'@

Write-Result -Rows $rows -Columns @('family', 'generation', 'VMs')

# ------------------------------------------------------------- 7. disks

Write-Section 'Managed disks by tier' 'The only population disk tiering can act on, and what it currently costs to keep.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/disks'
| extend skuName = tostring(sku.name)
| extend state = tostring(properties.diskState)
| extend sizeGB = toint(properties.diskSizeGB)
| summarize Disks = count(), ProvisionedTiB = round(sum(sizeGB) / 1024.0, 1) by skuName, state
| order by Disks desc
'@

Write-Result -Rows $rows -Columns @('skuName', 'state', 'Disks', 'ProvisionedTiB')

Write-Section 'Managed disks by size' 'Size clusters usually reveal the standard build. A large cluster at one size is a fleet, not a coincidence.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.compute/disks'
| extend sizeGB = toint(properties.diskSizeGB)
| extend skuName = tostring(sku.name)
| summarize Disks = count() by sizeGB, skuName
| order by Disks desc
| take 30
'@

Write-Result -Rows $rows -Columns @('sizeGB', 'skuName', 'Disks')

# ------------------------------------------------------------ 8. AVD estate

Write-Section 'Azure Virtual Desktop' 'Whatever already exists. Often more than anyone expects.'

$rows = Invoke-Graph @'
Resources
| where type startswith 'microsoft.desktopvirtualization'
| summarize Count = count() by type
| order by Count desc
'@

Write-Result -Rows $rows -Columns @('type', 'Count') -EmptyMessage 'No Azure Virtual Desktop resources found.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.desktopvirtualization/hostpools'
| extend poolType = tostring(properties.hostPoolType)
| extend loadBalancer = tostring(properties.loadBalancerType)
| extend maxSessions = toint(properties.maxSessionLimit)
| summarize HostPools = count() by poolType, loadBalancer, maxSessions
| order by HostPools desc
'@

Write-Result -Rows $rows -Columns @('poolType', 'loadBalancer', 'maxSessions', 'HostPools') `
    -EmptyMessage 'No host pools found.'

# ------------------------------------------------------- 9. profile storage

Write-Section 'Azure NetApp Files' 'Profile storage. Capacity and service level together decide both performance and cost.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.netapp/netappaccounts/capacitypools/volumes'
| extend serviceLevel = tostring(properties.serviceLevel)
| extend quotaGiB = todouble(properties.usageThreshold) / 1073741824
| summarize Volumes = count(), ProvisionedTiB = round(sum(quotaGiB) / 1024.0, 1) by serviceLevel, location
| order by ProvisionedTiB desc
'@

Write-Result -Rows $rows -Columns @('serviceLevel', 'location', 'Volumes', 'ProvisionedTiB') `
    -EmptyMessage 'No Azure NetApp Files volumes visible.'

Write-Section 'Storage accounts by kind and replication' 'The other half of the profile and application delivery picture.'

$rows = Invoke-Graph @'
Resources
| where type =~ 'microsoft.storage/storageaccounts'
| extend skuName = tostring(sku.name)
| extend tier = tostring(properties.accessTier)
| summarize Accounts = count() by kind, skuName, tier
| order by Accounts desc
| take 25
'@

Write-Result -Rows $rows -Columns @('kind', 'skuName', 'tier', 'Accounts')

# ------------------------------------------------------ 10. images and galleries

Write-Section 'Image sources' 'Where hosts are actually built from. Relevant to whether an image pipeline is being lost or kept.'

$rows = Invoke-Graph @'
Resources
| where type in~ ('microsoft.compute/galleries', 'microsoft.compute/galleries/images',
                  'microsoft.compute/images', 'microsoft.compute/galleries/images/versions')
| summarize Count = count() by type
| order by Count desc
'@

Write-Result -Rows $rows -Columns @('type', 'Count') -EmptyMessage 'No compute gallery or managed image resources visible.'

# ------------------------------------------------- 11. reservations coverage

Write-Section 'Reservations and savings plans' 'Commitment coverage. A lapsed reservation is a silent price rise.'

$rows = Invoke-Graph @'
Resources
| where type startswith 'microsoft.capacity'
| summarize Count = count() by type
| order by Count desc
'@

Write-Result -Rows $rows -Columns @('type', 'Count') `
    -EmptyMessage 'No capacity resources visible through Resource Graph.'

try {
    $res = @(Get-AzReservation -ErrorAction Stop)
    if ($res.Count -gt 0) {
        $summary = $res | Group-Object { $_.SkuName }, { $_.ProvisioningState } |
            ForEach-Object {
                [pscustomobject]@{
                    Sku        = $_.Group[0].SkuName
                    State      = $_.Group[0].ProvisioningState
                    Quantity   = ($_.Group | Measure-Object -Property Quantity -Sum).Sum
                    Expiring   = ($_.Group | Sort-Object ExpiryDate | Select-Object -First 1).ExpiryDate
                }
            }
        Write-Result -Rows $summary -Columns @('Sku', 'State', 'Quantity', 'Expiring')
    }
    else {
        Write-Note 'No reservations returned. Reservation data needs the Reservation Reader role, which is separate from subscription Reader.'
    }
}
catch {
    $reason = $_.Exception.Message.TrimEnd('.')
    Write-Note "Reservation lookup unavailable: $reason. This usually means the Reservation Reader role has not been granted - it is billing scoped, not subscription scoped."
}

# ---------------------------------------------------------------- 12. network

Write-Section 'Network shape' 'Gateways, firewalls and private endpoints. The things that decide how a desktop actually reaches anything.'

$rows = Invoke-Graph @'
Resources
| where type in~ ('microsoft.network/virtualnetworkgateways', 'microsoft.network/azurefirewalls',
                  'microsoft.network/privateendpoints', 'microsoft.network/natgateways',
                  'microsoft.network/expressroutecircuits', 'microsoft.network/connections')
| summarize Count = count() by type, location
| order by Count desc
| take 30
'@

Write-Result -Rows $rows -Columns @('type', 'location', 'Count')

# ----------------------------------------------------------------- write out

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor DarkCyan

if (-not $NoFile) {
    if (-not $OutputPath) {
        $home_ = if ($HOME) { $HOME } else { (Get-Location).Path }
        $OutputPath = Join-Path $home_ ("azure-discovery-{0}.md" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
    }

    try {
        $script:Report.ToString() | Out-File -FilePath $OutputPath -Encoding utf8
        Write-Host ''
        Write-Host "  Report written to:" -ForegroundColor Green
        Write-Host "  $OutputPath" -ForegroundColor White
        Write-Host ''
        Write-Host '  It stays in this session. Nothing has been sent anywhere.' -ForegroundColor DarkGray
        Write-Host '  Agree an approved channel before moving any of it out.' -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  Could not write the report: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Everything above is still on screen.' -ForegroundColor Yellow
    }
}

Write-Host ''
