<#
.SYNOPSIS
    Clone/update repos from repos.json and generate a VS Code multi-root workspace.

.DESCRIPTION
    Idempotent: safe to run any time.
      - Missing repo            -> git clone (default branch)
      - Present, clean, on default branch -> fetch + pull --ff-only
      - Present, dirty or on another branch -> fetch only, reported, never touched
    Then writes <root>/<workspaceName>[.<Name>].local.code-workspace containing
    this hub repo plus the selected repos (and optionally their worktrees).
    workspaceName defaults to this folder's name; set it in repos.json to override.

.EXAMPLE
    ./scripts/setup.ps1                              # all non-optional repos
.EXAMPLE
    ./scripts/setup.ps1 -Tag ui -Name ui -Open       # <workspaceName>.ui.local.code-workspace, open in VS Code
.EXAMPLE
    ./scripts/setup.ps1 -Only web-app,api-service -IncludeWorktrees
.EXAMPLE
    ./scripts/setup.ps1 -NoGit                       # only regenerate the workspace file
#>
[CmdletBinding()]
param(
    # Repo names to include (exact match). Combined with -Tag as a union.
    [string[]] $Only,
    # Include repos having any of these tags.
    [string[]] $Tag,
    # Workspace suffix: <workspaceName>.<Name>.local.code-workspace. Empty -> <workspaceName>.local.code-workspace.
    [string] $Name,
    # Skip clone/fetch/pull; only generate the workspace file from what exists on disk.
    [switch] $NoGit,
    # Fetch only, never pull.
    [switch] $NoPull,
    # Add each repo's linked worktrees as extra workspace folders.
    [switch] $IncludeWorktrees,
    # Open the generated workspace with `code`.
    [switch] $Open,
    # Path to manifest; default <root>/repos.json.
    [string] $Manifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Accept "a,b" as one string too (pwsh -File / bash / cmd don't split arrays).
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Tag  = @($Tag  | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# ---------- paths ----------
$Root = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
if (-not $Manifest) { $Manifest = Join-Path $Root 'repos.json' }
if (-not (Test-Path $Manifest)) { throw "Manifest not found: $Manifest" }

$config       = Get-Content $Manifest -Raw | ConvertFrom-Json
$reposDirRel  = if ($config.PSObject.Properties['reposDir'])     { $config.reposDir }     else { 'repos' }
$wtDirRel     = if ($config.PSObject.Properties['worktreesDir']) { $config.worktreesDir } else { 'worktrees' }
$wsName       = if ($config.PSObject.Properties['workspaceName']) { $config.workspaceName } else { Split-Path $Root -Leaf }
$extensions   = if ($config.PSObject.Properties['extensions'])    { @($config.extensions) } else { @() }
$ReposDir     = Join-Path $Root $reposDirRel
New-Item -ItemType Directory -Force -Path $ReposDir | Out-Null

function Get-Prop($obj, [string]$prop, $default = $null) {
    if ($obj.PSObject.Properties[$prop]) { $obj.$prop } else { $default }
}

function ConvertTo-WorkspacePath([string]$fullPath) {
    [System.IO.Path]::GetRelativePath($Root, $fullPath).Replace('\', '/')
}

function Invoke-Git {
    param([string]$RepoPath, [Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    $out = & git -C $RepoPath @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in ${RepoPath}:`n$out" }
    return $out
}

# ---------- validate manifest ----------
$dupes = $config.repos | Group-Object name | Where-Object Count -gt 1
if ($dupes) { throw "Duplicate repo names in manifest: $($dupes.Name -join ', ')" }

# ---------- warn if clone dirs are not gitignored ----------
foreach ($d in @($reposDirRel, $wtDirRel)) {
    & git -C $Root check-ignore -q "$d/" 2>$null
    if ($LASTEXITCODE -ne 0 -and (Test-Path (Join-Path $Root '.git'))) {
        Write-Warning "'$d/' is not gitignored in $wsName. Add it to .gitignore."
    }
}

# ---------- select repos ----------
$explicit = ($Only.Count -gt 0) -or ($Tag.Count -gt 0)
$selected = $config.repos | Where-Object {
    $tags = @(Get-Prop $_ 'tags' @())
    if ($explicit) {
        ($Only -contains $_.name) -or
        [bool]($tags | Where-Object { $Tag -contains $_ })
    } else {
        -not (Get-Prop $_ 'optional' $false)
    }
}

if ($Only.Count) {
    $unknown = $Only | Where-Object { $config.repos.name -notcontains $_ }
    if ($unknown) { Write-Warning "Not in manifest: $($unknown -join ', ')" }
}
if (-not $selected) { throw 'No repos selected. Check -Only / -Tag values.' }

# ---------- clone / update ----------
$report = [System.Collections.Generic.List[object]]::new()

foreach ($repo in $selected) {
    $path   = Join-Path $ReposDir $repo.name
    $status = ''
    try {
        if ($NoGit) {
            $status = if (Test-Path (Join-Path $path '.git')) { 'present' } else { 'MISSING (skipped, -NoGit)' }
        }
        elseif (-not (Test-Path $path)) {
            Write-Host "Cloning $($repo.name)..." -ForegroundColor Cyan
            & git clone --branch $repo.defaultBranch $repo.url $path
            if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
            $status = 'cloned'
        }
        elseif (-not (Test-Path (Join-Path $path '.git'))) {
            $status = 'ERROR: folder exists but is not a git repo'
        }
        else {
            Write-Host "Updating $($repo.name)..." -ForegroundColor Cyan
            Invoke-Git $path fetch --prune --quiet | Out-Null
            $branch = (Invoke-Git $path rev-parse --abbrev-ref HEAD).Trim()
            $dirty  = [bool](Invoke-Git $path status --porcelain)

            if ($NoPull)                             { $status = "fetched (on $branch)" }
            elseif ($branch -ne $repo.defaultBranch) { $status = "fetched only - on branch '$branch'" }
            elseif ($dirty)                          { $status = 'fetched only - uncommitted changes' }
            else {
                $null = & git -C $path pull --ff-only --quiet 2>&1
                $status = if ($LASTEXITCODE -eq 0) { 'up to date' } else { 'fetched - pull --ff-only failed (diverged?)' }
            }
        }
    }
    catch { $status = "ERROR: $($_.Exception.Message.Split("`n")[0])" }

    $report.Add([pscustomobject]@{ Repo = $repo.name; Status = $status })
}

# ---------- build workspace ----------
$folders = [System.Collections.Generic.List[object]]::new()
$folders.Add([ordered]@{ name = $wsName; path = '.' })

foreach ($repo in $selected) {
    $path = Join-Path $ReposDir $repo.name
    if (-not (Test-Path (Join-Path $path '.git'))) { continue }

    $folders.Add([ordered]@{ name = $repo.name; path = (ConvertTo-WorkspacePath $path) })

    if ($IncludeWorktrees) {
        $wtLines = & git -C $path worktree list --porcelain 2>$null
        $wtPaths = $wtLines | Where-Object { $_ -like 'worktree *' } |
                   ForEach-Object { $_.Substring(9) } |
                   Select-Object -Skip 1    # first entry is the main checkout
        foreach ($wt in $wtPaths) {
            $full = [System.IO.Path]::GetFullPath($wt)
            $leaf = Split-Path $full -Leaf
            $folders.Add([ordered]@{ name = "$($repo.name) ⎇ $leaf"; path = (ConvertTo-WorkspacePath $full) })
        }
    }
}

$hidden = [ordered]@{ $reposDirRel = $true; $wtDirRel = $true }

$workspace = [ordered]@{
    folders  = $folders
    settings = [ordered]@{
        'files.exclude'                   = $hidden
        'search.exclude'                  = $hidden
        'files.watcherExclude'            = [ordered]@{ "**/$reposDirRel/**" = $true; "**/$wtDirRel/**" = $true }
        'git.openRepositoryInParentFolders' = 'never'
        'git.repositoryScanMaxDepth'      = 1
    }
    extensions = [ordered]@{
        recommendations = @($extensions)
    }
}

$fileName = if ($Name) { "$wsName.$Name.local.code-workspace" } else { "$wsName.local.code-workspace" }
$wsPath   = Join-Path $Root $fileName
$workspace | ConvertTo-Json -Depth 10 | Set-Content -Path $wsPath -Encoding utf8

# ---------- report ----------
Write-Host ''
$report | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host
Write-Host "Workspace: $wsPath ($($folders.Count) folders)" -ForegroundColor Green

if ($Open) {
    if (Get-Command code -ErrorAction SilentlyContinue) { & code $wsPath }
    else { Write-Warning "'code' not on PATH; open $fileName manually." }
}

# Non-zero exit so agents/CI notice failed repos.
if (@($report | Where-Object Status -like 'ERROR*').Count -gt 0) { exit 1 }
exit 0
