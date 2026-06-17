[CmdletBinding()]
param(
    [string]$Remote = 'origin',
    [string]$Branch,
    [string]$GitCommand = 'git',
    [string]$NodeCommand = 'node',
    [switch]$Apply,
    [switch]$PlanOnly,
    [switch]$SkipChecks,
    [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'

$focusedChecks = @(
    'test/cloudflare-email-routing-script.test.mjs',
    'test/cloudflare-email-routing-removal-script.test.mjs',
    'test/github-push-deploy-script.test.mjs',
    'test/wrangler-domain-vars.test.mjs',
    'test/domain-picker.test.mjs',
    'test/mail-domains.test.mjs',
    'test/mailboxes-domain-selection.test.mjs'
)

function Invoke-NativeCommand {
    param(
        [string]$FilePath,
        [string[]]$CommandArgs
    )

    $oldErrorActionPreference = $ErrorActionPreference
    $nativePreference = Get-Variable -Name 'PSNativeCommandUseErrorActionPreference' -ErrorAction SilentlyContinue
    $oldNativePreference = $null
    if ($nativePreference) {
        $oldNativePreference = $PSNativeCommandUseErrorActionPreference
    }

    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $output = & $FilePath @CommandArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
        if ($nativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }

    return [pscustomobject]@{
        exitCode = $exitCode
        output = @($output | ForEach-Object { $_.ToString() })
    }
}

function Get-CurrentBranch {
    $result = Invoke-NativeCommand -FilePath $GitCommand -CommandArgs @('branch', '--show-current')
    if ($result.exitCode -ne 0) {
        throw "git branch --show-current failed: $($result.output -join "`n")"
    }

    $name = ($result.output -join "`n").Trim()
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
    $commandArgs = @('--test') + $focusedChecks
    $result = Invoke-NativeCommand -FilePath $NodeCommand -CommandArgs $commandArgs
    return [pscustomobject]@{
        command = @('node', '--test') + $focusedChecks
        exitCode = $result.exitCode
        output = $result.output
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

    $result = Invoke-NativeCommand -FilePath $GitCommand -CommandArgs @('status', '--porcelain')
    if ($result.exitCode -ne 0) {
        throw "git status --porcelain failed: $($result.output -join "`n")"
    }

    $status = @($result.output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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
    $result = Invoke-NativeCommand -FilePath $GitCommand -CommandArgs $pushArgs
    return [pscustomobject]@{
        command = @(ConvertTo-DisplayCommand -CommandArgs $pushArgs)
        exitCode = $result.exitCode
        output = $result.output
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
