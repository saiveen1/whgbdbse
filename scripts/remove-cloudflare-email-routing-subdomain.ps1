[CmdletBinding()]
param(
    [string]$Domain = 'aibus.us.ci',
    [string]$Subdomain = 'test.aibus.us.ci',
    [string]$CloudflareEmail,
    [string]$CloudflareApiKey,
    [string]$AccountId,
    [string]$ApiBaseUrl = 'https://api.cloudflare.com/client/v4',
    [switch]$Apply,
    [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'

function Normalize-Name {
    param([string]$Name)
    return ($Name.Trim().TrimEnd('.')).ToLowerInvariant()
}

function Assert-SafeSubdomain {
    param(
        [string]$ParentDomain,
        [string]$TargetSubdomain
    )

    if ([string]::IsNullOrWhiteSpace($ParentDomain)) {
        throw 'Domain is required.'
    }
    if ([string]::IsNullOrWhiteSpace($TargetSubdomain)) {
        throw 'Subdomain is required.'
    }

    $normalizedDomain = Normalize-Name -Name $ParentDomain
    $normalizedSubdomain = Normalize-Name -Name $TargetSubdomain
    if ($normalizedSubdomain.Contains('*')) {
        throw 'Subdomain must not contain wildcards.'
    }
    if ($normalizedSubdomain -eq $normalizedDomain) {
        throw "Subdomain must be a child of $normalizedDomain, not the apex domain."
    }
    if (-not $normalizedSubdomain.EndsWith(".$normalizedDomain")) {
        throw "Subdomain must be a child of $normalizedDomain."
    }
}

function New-Plan {
    Assert-SafeSubdomain -ParentDomain $Domain -TargetSubdomain $Subdomain

    [pscustomobject]@{
        domain = Normalize-Name -Name $Domain
        subdomain = Normalize-Name -Name $Subdomain
        zoneWideEmailRoutingChanged = $false
        catchAllChanged = $false
        supportSubaddressChanged = $false
        operations = @(
            [pscustomobject]@{
                method = 'GET'
                path = "/zones?account.id={account_id}&name=$(Normalize-Name -Name $Domain)&per_page=1"
            }
            [pscustomobject]@{
                method = 'GET'
                path = "/zones/{zone_id}/email/routing/dns?subdomain=$(Normalize-Name -Name $Subdomain)"
            }
            [pscustomobject]@{
                method = 'GET'
                path = "/zones/{zone_id}/dns_records?name=$(Normalize-Name -Name $Subdomain)&per_page=100"
            }
            [pscustomobject]@{
                method = 'DELETE'
                path = '/zones/{zone_id}/dns_records/{record_id}'
                scope = "only DNS records whose name exactly equals $(Normalize-Name -Name $Subdomain)"
            }
            [pscustomobject]@{
                method = 'GET'
                path = "/zones/{zone_id}/email/routing/dns?subdomain=$(Normalize-Name -Name $Subdomain)"
            }
            [pscustomobject]@{
                method = 'GET'
                path = "/zones/{zone_id}/dns_records?name=$(Normalize-Name -Name $Subdomain)&per_page=100"
            }
        )
    }
}

function Get-LocalSetting {
    param(
        [string]$Name,
        [string]$Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override
    }

    foreach ($target in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable($Name, $target)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $null
}

function Assert-RequiredSetting {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing $Name. Pass it as a parameter or set it in the Process/User/Machine environment."
    }
}

function Invoke-CfApi {
    param(
        [ValidateSet('GET', 'DELETE')]
        [string]$Method,
        [string]$Path,
        [hashtable]$Headers
    )

    $base = $ApiBaseUrl.TrimEnd('/')
    $uri = "$base$Path"
    $lastError = $null

    foreach ($attempt in 1..3) {
        try {
            $response = Invoke-RestMethod -Method $Method -Uri $uri -Headers $Headers
            if ($response.PSObject.Properties['success'] -and -not $response.success) {
                $messages = @($response.errors | ForEach-Object { $_.message }) -join '; '
                throw "Cloudflare API returned success=false for $Method $Path. $messages"
            }
            return $response.result
        } catch {
            $lastError = $_
            if ($attempt -lt 3) {
                Start-Sleep -Seconds $attempt
            }
        }
    }

    throw $lastError
}

function Get-EmailRoutingDnsStatus {
    param(
        [string]$ZoneId,
        [string]$TargetSubdomain,
        [hashtable]$Headers
    )

    $subdomainQuery = [Uri]::EscapeDataString($TargetSubdomain)
    $value = Invoke-CfApi -Method GET -Path "/zones/$ZoneId/email/routing/dns?subdomain=$subdomainQuery" -Headers $Headers
    if ($null -eq $value) {
        return [pscustomobject]@{
            requiredRecordCount = 0
            missingRecordCount = 0
            presentRecordCount = 0
            records = @()
            missingRecords = @()
        }
    }

    $records = @()
    if ($value.PSObject.Properties['records']) {
        $records = @($value.records)
    } else {
        $records = @($value)
    }

    $missingErrors = @()
    if ($value.PSObject.Properties['errors']) {
        $missingErrors = @($value.errors | Where-Object { $_.code -like '*.missing' })
    }

    [pscustomobject]@{
        requiredRecordCount = $records.Count
        missingRecordCount = $missingErrors.Count
        presentRecordCount = [Math]::Max(0, $records.Count - $missingErrors.Count)
        records = $records
        missingRecords = @($missingErrors | ForEach-Object { $_.missing })
    }
}

function Get-DnsRecords {
    param(
        [string]$ZoneId,
        [string]$TargetSubdomain,
        [hashtable]$Headers
    )

    $nameQuery = [Uri]::EscapeDataString($TargetSubdomain)
    $records = Invoke-CfApi -Method GET -Path "/zones/$ZoneId/dns_records?name=$nameQuery&per_page=100" -Headers $Headers
    return @($records | Where-Object { (Normalize-Name -Name $_.name) -eq $TargetSubdomain })
}

function Convert-RecordSummary {
    param([object[]]$Records)

    return @($Records | ForEach-Object {
        [pscustomobject]@{
            id = $_.id
            type = $_.type
            name = $_.name
            priority = $_.priority
            ttl = $_.ttl
        }
    })
}

Assert-SafeSubdomain -ParentDomain $Domain -TargetSubdomain $Subdomain
$Domain = Normalize-Name -Name $Domain
$Subdomain = Normalize-Name -Name $Subdomain

if ($PlanOnly) {
    New-Plan | ConvertTo-Json -Depth 20
    exit 0
}

if (-not $Apply) {
    throw 'Refusing to change Cloudflare state without -Apply. Use -PlanOnly to inspect the deletion plan.'
}

$resolvedEmail = Get-LocalSetting -Name 'CLOUDFLARE_EMAIL' -Override $CloudflareEmail
if (-not $resolvedEmail) {
    $resolvedEmail = Get-LocalSetting -Name 'CF_EMAIL'
}
$resolvedApiKey = Get-LocalSetting -Name 'CLOUDFLARE_API_KEY' -Override $CloudflareApiKey
if (-not $resolvedApiKey) {
    $resolvedApiKey = Get-LocalSetting -Name 'CF_API_KEY'
}
$resolvedAccountId = Get-LocalSetting -Name 'CLOUDFLARE_ACCOUNT_ID' -Override $AccountId
if (-not $resolvedAccountId) {
    $resolvedAccountId = Get-LocalSetting -Name 'CF_ACCOUNT_ID'
}

Assert-RequiredSetting -Name 'CLOUDFLARE_EMAIL/CF_EMAIL' -Value $resolvedEmail
Assert-RequiredSetting -Name 'CLOUDFLARE_API_KEY/CF_API_KEY' -Value $resolvedApiKey
Assert-RequiredSetting -Name 'CLOUDFLARE_ACCOUNT_ID/CF_ACCOUNT_ID' -Value $resolvedAccountId

$headers = @{
    'X-Auth-Email' = $resolvedEmail
    'X-Auth-Key' = $resolvedApiKey
    'Content-Type' = 'application/json'
}

$domainQuery = [Uri]::EscapeDataString($Domain)
$accountQuery = [Uri]::EscapeDataString($resolvedAccountId)
$zones = Invoke-CfApi -Method GET -Path "/zones?account.id=$accountQuery&name=$domainQuery&per_page=1" -Headers $headers
$zone = @($zones | Where-Object { (Normalize-Name -Name $_.name) -eq $Domain }) | Select-Object -First 1
if (-not $zone) {
    throw "Cloudflare zone was not found for $Domain in the configured account."
}

$zoneId = $zone.id
$emailRoutingBefore = Get-EmailRoutingDnsStatus -ZoneId $zoneId -TargetSubdomain $Subdomain -Headers $headers
$dnsBefore = @(Get-DnsRecords -ZoneId $zoneId -TargetSubdomain $Subdomain -Headers $headers)
$deleted = @()

foreach ($record in $dnsBefore) {
    [void](Invoke-CfApi -Method DELETE -Path "/zones/$zoneId/dns_records/$($record.id)" -Headers $headers)
    $deleted += $record
}

$emailRoutingAfter = Get-EmailRoutingDnsStatus -ZoneId $zoneId -TargetSubdomain $Subdomain -Headers $headers
$dnsAfter = @(Get-DnsRecords -ZoneId $zoneId -TargetSubdomain $Subdomain -Headers $headers)

[pscustomobject]@{
    domain = $Domain
    subdomain = $Subdomain
    zoneId = $zoneId
    zoneStatus = $zone.status
    zoneWideEmailRoutingChanged = $false
    catchAllChanged = $false
    supportSubaddressChanged = $false
    before = [pscustomobject]@{
        emailRoutingDnsRequiredRecordCount = $emailRoutingBefore.requiredRecordCount
        emailRoutingDnsMissingRecordCount = $emailRoutingBefore.missingRecordCount
        emailRoutingDnsPresentRecordCount = $emailRoutingBefore.presentRecordCount
        dnsRecordCount = $dnsBefore.Count
        dnsRecords = @(Convert-RecordSummary -Records $dnsBefore)
    }
    deleted = [pscustomobject]@{
        dnsRecordCount = $deleted.Count
        dnsRecords = @(Convert-RecordSummary -Records $deleted)
    }
    after = [pscustomobject]@{
        emailRoutingDnsRequiredRecordCount = $emailRoutingAfter.requiredRecordCount
        emailRoutingDnsMissingRecordCount = $emailRoutingAfter.missingRecordCount
        emailRoutingDnsPresentRecordCount = $emailRoutingAfter.presentRecordCount
        dnsRecordCount = $dnsAfter.Count
        dnsRecords = @(Convert-RecordSummary -Records $dnsAfter)
    }
} | ConvertTo-Json -Depth 20
