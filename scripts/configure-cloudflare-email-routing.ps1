[CmdletBinding()]
param(
    [string]$Domain = 'aibus.us.ci',
    [string]$WorkerName = 'whgbdbse',
    [string]$Subdomain = 'test.aibus.us.ci',
    [string]$WorkerUrl = 'https://whgbdbse.1908912779.workers.dev',
    [string]$CloudflareEmail,
    [string]$CloudflareApiKey,
    [string]$AccountId,
    [string]$ApiBaseUrl = 'https://api.cloudflare.com/client/v4',
    [string]$AdminName,
    [string]$AdminPassword,
    [string]$AdminToken,
    [int]$SyncWaitSeconds = 60,
    [int]$SyncPollSeconds = 3,
    [switch]$Apply,
    [switch]$PlanOnly,
    [switch]$SkipWorkerProbe
)

$ErrorActionPreference = 'Stop'

function New-CatchAllBody {
    param([string]$TargetWorker)

    [ordered]@{
        name = "catch-all to $TargetWorker"
        enabled = $true
        matchers = @(
            [ordered]@{
                type = 'all'
            }
        )
        actions = @(
            [ordered]@{
                type = 'worker'
                value = @($TargetWorker)
            }
        )
    }
}

function New-Plan {
    [pscustomobject]@{
        domain = $Domain
        workerName = $WorkerName
        subdomain = $Subdomain
        workerUrl = $WorkerUrl
        syncWaitSeconds = $SyncWaitSeconds
        operations = @(
            [pscustomobject]@{
                method = 'GET'
                path = "/zones?account.id={account_id}&name=$Domain&per_page=1"
            }
            [pscustomobject]@{
                method = 'POST'
                path = '/zones/{zone_id}/email/routing/dns'
            }
            [pscustomobject]@{
                method = 'POST'
                path = '/zones/{zone_id}/email/routing/dns'
                body = [ordered]@{ name = $Subdomain }
            }
            [pscustomobject]@{
                method = 'POST'
                path = '/zones/{zone_id}/email/routing/enable'
            }
            [pscustomobject]@{
                method = 'PUT'
                path = '/zones/{zone_id}/email/routing/rules/catch_all'
                body = New-CatchAllBody -TargetWorker $WorkerName
            }
            [pscustomobject]@{
                method = 'PATCH'
                path = '/zones/{zone_id}/email/routing'
                body = [ordered]@{ support_subaddress = $true }
            }
            [pscustomobject]@{
                method = 'GET'
                path = '/zones/{zone_id}/email/routing'
            }
            [pscustomobject]@{
                method = 'GET'
                path = '/zones/{zone_id}/email/routing/rules/catch_all'
            }
            [pscustomobject]@{
                method = 'GET'
                path = '/zones/{zone_id}/email/routing/dns'
            }
            [pscustomobject]@{
                method = 'GET'
                path = "/zones/{zone_id}/email/routing/dns?subdomain=$Subdomain"
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
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method,
        [string]$Path,
        [object]$Body = $null,
        [hashtable]$Headers
    )

    $base = $ApiBaseUrl.TrimEnd('/')
    $uri = "$base$Path"
    $lastError = $null

    foreach ($attempt in 1..3) {
        try {
            $parameters = @{
                Method = $Method
                Uri = $uri
                Headers = $Headers
            }
            if ($null -ne $Body) {
                $parameters['ContentType'] = 'application/json'
                $parameters['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress)
            }

            $response = Invoke-RestMethod @parameters
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

function Get-RecordCount {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0
    }
    if ($Value.PSObject.Properties['records']) {
        return @($Value.records).Count
    }
    return @($Value).Count
}

function Get-Records {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value.PSObject.Properties['records']) {
        return @($Value.records)
    }
    return @($Value)
}

function Invoke-WorkerProbe {
    if ($SkipWorkerProbe) {
        return [pscustomobject]@{
            attempted = $false
            reason = 'Skipped by -SkipWorkerProbe.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($WorkerUrl)) {
        return [pscustomobject]@{
            attempted = $false
            reason = 'No WorkerUrl was provided.'
        }
    }

    $base = $WorkerUrl.TrimEnd('/')
    try {
        if (-not [string]::IsNullOrWhiteSpace($AdminToken)) {
            $session = Invoke-WebRequest -Method GET -Uri "$base/api/session" -Headers @{ 'X-Admin-Token' = $AdminToken } -UseBasicParsing
            $json = $session.Content | ConvertFrom-Json
            return [pscustomobject]@{
                attempted = $true
                mode = 'admin-token'
                statusCode = [int]$session.StatusCode
                authenticated = [bool]$json.authenticated
                role = $json.role
                strictAdmin = [bool]$json.strictAdmin
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($AdminName) -and -not [string]::IsNullOrWhiteSpace($AdminPassword)) {
            $loginBody = @{ username = $AdminName; password = $AdminPassword } | ConvertTo-Json -Compress
            $login = Invoke-WebRequest -Method POST -Uri "$base/api/login" -ContentType 'application/json' -Body $loginBody -UseBasicParsing
            $cookieHeader = @($login.Headers['Set-Cookie'])[0]
            $cookie = if ($cookieHeader) { ($cookieHeader -split ';')[0] } else { '' }
            if ([string]::IsNullOrWhiteSpace($cookie)) {
                throw 'Login succeeded but did not return a session cookie.'
            }
            $session = Invoke-WebRequest -Method GET -Uri "$base/api/session" -Headers @{ Cookie = $cookie } -UseBasicParsing
            $json = $session.Content | ConvertFrom-Json
            return [pscustomobject]@{
                attempted = $true
                mode = 'login'
                loginStatusCode = [int]$login.StatusCode
                statusCode = [int]$session.StatusCode
                authenticated = [bool]$json.authenticated
                role = $json.role
                strictAdmin = [bool]$json.strictAdmin
            }
        }

        return [pscustomobject]@{
            attempted = $false
            reason = 'No AdminToken or AdminName/AdminPassword was provided.'
        }
    } catch {
        return [pscustomobject]@{
            attempted = $true
            error = $_.Exception.Message
        }
    }
}

function Wait-EmailRoutingReady {
    param(
        [string]$ZoneId,
        [hashtable]$Headers
    )

    $maxWait = [Math]::Max(0, $SyncWaitSeconds)
    $pollSeconds = [Math]::Max(1, $SyncPollSeconds)
    $deadline = (Get-Date).AddSeconds($maxWait)
    $lastSettings = $null

    do {
        $lastSettings = Invoke-CfApi -Method GET -Path "/zones/$ZoneId/email/routing" -Headers $Headers
        $isReady = [bool]$lastSettings.enabled -and
            ($lastSettings.status -eq 'ready') -and
            [bool]$lastSettings.support_subaddress

        if ($lastSettings.PSObject.Properties['synced']) {
            $isReady = $isReady -and [bool]$lastSettings.synced
        }

        if ($isReady -or $maxWait -eq 0) {
            return $lastSettings
        }

        Start-Sleep -Seconds $pollSeconds
    } while ((Get-Date) -lt $deadline)

    return $lastSettings
}

if ($PlanOnly) {
    New-Plan | ConvertTo-Json -Depth 20
    exit 0
}

if (-not $Apply) {
    throw 'Refusing to change Cloudflare state without -Apply. Use -PlanOnly to inspect the API plan.'
}

$resolvedEmail = Get-LocalSetting -Name 'CLOUDFLARE_EMAIL' -Override $CloudflareEmail
$resolvedApiKey = Get-LocalSetting -Name 'CLOUDFLARE_API_KEY' -Override $CloudflareApiKey
$resolvedAccountId = Get-LocalSetting -Name 'CLOUDFLARE_ACCOUNT_ID' -Override $AccountId

Assert-RequiredSetting -Name 'CLOUDFLARE_EMAIL' -Value $resolvedEmail
Assert-RequiredSetting -Name 'CLOUDFLARE_API_KEY' -Value $resolvedApiKey
Assert-RequiredSetting -Name 'CLOUDFLARE_ACCOUNT_ID' -Value $resolvedAccountId

$headers = @{
    'X-Auth-Email' = $resolvedEmail
    'X-Auth-Key' = $resolvedApiKey
    'Content-Type' = 'application/json'
}

$domainQuery = [Uri]::EscapeDataString($Domain)
$accountQuery = [Uri]::EscapeDataString($resolvedAccountId)
$zones = Invoke-CfApi -Method GET -Path "/zones?account.id=$accountQuery&name=$domainQuery&per_page=1" -Headers $headers
$zone = @($zones | Where-Object { $_.name -eq $Domain }) | Select-Object -First 1
if (-not $zone) {
    throw "Cloudflare zone was not found for $Domain in the configured account."
}

$zoneId = $zone.id

[void](Invoke-CfApi -Method POST -Path "/zones/$zoneId/email/routing/dns" -Headers $headers)
[void](Invoke-CfApi -Method POST -Path "/zones/$zoneId/email/routing/dns" -Body ([ordered]@{ name = $Subdomain }) -Headers $headers)
[void](Invoke-CfApi -Method POST -Path "/zones/$zoneId/email/routing/enable" -Headers $headers)
[void](Invoke-CfApi -Method PUT -Path "/zones/$zoneId/email/routing/rules/catch_all" -Body (New-CatchAllBody -TargetWorker $WorkerName) -Headers $headers)
[void](Invoke-CfApi -Method PATCH -Path "/zones/$zoneId/email/routing" -Body ([ordered]@{ support_subaddress = $true }) -Headers $headers)

$settings = Wait-EmailRoutingReady -ZoneId $zoneId -Headers $headers
$catchAll = Invoke-CfApi -Method GET -Path "/zones/$zoneId/email/routing/rules/catch_all" -Headers $headers
$apexDns = Invoke-CfApi -Method GET -Path "/zones/$zoneId/email/routing/dns" -Headers $headers
$subdomainQuery = [Uri]::EscapeDataString($Subdomain)
$subdomainDns = Invoke-CfApi -Method GET -Path "/zones/$zoneId/email/routing/dns?subdomain=$subdomainQuery" -Headers $headers
$workerProbe = Invoke-WorkerProbe

$subdomainRecords = @(Get-Records -Value $subdomainDns | ForEach-Object {
    [pscustomobject]@{
        type = $_.type
        name = $_.name
        content = $_.content
        priority = $_.priority
        ttl = $_.ttl
    }
})

[pscustomobject]@{
    domain = $Domain
    zoneId = $zoneId
    zoneStatus = $zone.status
    routing = [pscustomobject]@{
        enabled = [bool]$settings.enabled
        status = $settings.status
        synced = [bool]$settings.synced
        adminLocked = [bool]$settings.admin_locked
        supportSubaddress = [bool]$settings.support_subaddress
    }
    catchAll = [pscustomobject]@{
        enabled = [bool]$catchAll.enabled
        name = $catchAll.name
        matchers = $catchAll.matchers
        actions = $catchAll.actions
    }
    dns = [pscustomobject]@{
        apexRecordCount = Get-RecordCount -Value $apexDns
        subdomain = $Subdomain
        subdomainRecordCount = Get-RecordCount -Value $subdomainDns
        subdomainRecords = $subdomainRecords
    }
    workerProbe = $workerProbe
} | ConvertTo-Json -Depth 20
