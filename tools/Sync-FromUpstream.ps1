#Requires -Version 7.0
<#
.SYNOPSIS
  Merges updates from the original repo (upstream) into a copy of it, keeping the copy's own edits.

.DESCRIPTION
  Adds the original repo as a second remote and merges it in:
    1. Makes a timestamped backup branch of the copy's branch.
    2. Adds the original repo as the 'upstream' remote (if it isn't already) and fetches it.
    3. Merges upstream/<branch> into the copy.
    4. Stops on conflicts and lists the files to resolve.
    5. Pushes the result to origin (asks first; -Confirm:$false skips the prompt).

  Run it from a clone of the COPY (the new repo), or pass -RepoPath. It refuses to start with
  uncommitted changes, so a failed merge can always be undone with 'git merge --abort' or the backup branch.

.EXAMPLE
  ./Sync-FromUpstream.ps1 -RepoPath C:\src\new-repo
.EXAMPLE
  # First sync into a copy made by uploading files or "Use this template" (no shared history)
  ./Sync-FromUpstream.ps1 -RepoPath C:\src\new-repo -AllowUnrelatedHistories
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$RepoPath = (Get-Location).Path,
    [string]$UpstreamUrl = 'https://github.com/akashic/BGLConnector.git',
    [string]$Branch = 'main',
    [string]$UpstreamBranch = 'main',
    [switch]$AllowUnrelatedHistories
)
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    # Runs git and throws on a non-zero exit code, unless -AllowFailure is set. Pass git's long options
    # (--verbose, --delete): PowerShell would take short ones like -v or -d as its own -Verbose or -Debug.
    param([Parameter(ValueFromRemainingArguments)][string[]]$GitArgs, [switch]$AllowFailure)
    # git writes progress to stderr; stringify it so PowerShell doesn't show it as an error.
    $output = & git -C $RepoPath @GitArgs 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE):`n$($output -join "`n")"
    }
    $output
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is not installed or not on PATH.' }
Invoke-Git rev-parse --is-inside-work-tree | Out-Null
if (Invoke-Git status --porcelain) {
    throw 'The repo has uncommitted changes. Commit or stash them first, so the merge can be undone cleanly.'
}

# 1. Safety branch
Write-Host "== Updating '$Branch' from origin ==" -ForegroundColor Cyan
Invoke-Git checkout $Branch | Out-Null
Invoke-Git pull origin $Branch | Out-Host
$backup = "backup-before-upstream-merge-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Invoke-Git branch $backup | Out-Null
Write-Host "Backup branch: $backup"

# 2. Upstream remote
$existing = Invoke-Git remote get-url upstream -AllowFailure
if ($LASTEXITCODE -ne 0) {
    Invoke-Git remote add upstream $UpstreamUrl | Out-Null
    Write-Host "Added remote 'upstream' -> $UpstreamUrl"
}
elseif ("$existing".Trim() -ne $UpstreamUrl) {
    throw "Remote 'upstream' already points to $existing, not $UpstreamUrl. Fix it with 'git remote set-url upstream <url>' or pass -UpstreamUrl."
}
Write-Host "== Fetching upstream ==" -ForegroundColor Cyan
Invoke-Git fetch upstream | Out-Host
Invoke-Git remote --verbose | Out-Host

# 3. Merge. Without a common ancestor git refuses the merge, so check first and explain.
$target = "upstream/$UpstreamBranch"
Invoke-Git merge-base HEAD $target -AllowFailure | Out-Null
$related = $LASTEXITCODE -eq 0
if (-not $related -and -not $AllowUnrelatedHistories) {
    throw "The copy and $target share no history (the copy wasn't made as a fork). Re-run with -AllowUnrelatedHistories, and expect many conflicts on the first sync."
}
$mergeArgs = @('merge', $target, '--no-edit')
if (-not $related) { $mergeArgs += '--allow-unrelated-histories' }

$headBefore = "$(Invoke-Git rev-parse HEAD)".Trim()
Write-Host "== Merging $target into $Branch ==" -ForegroundColor Cyan
Invoke-Git @mergeArgs -AllowFailure | Out-Host

# 4. Conflicts: stop here and leave the merge in progress for the user to resolve.
$conflicts = Invoke-Git diff --name-only --diff-filter=U
if ($conflicts) {
    Write-Host "`nMerge conflicts in:" -ForegroundColor Yellow
    $conflicts | ForEach-Object { Write-Host "  $_" }
    Write-Host @"

For each file, edit the <<<<<<< / ======= / >>>>>>> blocks to what you want to keep and delete the
marker lines (VS Code's Accept Current / Incoming / Both buttons help). Then:

  git -C "$RepoPath" add <file>
  git -C "$RepoPath" commit --no-edit
  git -C "$RepoPath" push origin $Branch

To back out instead:   git -C "$RepoPath" merge --abort
To restore the backup: git -C "$RepoPath" reset --hard $backup
"@
    exit 1
}
if ($LASTEXITCODE -ne 0) { throw "Merge failed. To back out: git -C `"$RepoPath`" merge --abort" }

if ("$(Invoke-Git rev-parse HEAD)".Trim() -eq $headBefore) {
    Write-Host "`nAlready up to date with $target. Nothing to push." -ForegroundColor Green
    Invoke-Git branch --delete $backup | Out-Null
    exit 0
}

# 5. Push
if ($PSCmdlet.ShouldProcess("origin/$Branch", 'Push merged upstream changes')) {
    Invoke-Git push origin $Branch | Out-Host
    Write-Host "`nPushed. The backup branch '$backup' is local only; delete it with 'git branch -D $backup' once you're happy." -ForegroundColor Green
}
else {
    Write-Host "`nMerged locally but not pushed. Push with: git -C `"$RepoPath`" push origin $Branch"
}
