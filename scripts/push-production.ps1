[CmdletBinding()]
param(
    [string]$Remote = 'origin',
    [string]$Branch,
    [switch]$Apply,
    [switch]$PlanOnly,
    [switch]$SkipChecks,
    [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'

$focusedChecks = @(
    'test/cloudflare-email-routing-script.test.mjs',
    'test/github-push-deploy-script.test.mjs',
    'test/wrangler-domain-vars.test.mjs',
    'test/domain-picker.test.mjs',
    'test/mail-domains.test.mjs',
    'test/mailboxes-domain-selection.test.mjs'
)

function Get-CurrentBranch {
    $name = (& git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'Cannot determine current git branch.'
    }
    return $name
}

function Get-TargetBranch {
    if (-not [string]::IsNullOrWhiteSpace($Branch)) {
        return $Branch
    }
    return Get-CurrentBranch
}

function Get-PushArgs {
    param(
        [string]$TargetRemote,
        [string]$TargetBranch,
        [bool]$DoApply
    )

    $pushArgs = @('push')
    if (-not $DoApply) {
        $pushArgs += '--dry-run'
    }
    $pushArgs += $TargetRemote
    $pushArgs += "HEAD:$TargetBranch"
    return $pushArgs
}

function ConvertTo-DisplayCommand {
    param([string[]]$CommandArgs)
    return @('git') + $CommandArgs
}

function New-Plan {
    param(
        [string]$TargetRemote,
        [string]$TargetBranch
    )

    [pscustomobject]@{
        remote = $TargetRemote
        branch = $TargetBranch
        defaultCommand = @(ConvertTo-DisplayCommand -CommandArgs @(Get-PushArgs -TargetRemote $TargetRemote -TargetBranch $TargetBranch -DoApply $false))
        applyCommand = @(ConvertTo-DisplayCommand -CommandArgs @(Get-PushArgs -TargetRemote $TargetRemote -TargetBranch $TargetBranch -DoApply $true))
        cloudflare = [pscustomobject]@{
            usesWranglerDeploy = $false
            usesWranglerLogin = $false
            requiresCloudflareCredentials = $false
        }
        focusedChecks = $focusedChecks
    }
}

function Invoke-FocusedChecks {
    $output = & node --test @focusedChecks 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        command = @('node', '--test') + $focusedChecks
        exitCode = $exitCode
        output = @($output | ForEach-Object { $_.ToString() })
    }
}

function Assert-CleanWorktree {
    if ($AllowDirty) {
        return [pscustomobject]@{
            clean = $false
            skipped = $true
            reason = 'Skipped by -AllowDirty.'
        }
    }

    $status = @(& git status --porcelain)
    if ($status.Count -gt 0) {
        throw "Refusing to push with uncommitted changes. Commit first or pass -AllowDirty. Changed entries: $($status.Count)"
    }

    return [pscustomobject]@{
        clean = $true
        skipped = $false
    }
}

function Invoke-GitPush {
    param(
        [string]$TargetRemote,
        [string]$TargetBranch,
        [bool]$DoApply
    )

    $pushArgs = Get-PushArgs -TargetRemote $TargetRemote -TargetBranch $TargetBranch -DoApply $DoApply
    $output = & git @pushArgs 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        command = @(ConvertTo-DisplayCommand -CommandArgs $pushArgs)
        exitCode = $exitCode
        output = @($output | ForEach-Object { $_.ToString() })
    }
}

$targetBranch = Get-TargetBranch

if ($PlanOnly) {
    New-Plan -TargetRemote $Remote -TargetBranch $targetBranch | ConvertTo-Json -Depth 20
    exit 0
}

$checks = $null
if (-not $SkipChecks) {
    $checks = Invoke-FocusedChecks
    if ($checks.exitCode -ne 0) {
        [pscustomobject]@{
            remote = $Remote
            branch = $targetBranch
            applied = $false
            checks = $checks
            push = $null
        } | ConvertTo-Json -Depth 20
        exit $checks.exitCode
    }
}

$worktree = Assert-CleanWorktree
$push = Invoke-GitPush -TargetRemote $Remote -TargetBranch $targetBranch -DoApply ([bool]$Apply)

[pscustomobject]@{
    remote = $Remote
    branch = $targetBranch
    applied = [bool]$Apply
    checks = $checks
    worktree = $worktree
    push = $push
} | ConvertTo-Json -Depth 20

exit $push.exitCode
