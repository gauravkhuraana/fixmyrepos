# NOTE: This file must be saved as UTF-8 with BOM for Windows PowerShell 5.1 compatibility.
<#
.SYNOPSIS
    Scans all your GitHub repos, finds missing/weak .gitignore files,
    fixes them, and opens PRs -- so your profile shows correct language stats
    and repos stay lean.

.DESCRIPTION
    Single-file, zero-dependency script. Just needs PowerShell + Git + a GitHub token.

    What it does:
      1. Lists all your repos via GitHub API
      2. Detects committed junk (node_modules, __pycache__, bin/obj, coverage, etc.)
      3. Clones problematic repos, adds/improves .gitignore, removes cached junk
      4. Pushes a branch "improvement-YYYY-MM-DD" and opens a PR
      5. Generates a Markdown report with links to every PR

    You stay in full control -- every fix is a PR you can review, merge, or close.

.PARAMETER GitHubUser
    Your GitHub username. If omitted, you'll be prompted.

.PARAMETER GitHubToken
    GitHub Personal Access Token with "repo" scope.
    If omitted, checks $env:GITHUB_TOKEN, then prompts.
    Press Enter to skip -- runs in scan-only mode (no token needed for public repos).
    Create one at: https://github.com/settings/tokens

.PARAMETER RepoName
    Target a specific repo instead of scanning all. Accepts:
      - Full name: "octocat/my-repo"
      - Short name: "my-repo" (auto-prefixed with GitHubUser)
      - Comma-separated: "repo1,repo2"
    If omitted, scans all repos.

.PARAMETER WorkDir
    Where repos get cloned temporarily. Default: ./work

.PARAMETER DryRun
    Scan and report only -- no cloning, no branches, no PRs.

.PARAMETER SkipArchived
    Skip archived repos. Default: true.

.PARAMETER SkipForks
    Skip forked repos. Default: true.

.PARAMETER DirectPush
    Push fixes directly to the default branch (main/master) instead of creating
    a separate branch and PR. Changes go live immediately. Requires confirmation.

.PARAMETER Revert
    Undo changes made by this tool. Closes open PRs, deletes improvement branches,
    and reverts any direct-push commits. Use with -RepoName to target specific repos.

.PARAMETER ExcludeRepo
    Exclude specific repos from scanning. Accepts:
      - Short name: "my-repo" (auto-prefixed with GitHubUser)
      - Full name: "octocat/my-repo"
      - Comma-separated: "repo1,repo2"
    Only used when scanning all repos (ignored if -RepoName is set).

.EXAMPLE
    # Just run it -- you'll be prompted for what's needed:
    .\Improve-GitHubRepos.ps1

.EXAMPLE
    # Scan public repos WITHOUT a token (report only, no PRs):
    .\Improve-GitHubRepos.ps1 -GitHubUser "octocat"

.EXAMPLE
    # Dry run with token (scans private repos too):
    .\Improve-GitHubRepos.ps1 -GitHubUser "octocat" -GitHubToken $env:GITHUB_TOKEN -DryRun

.EXAMPLE
    # Fix a specific repo only:
    .\Improve-GitHubRepos.ps1 -GitHubUser "octocat" -GitHubToken $env:GITHUB_TOKEN -RepoName "my-project"

.EXAMPLE
    # Fix multiple specific repos:
    .\Improve-GitHubRepos.ps1 -GitHubUser "octocat" -GitHubToken $env:GITHUB_TOKEN -RepoName "repo1,repo2"

.EXAMPLE
    # Full run on all repos:
    .\Improve-GitHubRepos.ps1 -GitHubUser "octocat" -GitHubToken $env:GITHUB_TOKEN

.EXAMPLE
    # Push fixes directly to main (no branch/PR):
    .\Improve-GitHubRepos.ps1 -GitHubUser "octocat" -GitHubToken $env:GITHUB_TOKEN -DirectPush

.EXAMPLE
    # Revert changes on a specific repo:
    .\Improve-GitHubRepos.ps1 -GitHubUser "octocat" -GitHubToken $env:GITHUB_TOKEN -Revert -RepoName "my-project"

.EXAMPLE
    # Revert all changes across all repos:
    .\Improve-GitHubRepos.ps1 -GitHubUser "octocat" -GitHubToken $env:GITHUB_TOKEN -Revert

.EXAMPLE
    # Scan all repos except a few:
    .\Improve-GitHubRepos.ps1 -GitHubUser "octocat" -GitHubToken $env:GITHUB_TOKEN -ExcludeRepo "old-junk,experiments"
#>

[CmdletBinding()]
param(
    [string]$GitHubUser,
    [string]$GitHubToken,
    [string[]]$RepoName,
    [string]$WorkDir,
    [switch]$DryRun,
    [switch]$DirectPush,
    [switch]$Revert,
    [switch]$Cleanup,
    [string[]]$ExcludeRepo,
    [bool]$SkipArchived = $true,
    [bool]$SkipForks = $true,
    [int]$BatchSize = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Handle $PSScriptRoot being empty (e.g., pasted into terminal)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $WorkDir) { $WorkDir = Join-Path $scriptDir "work" }

# ===========================================================================
# SECTION 0: INTERACTIVE SETUP (when run without params)
# ===========================================================================

function Show-Banner {
    Write-Host ""
    Write-Host "  +==============================================================+" -ForegroundColor Cyan
    Write-Host "  |          Improve-GitHubRepos -- .gitignore Fixer             |" -ForegroundColor Cyan
    Write-Host "  |                                                              |" -ForegroundColor Cyan
    Write-Host "  |  Scans your GitHub repos for missing/weak .gitignore files,  |" -ForegroundColor Cyan
    Write-Host "  |  fixes them, and opens PRs so you stay in control.           |" -ForegroundColor Cyan
    Write-Host "  +==============================================================+" -ForegroundColor Cyan
    Write-Host ""
}

# Check git is available
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  ERROR: 'git' is not installed or not on PATH." -ForegroundColor Red
    Write-Host "  Install it from https://git-scm.com and re-run." -ForegroundColor Gray
    exit 1
}

# Track whether we have a token (controls what operations are possible)
$script:HasToken = $false

# Show banner if running interactively without key params
if (-not $GitHubUser -or -not $GitHubToken) {
    Show-Banner
}

# -- Interactive mode menu (show FIRST so user knows what they're signing up for) --
$script:MenuWasShown = $false
$script:ChosenMode = $null   # 'analyze', 'pr', 'direct', 'revert'
$explicitMode = $DryRun -or $DirectPush -or $Revert
if (-not $explicitMode -and -not $GitHubUser -and -not $GitHubToken) {
    $script:MenuWasShown = $true
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  How would you like to run?                              |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  |  [1] Analyse repos (prerequisite -- run this first)       |" -ForegroundColor Green
    Write-Host "  |      Scans all repos for .gitignore issues.              |" -ForegroundColor DarkGray
    Write-Host "  |      Generates an HTML report. Token optional.           |" -ForegroundColor DarkGray
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  |  [2] Fix via Pull Requests (recommended)                 |" -ForegroundColor Yellow
    Write-Host "  |      Uses last analysis (or runs fresh). Creates PRs.    |" -ForegroundColor DarkGray
    Write-Host "  |      You pick which repos. Needs token.                  |" -ForegroundColor DarkGray
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  |  [3] Direct merge to main/master (use with caution)      |" -ForegroundColor Red
    Write-Host "  |      Uses last analysis (or runs fresh). Pushes directly.|" -ForegroundColor DarkGray
    Write-Host "  |      You pick which repos. Needs token.                  |" -ForegroundColor DarkGray
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  |  [4] Revert previous changes                             |" -ForegroundColor Magenta
    Write-Host "  |      Closes PRs, deletes branches, reverts pushes.       |" -ForegroundColor DarkGray
    Write-Host "  |      Needs token.                                        |" -ForegroundColor DarkGray
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Created by gauravkhurana.com for community" -ForegroundColor DarkCyan
    Write-Host "  #SharingIsCaring" -ForegroundColor DarkCyan
    Write-Host ""
    $choice = Read-Host "  Enter choice [1-4]"
    switch ($choice) {
        '1' {
            $DryRun = [switch]$true
            $script:ChosenMode = 'analyze'
            Write-Host "  -> Analyse mode selected. Will scan repos and generate a report." -ForegroundColor Green
        }
        '2' {
            $script:ChosenMode = 'pr'
            Write-Host "  -> PR mode selected. You'll pick which repos to fix." -ForegroundColor Yellow
        }
        '3' {
            $DirectPush = [switch]$true
            $script:ChosenMode = 'direct'
            Write-Host ""
            Write-Host "  WARNING: This will commit directly to each repo's default branch." -ForegroundColor Red
            Write-Host "  Changes go live immediately -- no PR for review." -ForegroundColor Yellow
            Write-Host "  Use option [4] later to undo if needed." -ForegroundColor Yellow
            Write-Host ""
            $confirm = Read-Host "  Type 'yes' to confirm direct merge"
            if ($confirm -ne 'yes') { Write-Host "  Cancelled." -ForegroundColor Gray; exit 0 }
        }
        '4' {
            $Revert = [switch]$true
            $script:ChosenMode = 'revert'
            Write-Host "  -> Revert mode selected." -ForegroundColor Magenta
        }
        default {
            Write-Host "  Invalid choice. Defaulting to analyse mode." -ForegroundColor Yellow
            $DryRun = [switch]$true
            $script:ChosenMode = 'analyze'
        }
    }
    Write-Host ""
    $explicitMode = $true  # menu was shown, don't show again
}

# Map CLI flags to ChosenMode if not set by menu
if ($null -eq $script:ChosenMode) {
    if ($Revert) { $script:ChosenMode = 'revert' }
    elseif ($DirectPush) { $script:ChosenMode = 'direct' }
    elseif ($DryRun) { $script:ChosenMode = 'analyze' }
    else { $script:ChosenMode = 'pr' }
}

# Determine if token is required for the chosen mode
$script:TokenRequired = -not $DryRun

# Prompt for GitHubUser if missing -- for options 2/3/4, try to reuse from cached analysis
if ([string]::IsNullOrWhiteSpace($GitHubUser)) {
    $cachedUser = $null
    if ($script:ChosenMode -in @('pr', 'direct', 'revert')) {
        $cacheLogsDir = Join-Path $scriptDir "logs"
        $cacheFiles = @(Get-ChildItem -Path $cacheLogsDir -Filter "analysis-cache-*.json" -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending)
        if ($cacheFiles.Count -gt 0) {
            try {
                $cacheData = Get-Content -Path $cacheFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($cacheData.user) { $cachedUser = $cacheData.user }
            } catch { Write-Verbose "Could not read analysis cache: $_" }
        }
    }

    if ($cachedUser) {
        $confirmUser = Read-Host "  Continue as '$cachedUser'? [Y/n]"
        if ($confirmUser -match '^[nN]') {
            $GitHubUser = Read-Host "  Enter your GitHub username"
        } else {
            $GitHubUser = $cachedUser
            Write-Host "  -> Using username: $GitHubUser" -ForegroundColor Green
        }
    } else {
        $GitHubUser = Read-Host "  Enter your GitHub username"
    }

    if ([string]::IsNullOrWhiteSpace($GitHubUser)) {
        Write-Host "  GitHub username is required. Exiting." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Usage:  .\Improve-GitHubRepos.ps1 -GitHubUser 'you'" -ForegroundColor Gray
        Write-Host "  Help:   Get-Help .\Improve-GitHubRepos.ps1 -Full" -ForegroundColor Gray
        exit 1
    }
}

# Prompt for GitHubToken if missing -- check env var first, allow skipping
if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
    if ($env:GITHUB_TOKEN) {
        $GitHubToken = $env:GITHUB_TOKEN
        Write-Host "  Using token from `$env:GITHUB_TOKEN" -ForegroundColor Green
        $script:HasToken = $true
    } elseif ($script:TokenRequired) {
        Write-Host "  GitHub token (repo scope) -- required for the selected mode." -ForegroundColor Gray
        Write-Host "  To create one:" -ForegroundColor Gray
        Write-Host "    1. Go to https://github.com/settings/tokens?type=beta" -ForegroundColor DarkCyan
        Write-Host "    2. Click 'Generate new token' -> give it a name" -ForegroundColor DarkCyan
        Write-Host "    3. Under 'Repository access' select 'All repositories'" -ForegroundColor DarkCyan
        Write-Host "    4. Under 'Permissions -> Repository permissions':" -ForegroundColor DarkCyan
        Write-Host "       Contents = Read and write, Pull requests = Read and write" -ForegroundColor DarkCyan
        Write-Host "    5. Click 'Generate token' and paste it below" -ForegroundColor DarkCyan
        Write-Host ""
        $secureToken = Read-Host "  Token" -AsSecureString
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        )
        if ([string]::IsNullOrWhiteSpace($plain)) {
            $GitHubToken = $null
            Write-Host "  No token provided -- falling back to scan-only mode (public repos, no PRs)." -ForegroundColor Yellow
            $DryRun = [switch]$true
            $DirectPush = [switch]$false
            $Revert = [switch]$false
        } else {
            $GitHubToken = $plain
            $script:HasToken = $true
        }
    } else {
        Write-Host "  Scan-only mode -- token is optional but recommended." -ForegroundColor Green
        Write-Host "  Without a token: 60 API requests/hour (may hit rate limits)." -ForegroundColor DarkGray
        Write-Host "  With a token:    5,000 requests/hour." -ForegroundColor DarkGray
        Write-Host ""
        $optIn = Read-Host "  Provide a token for higher rate limits? [y/N]"
        if ($optIn -match '^[yY]') {
            Write-Host "" 
            Write-Host "  To create one:" -ForegroundColor Gray
            Write-Host "    1. Go to https://github.com/settings/tokens?type=beta" -ForegroundColor DarkCyan
            Write-Host "    2. Click 'Generate new token' -> give it a name" -ForegroundColor DarkCyan
            Write-Host "    3. Under 'Repository access' select 'All repositories'" -ForegroundColor DarkCyan
            Write-Host "    4. Under 'Permissions -> Repository permissions':" -ForegroundColor DarkCyan
            Write-Host "       Contents = Read-only (write not needed for scan)" -ForegroundColor DarkCyan
            Write-Host "    5. Click 'Generate token' and paste it below" -ForegroundColor DarkCyan
            Write-Host ""
            $secureToken = Read-Host "  Token" -AsSecureString
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
            )
            if (-not [string]::IsNullOrWhiteSpace($plain)) {
                $GitHubToken = $plain
                $script:HasToken = $true
                Write-Host "  Token accepted -- using authenticated rate limits (5,000/hr)." -ForegroundColor Green
            } else {
                Write-Host "  No token -- continuing with unauthenticated limits (60/hr)." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Continuing without token (60 requests/hour limit)." -ForegroundColor Yellow
        }
    }
} else {
    $script:HasToken = $true
}

# Parse RepoName -- support comma-separated and auto-prefix with user
if ($RepoName) {
    $parsed = [System.Collections.Generic.List[string]]::new()
    foreach ($rn in $RepoName) {
        foreach ($part in ($rn -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            if ($part -notmatch "/") {
                $parsed.Add("$GitHubUser/$part")
            } else {
                $parsed.Add($part)
            }
        }
    }
    $RepoName = $parsed.ToArray()
    Write-Host "  Targeting specific repos: $($RepoName -join ', ')" -ForegroundColor Yellow
    Write-Host ""
}

# Parse ExcludeRepo -- support comma-separated and auto-prefix with user
if ($ExcludeRepo) {
    $parsedExclude = [System.Collections.Generic.List[string]]::new()
    foreach ($er in $ExcludeRepo) {
        foreach ($part in ($er -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            if ($part -notmatch "/") {
                $parsedExclude.Add("$GitHubUser/$part")
            } else {
                $parsedExclude.Add($part)
            }
        }
    }
    $ExcludeRepo = $parsedExclude.ToArray()
    Write-Host "  Excluding repos: $($ExcludeRepo -join ', ')" -ForegroundColor DarkGray
}

# Validate flag combinations
if ($DirectPush -and $DryRun) {
    Write-Host "  ERROR: Cannot use -DirectPush with -DryRun." -ForegroundColor Red; exit 1
}
if ($DirectPush -and $Revert) {
    Write-Host "  ERROR: Cannot use -DirectPush with -Revert." -ForegroundColor Red; exit 1
}
if ($DirectPush -and -not $script:HasToken) {
    Write-Host "  ERROR: -DirectPush requires a GitHub token." -ForegroundColor Red; exit 1
}
if ($Revert -and -not $script:HasToken) {
    Write-Host "  ERROR: -Revert requires a GitHub token." -ForegroundColor Red; exit 1
}

# DirectPush confirmation (for CLI flag usage -- interactive menu already confirmed)
if ($DirectPush -and -not $script:MenuWasShown) {
    Write-Host ""
    Write-Host "  WARNING: -DirectPush will commit directly to each repo's default branch." -ForegroundColor Red
    Write-Host "  Changes go live immediately -- no PR for review." -ForegroundColor Yellow
    Write-Host "  Use -Revert later to undo if needed." -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "  Type 'yes' to continue"
    if ($confirm -ne 'yes') {
        Write-Host "  Cancelled." -ForegroundColor Gray; exit 0
    }
}

# ===========================================================================
# SECTION 1: LOGGING
# ===========================================================================

$script:LogFilePath = $null

function Initialize-Logger {
    param([string]$Path)
    $script:LogFilePath = $Path
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
}

function Write-Log {
    param(
        [Parameter(Position = 0)] [string]$Message,
        [ValidateSet("Info","Warn","Error")] [string]$Level = "Info"
    )
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $tag   = switch ($Level) { "Warn" { "WARN " } "Error" { "ERROR" } default { "INFO " } }
    $line  = "[$ts] [$tag] $Message"
    $color = switch ($Level) { "Warn" { "Yellow" } "Error" { "Red" } default { "Gray" } }
    Write-Host $line -ForegroundColor $color
    if ($script:LogFilePath) { Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8 }
}

# ===========================================================================
# SECTION 1B: ANALYSIS CACHE (save/load analysis to avoid re-scanning)
# ===========================================================================

function Get-AnalysisCachePath {
    param([string]$LogsDir, [string]$User)
    Join-Path $LogsDir "analysis-cache-$User.json"
}

function Save-AnalysisCache {
    param([string]$CachePath, $AllResults, $ProblemResults, [int]$TotalScanned, [string]$User)
    $cache = @{
        timestamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        user        = $User
        totalScanned = $TotalScanned
        problemCount = $ProblemResults.Count
        allResults  = @($AllResults | ForEach-Object {
            $entry = @{
                RepoFullName  = $_.RepoFullName
                RepoUrl       = $_.RepoUrl
                DefaultBranch = $_.DefaultBranch
                Language      = $_.Language
                Summary       = $_.Summary
                JunkCount     = $_.JunkCount
                TotalFiles    = $_.TotalFiles
                Status        = $_.Status
                BranchUrl     = $_.BranchUrl
                PRUrl         = $_.PRUrl
            }
            # Save Analysis object details for problem repos so Phase 3 can use them
            if ($_.Status -eq 'needs-fix' -and $_.Analysis) {
                $a = $_.Analysis
                $entry.AnalysisData = @{
                    HasProblems      = $a.HasProblems
                    MissingGitignore = $a.MissingGitignore
                    WeakGitignore    = $a.WeakGitignore
                    JunkFileCount    = $a.JunkFileCount
                    JunkRatio        = $a.JunkRatio
                    TotalFiles       = $a.TotalFiles
                    Summary          = $a.Summary
                    NeededPatterns   = @($a.NeededPatterns)
                    JunkFiles        = @($a.JunkFiles)
                    Problems         = @($a.Problems | ForEach-Object {
                        @{ Type = $_.Type; Severity = $_.Severity; Description = $_.Description }
                    })
                }
            }
            $entry
        })
    }
    $cache | ConvertTo-Json -Depth 6 | Set-Content -Path $CachePath -Encoding UTF8
}

function Load-AnalysisCache {
    param([string]$CachePath)
    if (-not (Test-Path $CachePath)) { return $null }
    try {
        $raw = Get-Content -Path $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return $raw
    } catch {
        return $null
    }
}

function Restore-AnalysisFromCache {
    <# Converts cached JSON data back into the $allResults and $results lists with proper Analysis objects #>
    param($CacheData)

    $allResults = [System.Collections.Generic.List[object]]::new()
    $results    = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $CacheData.allResults) {
        $analysis = $null
        if ($item.PSObject.Properties['AnalysisData'] -and $item.AnalysisData) {
            $ad = $item.AnalysisData
            $problems = @($ad.Problems | ForEach-Object {
                [PSCustomObject]@{ Type = $_.Type; Severity = $_.Severity; Description = $_.Description }
            })
            $analysis = [PSCustomObject]@{
                HasProblems      = $ad.HasProblems
                MissingGitignore = $ad.MissingGitignore
                WeakGitignore    = $ad.WeakGitignore
                JunkFileCount    = $ad.JunkFileCount
                JunkRatio        = $ad.JunkRatio
                TotalFiles       = $ad.TotalFiles
                Summary          = $ad.Summary
                NeededPatterns   = @($ad.NeededPatterns)
                JunkFiles        = @($ad.JunkFiles)
                Problems         = $problems
            }
        }

        $entry = [PSCustomObject]@{
            RepoFullName  = $item.RepoFullName
            RepoUrl       = $item.RepoUrl
            DefaultBranch = $item.DefaultBranch
            Language      = $item.Language
            Analysis      = $analysis
            Summary       = $item.Summary
            JunkCount     = $item.JunkCount
            TotalFiles    = $item.TotalFiles
            BranchUrl     = $item.BranchUrl
            PRUrl         = $item.PRUrl
            Status        = $item.Status
        }

        $allResults.Add($entry)
        if ($item.Status -eq 'needs-fix') {
            $results.Add($entry)
        }
    }

    return @{ AllResults = $allResults; Results = $results; TotalScanned = $CacheData.totalScanned }
}

# ===========================================================================
# SECTION 2: JUNK PATTERN DATABASE (40+ patterns)
# ===========================================================================

$script:JunkPatterns = @(
    # JavaScript / Node
    @{ Pattern="node_modules/";    Desc="Node.js dependencies";          W=10; Lang=@("JavaScript","TypeScript","Vue","Svelte") }
    @{ Pattern="bower_components/";Desc="Bower dependencies";            W=8;  Lang=@("JavaScript") }
    @{ Pattern=".npm/";            Desc="npm cache";                     W=6;  Lang=@("JavaScript","TypeScript") }
    @{ Pattern="dist/";            Desc="Build output (JS)";             W=5;  Lang=@("JavaScript","TypeScript","Vue","Svelte") }
    @{ Pattern="build/";           Desc="Build output";                  W=4;  Lang=@("JavaScript","TypeScript","Java","C#","C++","Go") }
    @{ Pattern=".next/";           Desc="Next.js build cache";           W=8;  Lang=@("JavaScript","TypeScript") }
    @{ Pattern=".nuxt/";           Desc="Nuxt.js build cache";           W=8;  Lang=@("JavaScript","TypeScript","Vue") }
    @{ Pattern="coverage/";        Desc="Code coverage reports";         W=7;  Lang=@("*") }
    @{ Pattern=".nyc_output/";     Desc="NYC coverage output";           W=6;  Lang=@("JavaScript","TypeScript") }
    # Python
    @{ Pattern="__pycache__/";     Desc="Python bytecode cache";         W=9;  Lang=@("Python","Jupyter Notebook") }
    @{ Pattern="*.pyc";            Desc="Python compiled files";         W=8;  Lang=@("Python") }
    @{ Pattern=".venv/";           Desc="Python virtual env";            W=10; Lang=@("Python") }
    @{ Pattern="venv/";            Desc="Python virtual env";            W=10; Lang=@("Python") }
    @{ Pattern="env/";             Desc="Python virtual env";            W=7;  Lang=@("Python") }
    @{ Pattern="*.egg-info/";      Desc="Python egg metadata";           W=6;  Lang=@("Python") }
    @{ Pattern=".eggs/";           Desc="Python egg build dir";          W=6;  Lang=@("Python") }
    @{ Pattern=".tox/";            Desc="Tox test runner";               W=5;  Lang=@("Python") }
    @{ Pattern=".mypy_cache/";     Desc="Mypy cache";                   W=6;  Lang=@("Python") }
    @{ Pattern=".pytest_cache/";   Desc="Pytest cache";                  W=6;  Lang=@("Python") }
    # .NET / C#
    @{ Pattern="bin/";             Desc=".NET build output";             W=9;  Lang=@("C#","F#","Visual Basic .NET") }
    @{ Pattern="obj/";             Desc=".NET intermediate build";       W=9;  Lang=@("C#","F#","Visual Basic .NET") }
    @{ Pattern="packages/";        Desc="NuGet packages";                W=7;  Lang=@("C#","F#") }
    @{ Pattern=".vs/";             Desc="Visual Studio settings";        W=6;  Lang=@("C#","F#","C++","Visual Basic .NET") }
    @{ Pattern="*.user";           Desc="VS user-specific files";        W=4;  Lang=@("C#","C++") }
    # Java
    @{ Pattern="target/";          Desc="Maven/Gradle build output";     W=9;  Lang=@("Java","Kotlin","Scala","Rust") }
    @{ Pattern="*.class";          Desc="Java compiled classes";         W=8;  Lang=@("Java","Kotlin") }
    @{ Pattern=".gradle/";         Desc="Gradle cache";                  W=7;  Lang=@("Java","Kotlin","Groovy") }
    @{ Pattern=".idea/";           Desc="IntelliJ IDEA settings";        W=5;  Lang=@("Java","Kotlin","Python","Go","*") }
    # Go / Rust / Ruby / PHP
    @{ Pattern="vendor/";          Desc="Vendored dependencies";         W=5;  Lang=@("Go","PHP","Ruby") }
    @{ Pattern="vendor/bundle/";   Desc="Ruby vendored gems";            W=6;  Lang=@("Ruby") }
    @{ Pattern=".bundle/";         Desc="Bundler directory";             W=7;  Lang=@("Ruby") }
    # Universal
    @{ Pattern=".DS_Store";        Desc="macOS metadata";                W=3;  Lang=@("*") }
    @{ Pattern="Thumbs.db";        Desc="Windows thumbnail cache";       W=3;  Lang=@("*") }
    @{ Pattern="*.log";            Desc="Log files";                     W=3;  Lang=@("*") }
    @{ Pattern=".env";             Desc="Environment vars (secrets!)";   W=8;  Lang=@("*") }
    @{ Pattern=".env.local";       Desc="Local env overrides";           W=7;  Lang=@("*") }
    @{ Pattern="*.swp";            Desc="Vim swap files";                W=3;  Lang=@("*") }
    @{ Pattern="*.swo";            Desc="Vim swap files";                W=3;  Lang=@("*") }
    @{ Pattern="*~";               Desc="Backup files";                  W=3;  Lang=@("*") }
    @{ Pattern=".cache/";          Desc="Generic cache";                 W=5;  Lang=@("*") }
    @{ Pattern="tmp/";             Desc="Temporary files";               W=4;  Lang=@("*") }
    @{ Pattern=".terraform/";      Desc="Terraform provider cache";      W=8;  Lang=@("HCL") }
    @{ Pattern="*.tfstate";        Desc="Terraform state (sensitive!)";  W=10; Lang=@("HCL") }
)

function Get-JunkPatternsForLanguage {
    param([string]$Language)
    return $script:JunkPatterns | Where-Object { $_.Lang -contains "*" -or $_.Lang -contains $Language }
}

# ===========================================================================
# SECTION 3: GITIGNORE TEMPLATES
# ===========================================================================

function Get-GitignoreTemplate {
    param([string]$Language)
    $map = @{
        "JavaScript"="Node"; "TypeScript"="Node"; "Python"="Python"; "Java"="Java";
        "C#"="VisualStudio"; "C++"="C++"; "Go"="Go"; "Ruby"="Ruby"; "PHP"="Composer";
        "Rust"="Rust"; "Kotlin"="Java"; "Swift"="Swift"; "Dart"="Dart"; "Scala"="Scala";
        "Vue"="Node"; "Svelte"="Node"; "Shell"="Linux"; "HCL"="Terraform";
        "Jupyter Notebook"="Python"; "F#"="VisualStudio"; "Groovy"="Java"
    }
    $tpl = if ($map.ContainsKey($Language)) { $map[$Language] } else { $null }
    if ($tpl) {
        try {
            return Invoke-RestMethod -Uri "https://raw.githubusercontent.com/github/gitignore/main/${tpl}.gitignore" -TimeoutSec 10
        } catch { Write-Verbose "Could not fetch gitignore template for ${Language}: $_" }
    }
    # Fallback: build from our pattern database
    $lines = @("# Auto-generated .gitignore for $Language","")
    foreach ($p in (Get-JunkPatternsForLanguage -Language $Language)) {
        $lines += "# $($p.Desc)"; $lines += $p.Pattern; $lines += ""
    }
    $lines += "# OS / Editor"; $lines += ".DS_Store"; $lines += "Thumbs.db"
    $lines += ".idea/"; $lines += ".vscode/"; $lines += ""
    return ($lines -join "`n")
}

# ===========================================================================
# SECTION 4: REPO ANALYZER
# ===========================================================================

function Invoke-RepoAnalysis {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RepoFullName', Justification='Passed for API consistency with callers')]
    param([string[]]$FilePaths, [string]$ExistingGitignore, [string]$Language, [string]$RepoFullName)

    $problems       = [System.Collections.Generic.List[object]]::new()
    $junkFilesFound = [System.Collections.Generic.List[string]]::new()
    $missingGI      = [string]::IsNullOrWhiteSpace($ExistingGitignore)
    $weakGI         = $false
    $total          = $FilePaths.Count
    $junkPatterns   = Get-JunkPatternsForLanguage -Language $Language

    # Check 1: missing .gitignore
    if ($missingGI) {
        $problems.Add([PSCustomObject]@{ Type="missing-gitignore"; Severity="high"; Description="No .gitignore file found" })
    }

    # Check 2: junk files committed
    foreach ($pat in $junkPatterns) {
        $p = $pat.Pattern; $hits = @()
        if     ($p.EndsWith("/"))    { $d = $p.TrimEnd("/"); $hits = @($FilePaths | Where-Object { $_ -like "$d/*" -or $_ -eq $d }) }
        elseif ($p.StartsWith("*.")) { $ext = $p.Substring(1); $hits = @($FilePaths | Where-Object { $_.EndsWith($ext) }) }
        elseif ($p.Contains("*"))    { $hits = @($FilePaths | Where-Object { $_ -like $p }) }
        else                         { $hits = @($FilePaths | Where-Object { $_ -eq $p -or $_.EndsWith("/$p") -or $_.EndsWith("\$p") }) }

        if ($hits.Count -gt 0) {
            $sev = if ($pat.W -ge 7) { "high" } elseif ($pat.W -ge 4) { "medium" } else { "low" }
            $problems.Add([PSCustomObject]@{
                Type="junk-committed"; Severity=$sev; Pattern=$p; FileCount=$hits.Count; Weight=$pat.W
                Description="$($pat.Desc) -- $($hits.Count) file(s) matching '$p'"
            })
            foreach ($f in $hits) { if (-not $junkFilesFound.Contains($f)) { $junkFilesFound.Add($f) } }
        }
    }

    # Check 3: weak gitignore
    if (-not $missingGI) {
        $missing = [System.Collections.Generic.List[object]]::new()
        foreach ($cp in ($junkPatterns | Where-Object { $_.W -ge 7 })) {
            $clean = $cp.Pattern.TrimEnd("/")
            if ($ExistingGitignore -notmatch [regex]::Escape($clean)) {
                if ($problems | Where-Object { $_.Type -eq "junk-committed" -and $_.Pattern -eq $cp.Pattern }) {
                    $missing.Add($cp)
                }
            }
        }
        if ($missing.Count -gt 0) {
            $weakGI = $true
            $problems.Add([PSCustomObject]@{
                Type="weak-gitignore"; Severity="medium"
                Description="Gitignore missing $($missing.Count) critical pattern(s): $(($missing | ForEach-Object { $_.Pattern }) -join ', ')"
                MissingPatterns=$missing
            })
        }
    }

    # Check 4: stat inflation
    $junkCount = $junkFilesFound.Count
    $ratio = if ($total -gt 0) { $junkCount / $total } else { 0 }
    if ($ratio -gt 0.1 -and $junkCount -gt 20) {
        $problems.Add([PSCustomObject]@{
            Type="language-stat-inflation"; Severity="high"
            Description="$junkCount of $total files ($([math]::Round($ratio*100,1))%) are artifacts -- likely inflating language stats"
        })
    }

    $neededPatterns = [System.Collections.Generic.List[string]]::new()
    foreach ($pr in ($problems | Where-Object { $_.Type -eq "junk-committed" })) {
        if (-not $neededPatterns.Contains($pr.Pattern)) { $neededPatterns.Add($pr.Pattern) }
    }

    $sumParts = @()
    if ($missingGI) { $sumParts += "missing .gitignore" }
    if ($weakGI)    { $sumParts += "weak .gitignore" }
    if ($junkCount -gt 0) { $sumParts += "$junkCount junk files tracked" }

    return [PSCustomObject]@{
        HasProblems=$($problems.Count -gt 0); MissingGitignore=$missingGI; WeakGitignore=$weakGI
        Problems=$problems; JunkFiles=$junkFilesFound; JunkFileCount=$junkCount
        JunkRatio=$ratio; TotalFiles=$total; NeededPatterns=$neededPatterns
        Summary=$(if ($sumParts.Count -gt 0) { $sumParts -join "; " } else { "clean" })
    }
}

# ===========================================================================
# SECTION 5: REPO FIXER
# ===========================================================================

function Invoke-RepoFix {
    param([string]$RepoDir, [PSCustomObject]$Analysis, [string]$Language)

    $changeLog = [System.Collections.Generic.List[string]]::new()
    $changed   = $false
    $giPath    = Join-Path $RepoDir ".gitignore"

    # Step 1: create or improve .gitignore
    if ($Analysis.MissingGitignore) {
        Write-Log "  Fetching .gitignore template for '$Language' ..."
        $tpl = Get-GitignoreTemplate -Language $Language
        $extra = "`n`n# -- Additional patterns (auto-detected) --`n"
        foreach ($p in $Analysis.NeededPatterns) {
            if ($tpl -notmatch [regex]::Escape($p.TrimEnd("/"))) { $extra += "$p`n" }
        }
        Set-Content -Path $giPath -Value ($tpl + $extra) -Encoding UTF8 -NoNewline
        $changeLog.Add("- Created .gitignore with $Language template + $($Analysis.NeededPatterns.Count) extra patterns")
        $changed = $true
    }
    elseif ($Analysis.WeakGitignore -or ($Analysis.NeededPatterns -and $Analysis.NeededPatterns.Count -gt 0)) {
        $existing = Get-Content -Path $giPath -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($existing)) { $existing = "" }
        $append = "`n`n# -- Added by gitignore-improver (missing patterns) --`n"
        $count = 0
        foreach ($p in $Analysis.NeededPatterns) {
            if ($existing -notmatch [regex]::Escape($p.TrimEnd("/"))) { $append += "$p`n"; $count++ }
        }
        if ($count -gt 0) {
            Add-Content -Path $giPath -Value $append -Encoding UTF8
            $changeLog.Add("- Appended $count missing patterns to .gitignore")
            $changed = $true
        }
    }

    # Step 2: remove junk from git tracking (files stay on disk)
    $dirsToRemove  = [System.Collections.Generic.HashSet[string]]::new()
    $filesToRemove = [System.Collections.Generic.List[string]]::new()

    foreach ($jf in $Analysis.JunkFiles) {
        $topDir = ($jf -split "[/\\]")[0]
        if ($Analysis.NeededPatterns | Where-Object { $_.TrimEnd("/") -eq $topDir }) {
            $dirsToRemove.Add($topDir) | Out-Null
        } else {
            $filesToRemove.Add($jf)
        }
    }

    Push-Location $RepoDir
    try {
        foreach ($dir in $dirsToRemove) {
            if (Test-Path (Join-Path $RepoDir $dir)) {
                Write-Log "  Untracking: $dir/ ..."
                git rm -r --cached $dir 2>&1 | Out-Null
                $changeLog.Add("- Removed ``$dir/`` from git tracking")
                $changed = $true
            }
        }
        $indiv = 0
        foreach ($f in $filesToRemove) {
            if (Test-Path (Join-Path $RepoDir $f)) { git rm --cached $f 2>&1 | Out-Null; $indiv++ }
        }
        if ($indiv -gt 0) {
            $changeLog.Add("- Removed $indiv individual junk files from tracking")
            $changed = $true
        }
    }
    catch { Write-Log "  Warning: git rm failed: $_" -Level Warn }
    finally { Pop-Location }

    return [PSCustomObject]@{ ChangesMade=$changed; CommitDetails=($changeLog -join "`n"); ChangeLog=$changeLog }
}

# ===========================================================================
# SECTION 6: REPORT GENERATOR
# ===========================================================================

function Write-Report {
    param([string]$ReportPath, $Results, [string]$GitHubUser, [string]$RunDate, [switch]$DryRun)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# GitHub Repo Improvement Report")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Field | Value |")
    [void]$sb.AppendLine("|-------|-------|")
    [void]$sb.AppendLine("| **User** | $GitHubUser |")
    [void]$sb.AppendLine("| **Date** | $RunDate |")
    [void]$sb.AppendLine("| **Mode** | $(if ($DryRun) {'Dry Run (no changes)'} else {'Live Run'}) |")
    [void]$sb.AppendLine("| **Repos with issues** | $($Results.Count) |")
    [void]$sb.AppendLine("")

    if ($Results.Count -eq 0) {
        [void]$sb.AppendLine("> All repos look good! No .gitignore issues found.")
        Set-Content -Path $ReportPath -Value $sb.ToString() -Encoding UTF8; return
    }

    # Summary table
    [void]$sb.AppendLine("## Summary")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| # | Repository | Language | Issue | Junk Files | Status | Action |")
    [void]$sb.AppendLine("|---|-----------|----------|-------|------------|--------|--------|")
    $i = 0
    foreach ($r in $Results) {
        $i++
        $badge = switch ($r.Status) {
            "pr-created"       {"PR Created"}   "pushed-no-pr"     {"Pushed"}
            "direct-pushed"    {"Direct Push"}  "already-processed"{"Already Done"}
            "no-changes"       {"No Changes"}   "needs-fix"        {"Needs Fix"}
            "error"            {"Error"}        default            {$r.Status}
        }
        $link = if ($r.PRUrl) {"[Review PR]($($r.PRUrl))"} elseif ($r.BranchUrl) {"[View Branch]($($r.BranchUrl))"} else {"-"}
        [void]$sb.AppendLine("| $i | [$($r.RepoFullName)]($($r.RepoUrl)) | $($r.Language) | $($r.Analysis.Summary) | $($r.Analysis.JunkFileCount) | $badge | $link |")
    }
    [void]$sb.AppendLine("")

    # Detail per repo
    [void]$sb.AppendLine("## Details")
    [void]$sb.AppendLine("")
    foreach ($r in $Results) {
        $a = $r.Analysis
        [void]$sb.AppendLine("### [$($r.RepoFullName)]($($r.RepoUrl))")
        [void]$sb.AppendLine("- **Language:** $($r.Language) | **Files:** $($a.TotalFiles) | **Junk:** $($a.JunkFileCount) ($([math]::Round($a.JunkRatio*100,1))%)")
        if ($r.PRUrl)     { [void]$sb.AppendLine("- **PR:** [$($r.PRUrl)]($($r.PRUrl))") }
        if ($r.BranchUrl) { [void]$sb.AppendLine("- **Branch:** [$($r.BranchUrl)]($($r.BranchUrl))") }
        [void]$sb.AppendLine("")
        foreach ($p in $a.Problems) {
            $icon = switch ($p.Severity) { "high"{"!!"} "medium"{"! "} "low"{"  "} default{"  "} }
            [void]$sb.AppendLine("  - [$icon] $($p.Description)")
        }
        [void]$sb.AppendLine("")
        if ($a.JunkFiles.Count -gt 0 -and $a.JunkFiles.Count -le 50) {
            [void]$sb.AppendLine("<details><summary>Junk files ($($a.JunkFiles.Count))</summary>")
            [void]$sb.AppendLine(""); [void]$sb.AppendLine("``````")
            foreach ($f in $a.JunkFiles) { [void]$sb.AppendLine($f) }
            [void]$sb.AppendLine("``````"); [void]$sb.AppendLine("</details>"); [void]$sb.AppendLine("")
        }
        elseif ($a.JunkFiles.Count -gt 50) {
            [void]$sb.AppendLine("<details><summary>Junk files (first 20 of $($a.JunkFiles.Count))</summary>")
            [void]$sb.AppendLine(""); [void]$sb.AppendLine("``````")
            $a.JunkFiles | Select-Object -First 20 | ForEach-Object { [void]$sb.AppendLine($_) }
            [void]$sb.AppendLine("... and $($a.JunkFiles.Count - 20) more")
            [void]$sb.AppendLine("``````"); [void]$sb.AppendLine("</details>"); [void]$sb.AppendLine("")
        }
        [void]$sb.AppendLine("---"); [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("*Generated by Improve-GitHubRepos on $RunDate*")
    Set-Content -Path $ReportPath -Value $sb.ToString() -Encoding UTF8
}

function Write-HtmlReport {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProblemResults', Justification='Kept for API consistency; may be used in future report sections')]
    param(
        [string]$ReportPath,
        $AllResults,
        $ProblemResults,
        [string]$GitHubUser,
        [string]$RunDate,
        [switch]$DryRun,
        [int]$TotalScanned
    )

    $mode       = if ($DryRun) { 'Dry Run' } else { 'Live Run' }
    $okCount    = @($AllResults | Where-Object { $_.Status -eq 'clean' }).Count
    $issueCount = @($AllResults | Where-Object { $_.Status -ne 'clean' -and $_.Status -ne 'skipped' }).Count
    $skipCount  = @($AllResults | Where-Object { $_.Status -eq 'skipped' }).Count
    $prCount    = @($AllResults | Where-Object { $_.Status -eq 'pr-created' }).Count
    $totalJunk  = ($AllResults | Measure-Object -Property JunkCount -Sum).Sum
    if ($null -eq $totalJunk) { $totalJunk = 0 }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="UTF-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1.0">')
    [void]$sb.AppendLine("<title>GitHub Repo Report - $RunDate</title>")
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('*{margin:0;padding:0;box-sizing:border-box}')
    [void]$sb.AppendLine('body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:#0d1117;color:#c9d1d9;line-height:1.5}')
    [void]$sb.AppendLine('.container{max-width:1280px;margin:0 auto;padding:24px}')
    [void]$sb.AppendLine('h1{font-size:24px;font-weight:600;margin-bottom:8px;color:#f0f6fc}')
    [void]$sb.AppendLine('.subtitle{color:#8b949e;margin-bottom:24px;font-size:14px}')
    [void]$sb.AppendLine('.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:16px;margin-bottom:32px}')
    [void]$sb.AppendLine('.card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px;text-align:center}')
    [void]$sb.AppendLine('.card .num{font-size:32px;font-weight:700}')
    [void]$sb.AppendLine('.card .label{font-size:12px;color:#8b949e;text-transform:uppercase;letter-spacing:.5px}')
    [void]$sb.AppendLine('.card.ok .num{color:#3fb950} .card.warn .num{color:#d29922} .card.err .num{color:#f85149} .card.info .num{color:#58a6ff} .card.purple .num{color:#bc8cff}')
    [void]$sb.AppendLine('.filter-bar{margin-bottom:16px;display:flex;gap:8px;flex-wrap:wrap;align-items:center}')
    [void]$sb.AppendLine('.filter-bar label{font-size:13px;color:#8b949e}')
    [void]$sb.AppendLine('.filter-bar select,.filter-bar input{background:#0d1117;color:#c9d1d9;border:1px solid #30363d;border-radius:6px;padding:6px 10px;font-size:13px}')
    [void]$sb.AppendLine('.filter-bar input{min-width:220px}')
    [void]$sb.AppendLine('table{width:100%;border-collapse:collapse;margin-bottom:32px}')
    [void]$sb.AppendLine('th{background:#161b22;text-align:left;padding:10px 12px;font-size:12px;color:#8b949e;text-transform:uppercase;letter-spacing:.5px;border-bottom:1px solid #30363d;position:sticky;top:0;cursor:pointer;user-select:none}')
    [void]$sb.AppendLine('th:hover{color:#f0f6fc}')
    [void]$sb.AppendLine('td{padding:10px 12px;border-bottom:1px solid #21262d;font-size:14px}')
    [void]$sb.AppendLine('tr:hover{background:#161b22}')
    [void]$sb.AppendLine('a{color:#58a6ff;text-decoration:none} a:hover{text-decoration:underline}')
    [void]$sb.AppendLine('.badge{display:inline-block;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:500}')
    [void]$sb.AppendLine('.badge-clean{background:#1b4332;color:#3fb950}')
    [void]$sb.AppendLine('.badge-fix{background:#4a2600;color:#d29922}')
    [void]$sb.AppendLine('.badge-pr{background:#0c2d6b;color:#58a6ff}')
    [void]$sb.AppendLine('.badge-pushed{background:#3d1f00;color:#f0883e}')
    [void]$sb.AppendLine('.badge-skip{background:#1c1c1c;color:#8b949e}')
    [void]$sb.AppendLine('.badge-error{background:#4a0e0e;color:#f85149}')
    [void]$sb.AppendLine('.badge-done{background:#1b3a4b;color:#79c0ff}')
    [void]$sb.AppendLine('.lang-tag{display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;background:#30363d;color:#c9d1d9}')
    [void]$sb.AppendLine('.issues-cell{font-size:13px;color:#8b949e;max-width:340px}')
    [void]$sb.AppendLine('.junk-bar{display:inline-block;height:8px;border-radius:4px;margin-left:6px}')
    [void]$sb.AppendLine('.junk-bar.low{background:#3fb950;width:30px} .junk-bar.med{background:#d29922;width:60px} .junk-bar.high{background:#f85149;width:90px}')
    [void]$sb.AppendLine('.footer{text-align:center;color:#484f58;font-size:12px;margin-top:32px;padding-top:16px;border-top:1px solid #21262d}')
    [void]$sb.AppendLine('@media(max-width:600px){.cards{grid-template-columns:1fr 1fr}}')
    [void]$sb.AppendLine('</style></head><body><div class="container">')

    # Header + cards
    [void]$sb.AppendLine("<h1>&#128203; GitHub Repo Improvement Report</h1>")
    [void]$sb.AppendLine("<p class=`"subtitle`">User: <strong>$GitHubUser</strong> &middot; Date: <strong>$RunDate</strong> &middot; Mode: <strong>$mode</strong></p>")
    [void]$sb.AppendLine('<div class="cards">')
    [void]$sb.AppendLine("  <div class=`"card info`"><div class=`"num`">$TotalScanned</div><div class=`"label`">Total Repos</div></div>")
    [void]$sb.AppendLine("  <div class=`"card ok`"><div class=`"num`">$okCount</div><div class=`"label`">Clean</div></div>")
    [void]$sb.AppendLine("  <div class=`"card warn`"><div class=`"num`">$issueCount</div><div class=`"label`">Issues Found</div></div>")
    [void]$sb.AppendLine("  <div class=`"card purple`"><div class=`"num`">$totalJunk</div><div class=`"label`">Junk Files</div></div>")
    [void]$sb.AppendLine("  <div class=`"card info`"><div class=`"num`">$prCount</div><div class=`"label`">PRs Created</div></div>")
    $skipCls = if ($skipCount -gt 0) { 'card err' } else { 'card ok' }
    [void]$sb.AppendLine("  <div class=`"$skipCls`"><div class=`"num`">$skipCount</div><div class=`"label`">Skipped</div></div>")
    [void]$sb.AppendLine('</div>')

    # Filter bar
    [void]$sb.AppendLine('<div class="filter-bar">')
    [void]$sb.AppendLine('  <label>Filter:</label>')
    [void]$sb.AppendLine('  <input type="text" id="searchBox" placeholder="Search repo name or language..." oninput="filterTable()">')
    [void]$sb.AppendLine('  <select id="statusFilter" onchange="filterTable()">')
    [void]$sb.AppendLine('    <option value="">All Statuses</option>')
    [void]$sb.AppendLine('    <option value="clean">Clean</option>')
    [void]$sb.AppendLine('    <option value="needs-fix">Needs Fix</option>')
    [void]$sb.AppendLine('    <option value="pr-created">PR Created</option>')
    [void]$sb.AppendLine('    <option value="direct-pushed">Direct Push</option>')
    [void]$sb.AppendLine('    <option value="skipped">Skipped</option>')
    [void]$sb.AppendLine('    <option value="error">Error</option>')
    [void]$sb.AppendLine('  </select>')
    [void]$sb.AppendLine('</div>')

    # Table header
    [void]$sb.AppendLine('<table id="repoTable"><thead><tr>')
    [void]$sb.AppendLine('  <th onclick="sortTable(0)">#</th>')
    [void]$sb.AppendLine('  <th onclick="sortTable(1)">Repository</th>')
    [void]$sb.AppendLine('  <th onclick="sortTable(2)">Language</th>')
    [void]$sb.AppendLine('  <th onclick="sortTable(3)">Status</th>')
    [void]$sb.AppendLine('  <th onclick="sortTable(4)">Issues</th>')
    [void]$sb.AppendLine('  <th onclick="sortTable(5)">Junk Files</th>')
    [void]$sb.AppendLine('  <th onclick="sortTable(6)">Junk %</th>')
    [void]$sb.AppendLine('  <th>Action</th>')
    [void]$sb.AppendLine('</tr></thead><tbody>')

    # Table rows -- ALL repos
    $i = 0
    foreach ($r in $AllResults) {
        $i++
        $statusBadge = switch ($r.Status) {
            'clean'             { '<span class="badge badge-clean">Clean</span>' }
            'needs-fix'         { '<span class="badge badge-fix">Needs Fix</span>' }
            'pr-created'        { '<span class="badge badge-pr">PR Created</span>' }
            'pushed-no-pr'      { '<span class="badge badge-pushed">Pushed</span>' }
            'direct-pushed'     { '<span class="badge badge-pushed">Direct Push</span>' }
            'already-processed' { '<span class="badge badge-done">Already Done</span>' }
            'no-changes'        { '<span class="badge badge-clean">No Changes</span>' }
            'skipped'           { '<span class="badge badge-skip">Skipped</span>' }
            'error'             { '<span class="badge badge-error">Error</span>' }
            default             { '<span class="badge badge-skip">' + $r.Status + '</span>' }
        }

        $junkBar = if ($r.JunkCount -eq 0) { '' }
                   elseif ($r.JunkCount -lt 10) { '<span class="junk-bar low"></span>' }
                   elseif ($r.JunkCount -lt 30) { '<span class="junk-bar med"></span>' }
                   else { '<span class="junk-bar high"></span>' }

        $issueText = if ($r.Summary -and $r.Summary -ne 'clean') {
            $r.Summary -replace '<','&lt;' -replace '>','&gt;' -replace '&','&amp;'
        } else { '&mdash;' }

        $actionLink = if ($r.PRUrl) { '<a href="' + $r.PRUrl + '" target="_blank">Review PR</a>' }
                      elseif ($r.BranchUrl) { '<a href="' + $r.BranchUrl + '" target="_blank">View Branch</a>' }
                      else { '&mdash;' }

        $junkPct = if ($r.TotalFiles -gt 0) { [math]::Round(($r.JunkCount / $r.TotalFiles) * 100, 1) } else { 0 }
        $repoNameEsc = $r.RepoFullName -replace '<','&lt;' -replace '>','&gt;'
        $langEsc     = $r.Language -replace '<','&lt;' -replace '>','&gt;'

        [void]$sb.AppendLine("  <tr data-status=`"$($r.Status)`">")
        [void]$sb.AppendLine("    <td>$i</td>")
        [void]$sb.AppendLine("    <td><a href=`"$($r.RepoUrl)`" target=`"_blank`">$repoNameEsc</a></td>")
        [void]$sb.AppendLine("    <td><span class=`"lang-tag`">$langEsc</span></td>")
        [void]$sb.AppendLine("    <td>$statusBadge</td>")
        [void]$sb.AppendLine("    <td class=`"issues-cell`">$issueText</td>")
        [void]$sb.AppendLine("    <td>$($r.JunkCount) $junkBar</td>")
        [void]$sb.AppendLine("    <td>${junkPct}%</td>")
        [void]$sb.AppendLine("    <td>$actionLink</td>")
        [void]$sb.AppendLine("  </tr>")
    }

    [void]$sb.AppendLine('</tbody></table>')
    [void]$sb.AppendLine("<div class=`"footer`">Generated by <strong>Improve-GitHubRepos</strong> on $RunDate &middot; $($AllResults.Count) repos scanned</div>")
    [void]$sb.AppendLine('</div>')

    # JavaScript -- filter + sort
    [void]$sb.AppendLine('<script>')
    [void]$sb.AppendLine('function filterTable(){')
    [void]$sb.AppendLine('  var s=document.getElementById("searchBox").value.toLowerCase();')
    [void]$sb.AppendLine('  var st=document.getElementById("statusFilter").value;')
    [void]$sb.AppendLine('  document.querySelectorAll("#repoTable tbody tr").forEach(function(r){')
    [void]$sb.AppendLine('    var t=r.textContent.toLowerCase(),rs=r.getAttribute("data-status");')
    [void]$sb.AppendLine('    r.style.display=(!s||t.indexOf(s)>=0)&&(!st||rs===st)?"":"none";')
    [void]$sb.AppendLine('  });')
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine('var sortDir={};')
    [void]$sb.AppendLine('function sortTable(c){')
    [void]$sb.AppendLine('  var tb=document.querySelector("#repoTable tbody");')
    [void]$sb.AppendLine('  var rows=Array.from(tb.querySelectorAll("tr"));')
    [void]$sb.AppendLine('  var d=sortDir[c]=!sortDir[c];')
    [void]$sb.AppendLine('  rows.sort(function(a,b){')
    [void]$sb.AppendLine('    var va=a.children[c].textContent.trim(),vb=b.children[c].textContent.trim();')
    [void]$sb.AppendLine('    var na=parseFloat(va),nb=parseFloat(vb);')
    [void]$sb.AppendLine('    if(!isNaN(na)&&!isNaN(nb))return d?na-nb:nb-na;')
    [void]$sb.AppendLine('    return d?va.localeCompare(vb):vb.localeCompare(va);')
    [void]$sb.AppendLine('  });')
    [void]$sb.AppendLine('  rows.forEach(function(r){tb.appendChild(r);});')
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine('</script>')
    [void]$sb.AppendLine('</body></html>')

    Set-Content -Path $ReportPath -Value $sb.ToString() -Encoding UTF8
}

# ===========================================================================
# SECTION 7: GITHUB API HELPERS
# ===========================================================================

# Build API headers -- with or without auth
$script:GHHeaders = @{
    "Accept"               = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}
if ($script:HasToken) {
    $script:GHHeaders["Authorization"] = "Bearer $GitHubToken"
}

function GH-GetAllRepos {
    $repos = [System.Collections.Generic.List[object]]::new()
    $page = 1
    # Authenticated: /user/repos (includes private). Unauthenticated: /users/{user}/repos (public only)
    $baseUrl = if ($script:HasToken) {
        "https://api.github.com/user/repos?per_page=100&affiliation=owner"
    } else {
        "https://api.github.com/users/$GitHubUser/repos?per_page=100"
    }
    do {
        Write-Log "Fetching repos page $page ..."
        Wait-IfRateLimited
        try {
            $webResp = Invoke-WebRequest -Uri "${baseUrl}&page=$page" -Headers $script:GHHeaders -UseBasicParsing
            Update-RateLimit $webResp
            $resp = $webResp.Content | ConvertFrom-Json
        } catch {
            $statusCode = 0
            if ($_.Exception -and $_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
            }
            if ($statusCode -eq 403 -or $statusCode -eq 429) {
                Write-Log "  Rate limit hit! GitHub API allows 60 requests/hour without a token, 5000 with." -Level Error
                Write-Log "  Create a token at: https://github.com/settings/tokens?type=beta" -Level Error
                Write-Log "  Then re-run with: -GitHubToken <your-token>" -Level Error
            } else {
                Write-Log "  API error fetching repos: $_" -Level Error
            }
            break
        }
        $resp = @($resp)
        if ($resp.Count -eq 0) { break }
        foreach ($r in $resp) { $repos.Add($r) }
        $page++
    } while ($resp.Count -eq 100)
    Write-Log "Total repos: $($repos.Count)"
    if (-not $script:HasToken) { Write-Log "  (public repos only -- provide a token to include private repos)" }
    return $repos
}

function GH-GetTree {
    param([string]$Repo, [string]$Branch)
    Wait-IfRateLimited
    try {
        $webResp = Invoke-WebRequest -Uri "https://api.github.com/repos/$Repo/git/trees/${Branch}?recursive=1" -Headers $script:GHHeaders -UseBasicParsing
        Update-RateLimit $webResp
        $t = $webResp.Content | ConvertFrom-Json
        return $t.tree
    } catch { Write-Log "  Could not fetch tree for $Repo -- $_" -Level Warn; return $null }
}

function GH-GetGitignore {
    param([string]$Repo, [string]$Branch)
    Wait-IfRateLimited
    try {
        $webResp = Invoke-WebRequest -Uri "https://api.github.com/repos/$Repo/contents/.gitignore?ref=$Branch" -Headers $script:GHHeaders -UseBasicParsing
        Update-RateLimit $webResp
        $f = $webResp.Content | ConvertFrom-Json
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($f.content))
    } catch { return $null }
}

function GH-CreatePR {
    param([string]$Repo, [string]$Head, [string]$Base, [string]$Title, [string]$Body)
    try {
        $pr = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/pulls" -Headers $script:GHHeaders -Method Post `
            -Body (@{ title=$Title; head=$Head; base=$Base; body=$Body } | ConvertTo-Json -Depth 5) -ContentType "application/json"
        Write-Log "  PR created: $($pr.html_url)"
        return $pr
    } catch { Write-Log "  ERROR creating PR: $_" -Level Error; return $null }
}

# -- Rate Limit Helpers ------------------------------------------------------
$script:RateLimitRemaining = 999
$script:RateLimitReset     = 0

function Update-RateLimit {
    <# Call after any Invoke-WebRequest to extract rate-limit headers #>
    param($Response)
    if ($Response -and $Response.Headers) {
        $h = $Response.Headers
        if ($h['X-RateLimit-Remaining']) {
            $val = $h['X-RateLimit-Remaining']
            $script:RateLimitRemaining = [int]$(if ($val -is [array]) { $val[0] } else { $val })
        }
        if ($h['X-RateLimit-Reset']) {
            $val = $h['X-RateLimit-Reset']
            $script:RateLimitReset = [long]$(if ($val -is [array]) { $val[0] } else { $val })
        }
    }
}

function Wait-IfRateLimited {
    <# Pauses automatically when approaching the rate limit (<=3 remaining) #>
    if ($script:RateLimitRemaining -le 3) {
        $nowEpoch  = [long](Get-Date -UFormat %s)
        $waitSecs  = [math]::Max($script:RateLimitReset - $nowEpoch + 2, 1)
        $resetTime = (Get-Date).AddSeconds($waitSecs).ToString('HH:mm:ss')
        Write-Log "Rate limit nearly exhausted ($($script:RateLimitRemaining) left). Waiting $waitSecs s until $resetTime ..." -Level Warn
        Start-Sleep -Seconds $waitSecs
        $script:RateLimitRemaining = 999   # optimistic reset
    }
}

# ===========================================================================
# SECTION 8: MAIN
# ===========================================================================

$runDate    = Get-Date -Format "yyyy-MM-dd"
$runTime    = Get-Date -Format "HHmmss"
$branchName = "improvement-${runDate}-${runTime}"
$logsDir    = Join-Path $scriptDir "logs"
$logFile    = Join-Path $logsDir "run-$runDate.log"
$reportFile = Join-Path $logsDir "report-$runDate.md"

if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

Initialize-Logger -Path $logFile
Write-Log "===== Improve-GitHubRepos ====="
Write-Log "User: $GitHubUser | DryRun: $DryRun | DirectPush: $DirectPush | Revert: $Revert | Token: $($script:HasToken) | Branch: $branchName"
if ($RepoName) { Write-Log "Target repos: $($RepoName -join ', ')" }

# -- Revert Mode (exits early) ----------------------------------------------
if ($Revert) {
    Write-Log "===== REVERT MODE ====="

    # Build list of repos from cached analysis or CLI param
    $revertRepos = @()
    if ($RepoName) {
        $revertRepos = $RepoName
    } else {
        # Load last analysis cache to show repos that were processed
        $analysisCachePath = Get-AnalysisCachePath -LogsDir $logsDir -User $GitHubUser
        $cached = Load-AnalysisCache -CachePath $analysisCachePath
        if ($cached -and $cached.user -eq $GitHubUser) {
            $revertCandidates = @($cached.allResults | Where-Object {
                $_.Status -notin @('clean', 'skipped')
            })
            if ($revertCandidates.Count -eq 0) {
                Write-Host "  No previously fixed repos found in the last analysis." -ForegroundColor Yellow
                Write-Host "  Nothing to revert." -ForegroundColor Gray
                exit 0
            }

            Write-Host ""
            Write-Host "  ==============================================================" -ForegroundColor Cyan
            Write-Host "  Last analysis: $($cached.timestamp) ($($cached.totalScanned) repos scanned)" -ForegroundColor White
            Write-Host "  $($revertCandidates.Count) repo(s) were flagged -- select which ones to revert" -ForegroundColor Yellow
            Write-Host "  ==============================================================" -ForegroundColor Cyan
            Write-Host ""

            $idx = 0
            foreach ($rc in $revertCandidates) {
                $idx++
                $statusLabel = switch ($rc.Status) {
                    'pr-created'        { 'PR Created' }
                    'direct-pushed'     { 'Direct Pushed' }
                    'pushed-no-pr'      { 'Pushed' }
                    'needs-fix'         { 'Needs Fix' }
                    'already-processed' { 'Already Processed' }
                    'no-changes'        { 'No Changes' }
                    'error'             { 'Error' }
                    default             { $rc.Status }
                }
                Write-Host "  [$idx] $($rc.RepoFullName) [$statusLabel]" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "  Enter selection:" -ForegroundColor DarkGray
            Write-Host "    - Number(s):  1  or  1,3,5  or  1-5" -ForegroundColor DarkGray
            Write-Host "    - 'all' to revert all $($revertCandidates.Count) repos" -ForegroundColor DarkGray
            Write-Host "    - Press Enter to cancel" -ForegroundColor DarkGray
            Write-Host ""
            $selection = Read-Host "  Select repos to revert"

            if ([string]::IsNullOrWhiteSpace($selection)) {
                Write-Log "User cancelled -- no repos selected for revert."
                Write-Host "  Cancelled." -ForegroundColor Gray
                exit 0
            }

            $selectedIndices = [System.Collections.Generic.List[int]]::new()
            if ($selection -eq 'all') {
                for ($i = 1; $i -le $revertCandidates.Count; $i++) { $selectedIndices.Add($i) }
            } else {
                foreach ($part in ($selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                    if ($part -match '^\d+$') {
                        $n = [int]$part
                        if ($n -ge 1 -and $n -le $revertCandidates.Count) { if (-not $selectedIndices.Contains($n)) { $selectedIndices.Add($n) } }
                    } elseif ($part -match '^(\d+)\s*-\s*(\d+)$') {
                        $from = [int]$Matches[1]; $to = [int]$Matches[2]
                        for ($i = [math]::Max(1,$from); $i -le [math]::Min($to,$revertCandidates.Count); $i++) {
                            if (-not $selectedIndices.Contains($i)) { $selectedIndices.Add($i) }
                        }
                    }
                }
            }

            if ($selectedIndices.Count -eq 0) {
                Write-Host "  No valid repos selected. Exiting." -ForegroundColor Yellow
                exit 0
            }

            $selectedIndices.Sort()
            $revertRepos = @($selectedIndices | ForEach-Object { $revertCandidates[$_ - 1].RepoFullName })

            Write-Host ""
            Write-Host "  -> Selected $($revertRepos.Count) repo(s) to revert:" -ForegroundColor Magenta
            foreach ($rr in $revertRepos) {
                Write-Host "    * $rr" -ForegroundColor White
            }
            Write-Host ""
            $confirm = Read-Host "  Type 'yes' to revert these $($revertRepos.Count) repo(s)"
            if ($confirm -ne 'yes') { Write-Host "  Cancelled." -ForegroundColor Gray; exit 0 }
        } else {
            Write-Host "  No cached analysis found for '$GitHubUser'." -ForegroundColor Yellow
            Write-Host "  Run option [1] (Analyse) first, then use option [4] to revert." -ForegroundColor Gray
            exit 0
        }
    }

    $revertCount = 0
    $prsClosed = 0
    $branchesDeleted = 0
    $commitsReverted = 0
    foreach ($rn in $revertRepos) {
        Write-Log ""; Write-Log "-- Checking: $rn --"
        $repoPRs = 0; $repoBranches = 0; $repoCommits = 0

        # 1. Close open PRs created by this tool
        try {
            $prs = Invoke-RestMethod -Uri "https://api.github.com/repos/$rn/pulls?state=open&per_page=100" -Headers $script:GHHeaders
            $ourPRs = @($prs | Where-Object { $_.title -match "^chore: improve \.gitignore" -and $_.head.ref -match "^improvement-" })
            foreach ($pr in $ourPRs) {
                Write-Log "  Closing PR #$($pr.number): $($pr.title)"
                Invoke-RestMethod -Uri "https://api.github.com/repos/$rn/pulls/$($pr.number)" `
                    -Headers $script:GHHeaders -Method Patch `
                    -Body (@{ state = "closed" } | ConvertTo-Json) -ContentType "application/json" | Out-Null
                $revertCount++
                $prsClosed++
                $repoPRs++
            }
        } catch {
            Write-Log "  Could not check PRs for $rn -- $_" -Level Warn
        }

        # 2. Delete improvement-* branches
        try {
            $refs = Invoke-RestMethod -Uri "https://api.github.com/repos/$rn/git/matching-refs/heads/improvement-" -Headers $script:GHHeaders
            foreach ($ref in @($refs)) {
                $brName = $ref.ref -replace "^refs/heads/", ""
                Write-Log "  Deleting branch: $brName"
                Invoke-RestMethod -Uri "https://api.github.com/repos/$rn/git/refs/heads/$brName" `
                    -Headers $script:GHHeaders -Method Delete | Out-Null
                $revertCount++
                $branchesDeleted++
                $repoBranches++
            }
        } catch {
            Write-Log "  Could not check branches for $rn -- $_" -Level Warn
        }

        # 3. Revert direct-push commits on default branch (checks last 20 commits)
        try {
            $repoInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$rn" -Headers $script:GHHeaders
            $defBranch = $repoInfo.default_branch
            $commits = Invoke-RestMethod -Uri "https://api.github.com/repos/$rn/commits?sha=$defBranch&per_page=20" -Headers $script:GHHeaders
            $ourCommits = @($commits | Where-Object {
                $_.commit.message -match "^chore: improve \.gitignore" -and
                $_.commit.author.email -eq "gitignore-improver@automation.local"
            })

            if ($ourCommits.Count -gt 0) {
                Write-Log "  Found $($ourCommits.Count) direct-push commit(s) to revert on '$defBranch'"
                $rDir = Join-Path $WorkDir ($rn -replace "/", "_")
                if (Test-Path $rDir) { Remove-Item -Recurse -Force $rDir }
                $cloneUrl = "https://x-access-token:${GitHubToken}@github.com/${rn}.git"
                $cloneOutput = & git clone $cloneUrl $rDir 2>&1
                foreach ($line in $cloneOutput) {
                    $safeLine = "$line" -replace 'x-access-token:[^@]+@', 'x-access-token:***@'
                    Write-Log "    $safeLine"
                }
                if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE" }

                Push-Location $rDir
                try {
                    git config user.email "gitignore-improver@automation.local"
                    git config user.name "GitIgnore Improver"
                    foreach ($c in $ourCommits) {
                        $firstLine = ($c.commit.message -split "`n")[0]
                        Write-Log "  Reverting commit $($c.sha.Substring(0,7)): $firstLine"
                        git revert --no-edit $c.sha 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            Write-Log "  Revert conflict -- aborting this commit. Manual revert may be needed." -Level Warn
                            git revert --abort 2>&1 | Out-Null
                            continue
                        }
                        $commitsReverted++
                        $repoCommits++
                    }
                    Write-Log "  Pushing revert(s) to $defBranch ..."
                    git push origin $defBranch 2>&1 | ForEach-Object {
                        $safeLine = $_ -replace 'x-access-token:[^@]+@', 'x-access-token:***@'
                        Write-Log "    $safeLine"
                    }
                    $revertCount += $ourCommits.Count
                } catch {
                    Write-Log "  Revert failed: $_ -- manual revert may be needed." -Level Error
                } finally { Pop-Location }
            }
        } catch {
            Write-Verbose "No direct-push commits found or API error for ${rn}: $_"
        }

        # Per-repo summary
        $repoTotal = $repoPRs + $repoBranches + $repoCommits
        if ($repoTotal -gt 0) {
            $parts = @()
            if ($repoPRs -gt 0)      { $parts += "$repoPRs PR(s) closed" }
            if ($repoBranches -gt 0)  { $parts += "$repoBranches branch(es) deleted" }
            if ($repoCommits -gt 0)  { $parts += "$repoCommits commit(s) reverted" }
            Write-Host "  -> $rn -- $($parts -join ', ')" -ForegroundColor Magenta
        } else {
            Write-Host "  -> $rn -- nothing to revert" -ForegroundColor Green
        }
    }

    Write-Log ""; Write-Log "===== Revert complete: $revertCount action(s) taken ====="
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  Revert complete!" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  Repos checked:      $($revertRepos.Count)" -ForegroundColor White
    if ($prsClosed -gt 0)       { Write-Host "  PRs closed:         $prsClosed" -ForegroundColor White }
    if ($branchesDeleted -gt 0) { Write-Host "  Branches deleted:   $branchesDeleted" -ForegroundColor White }
    if ($commitsReverted -gt 0) { Write-Host "  Commits reverted:   $commitsReverted" -ForegroundColor White }
    if ($revertCount -eq 0)     { Write-Host "  Nothing to revert -- repos are already clean." -ForegroundColor Green }
    Write-Host "  Log:                $logFile" -ForegroundColor White
    Write-Host "================================================" -ForegroundColor Cyan

    # Update cached analysis: set reverted repos back to needs-fix
    if ($revertCount -gt 0) {
        $revertCachePath = Get-AnalysisCachePath -LogsDir $logsDir -User $GitHubUser
        $revertCache = Load-AnalysisCache -CachePath $revertCachePath
        if ($revertCache) {
            $cacheUpdated = $false
            foreach ($rn in $revertRepos) {
                $match = $revertCache.allResults | Where-Object { $_.RepoFullName -eq $rn } | Select-Object -First 1
                if ($match -and $match.Status -notin @('clean', 'skipped', 'needs-fix')) {
                    $match.Status = 'needs-fix'
                    if ($match.PSObject.Properties['PRUrl'])     { $match.PRUrl = $null }
                    if ($match.PSObject.Properties['BranchUrl']) { $match.BranchUrl = $null }
                    $cacheUpdated = $true
                }
            }
            if ($cacheUpdated) {
                $revertCache.problemCount = @($revertCache.allResults | Where-Object { $_.Status -eq 'needs-fix' }).Count
                $revertCache | ConvertTo-Json -Depth 6 | Set-Content -Path $revertCachePath -Encoding UTF8
                Write-Log "Analysis cache updated: reverted repos set back to needs-fix"
            }
        }
    }

    exit 0
}

# -- Analysis: Run fresh or load from cache ---------------------------------
$analysisCachePath = Get-AnalysisCachePath -LogsDir $logsDir -User $GitHubUser
$results    = [System.Collections.Generic.List[object]]::new()
$allResults = [System.Collections.Generic.List[object]]::new()
$totalScanned = 0
$usedCache  = $false

# Check if a cached analysis exists and offer to reuse
if ($script:ChosenMode -eq 'analyze' -or $script:ChosenMode -eq 'pr' -or $script:ChosenMode -eq 'direct') {
    $cached = Load-AnalysisCache -CachePath $analysisCachePath
    if ($cached -and $cached.user -eq $GitHubUser) {
        $cacheTime    = $cached.timestamp
        $cacheProblems = $cached.problemCount
        $cacheTotal   = $cached.totalScanned

        # Find the latest HTML report
        $lastReport = @(Get-ChildItem -Path $logsDir -Filter "report-*.html" -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        $lastReportPath = if ($lastReport.Count -gt 0) { $lastReport[0].FullName } else { $null }
        $reportDisplay  = if ($lastReportPath) { [System.IO.Path]::GetFileName($lastReportPath) } else { "(not found)" }

        Write-Host ""
        Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
        Write-Host "  |  Previous analysis found                                 |" -ForegroundColor Cyan
        Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
        Write-Host "  |  Date:     $($cacheTime.PadRight(44))|" -ForegroundColor White
        Write-Host "  |  Scanned:  $($cacheTotal.ToString().PadRight(44))|" -ForegroundColor White
        Write-Host "  |  Issues:   $($cacheProblems.ToString().PadRight(44))|" -ForegroundColor Yellow
        Write-Host "  |  Report:   $($reportDisplay.PadRight(44))|" -ForegroundColor White
        Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
        Write-Host ""
        $reuseChoice = Read-Host "  Use this analysis? [Y/n] (Enter = yes, 'n' = run fresh analysis)"
        if ($reuseChoice -notmatch '^[nN]') {
            Write-Log "Reusing cached analysis from $cacheTime"

            # In analyse mode with existing report, just open it and exit
            if ($script:ChosenMode -eq 'analyze' -and $lastReportPath) {
                Write-Host ""
                Write-Host "================================================" -ForegroundColor Cyan
                Write-Host "  Analysis already available!" -ForegroundColor Cyan
                Write-Host "================================================" -ForegroundColor Cyan
                Write-Host "  Scanned:  $cacheTotal repos" -ForegroundColor White
                Write-Host "  Issues:   $cacheProblems" -ForegroundColor Yellow
                Write-Host "  Report:   $lastReportPath" -ForegroundColor White
                Write-Host ""
                Write-Host "  Created by gauravkhurana.com for community" -ForegroundColor DarkCyan
                Write-Host "  #SharingIsCaring" -ForegroundColor DarkCyan
                Write-Host ""
                Write-Host "  Next step: Re-run and choose option [2] PR or [3] Direct merge" -ForegroundColor DarkGray
                Write-Host "  to fix the repos using this analysis." -ForegroundColor DarkGray
                Write-Host "================================================" -ForegroundColor Cyan
                if ($env:OS -eq "Windows_NT") { try { Invoke-Item $lastReportPath } catch { Write-Verbose "Could not open report: $_" } }
                exit 0
            }

            $restored    = Restore-AnalysisFromCache -CacheData $cached
            $allResults  = $restored.AllResults
            $results     = $restored.Results
            $totalScanned = $restored.TotalScanned
            $usedCache   = $true
            Write-Host "  -> Using cached analysis ($cacheProblems issues in $cacheTotal repos)." -ForegroundColor Green
            Write-Host ""
        }
    }
}

# Run fresh analysis if no cache was used
if (-not $usedCache) {
    # -- Phase 1: Fetch repos -----------------------------------------------
    Write-Log ""; Write-Log "PHASE 1: Fetching repos ..."

    if ($RepoName) {
        $targetRepos = [System.Collections.Generic.List[object]]::new()
        foreach ($rn in $RepoName) {
            Write-Log "Fetching repo: $rn ..."
            try {
                $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$rn" -Headers $script:GHHeaders
                $targetRepos.Add($r)
            } catch {
                Write-Log "  Could not fetch repo '$rn' -- $_ (skipping)" -Level Warn
            }
        }
        Write-Log "Repos to process: $($targetRepos.Count)"
    } else {
        $allRepos = GH-GetAllRepos
        $targetRepos = @($allRepos | Where-Object {
            $ok = $true
            if ($SkipArchived -and $_.archived) { $ok = $false }
            if ($SkipForks    -and $_.fork)     { $ok = $false }
            if ($ExcludeRepo  -and $ExcludeRepo -contains $_.full_name) { $ok = $false }
            $ok
        })
        if ($ExcludeRepo) { Write-Log "After filtering (excl. $($ExcludeRepo.Count) excluded): $($targetRepos.Count) repos" }
        else              { Write-Log "After filtering: $($targetRepos.Count) repos" }
    }

    $totalScanned = $targetRepos.Count

    # -- Phase 2: Analyze ---------------------------------------------------
    Write-Log ""; Write-Log "PHASE 2: Analyzing ..."

    $repoIndex = 0
    $repoTotal = $targetRepos.Count
    foreach ($repo in $targetRepos) {
        $repoIndex++
        $name   = $repo.full_name
        $branch = $repo.default_branch
        $lang   = if ($repo.language) { $repo.language } else { "Unknown" }

        Write-Log ""; Write-Log "-- [$repoIndex/$repoTotal] $name (lang=$lang) --"

        $tree = GH-GetTree -Repo $name -Branch $branch
        if ($null -eq $tree) {
            Write-Log "  Skipping (empty/inaccessible)"
            $allResults.Add([PSCustomObject]@{
                RepoFullName=$name; RepoUrl=$repo.html_url; DefaultBranch=$branch
                Language=$lang; Summary="empty/inaccessible"; JunkCount=0; TotalFiles=0
                BranchUrl=$null; PRUrl=$null; Status="skipped"
            })
            continue
        }

        $files = @($tree | Where-Object { $_.type -eq "blob" } | Select-Object -ExpandProperty path)
        $gi    = GH-GetGitignore -Repo $name -Branch $branch
        $analysis = Invoke-RepoAnalysis -FilePaths $files -ExistingGitignore $gi -Language $lang -RepoFullName $name

        if ($analysis.HasProblems) {
            Write-Log "  PROBLEMS: $($analysis.Summary)"
            $entry = [PSCustomObject]@{
                RepoFullName=$name; RepoUrl=$repo.html_url; DefaultBranch=$branch
                Language=$lang; Analysis=$analysis; Summary=$analysis.Summary
                JunkCount=$analysis.JunkFileCount; TotalFiles=$analysis.TotalFiles
                BranchUrl=$null; PRUrl=$null; Status="needs-fix"
            }
            $results.Add($entry)
            $allResults.Add($entry)
        } else {
            Write-Log "  OK"
            $allResults.Add([PSCustomObject]@{
                RepoFullName=$name; RepoUrl=$repo.html_url; DefaultBranch=$branch
                Language=$lang; Summary="clean"; JunkCount=0; TotalFiles=$analysis.TotalFiles
                BranchUrl=$null; PRUrl=$null; Status="clean"
            })
        }

        # -- Batch pause: ask user every BatchSize repos --
        if ($BatchSize -gt 0 -and $repoIndex -lt $repoTotal -and ($repoIndex % $BatchSize) -eq 0) {
            Write-Log "Analyzed $repoIndex / $repoTotal repos so far ($($results.Count) with issues). Rate limit remaining: $($script:RateLimitRemaining)"
            Write-Host ""
            Write-Host "  -- Batch checkpoint ($repoIndex / $repoTotal) --" -ForegroundColor Cyan
            Write-Host "  Repos with issues so far: $($results.Count)" -ForegroundColor Yellow
            Write-Host "  API calls remaining:      $($script:RateLimitRemaining)" -ForegroundColor $(if ($script:RateLimitRemaining -lt 10) { 'Red' } else { 'Green' })
            Write-Host ""
            $cont = Read-Host "  Press Enter to continue next batch, or type 'stop' to finish here"
            if ($cont -eq 'stop') {
                Write-Log "User stopped after batch at repo $repoIndex."
                break
            }
        }
    }

    Write-Log ""; Write-Log "Repos needing fixes: $($results.Count) / $totalScanned"

    # Save analysis cache for future PR/Direct runs
    Save-AnalysisCache -CachePath $analysisCachePath -AllResults $allResults -ProblemResults $results -TotalScanned $totalScanned -User $GitHubUser
    Write-Log "Analysis cached: $analysisCachePath"
}

# -- Preview of changes ----------------------------------------------------------
if ($results.Count -gt 0) {
    Write-Log ""; Write-Log "PREVIEW -- what $(if ($DryRun) {'would'} else {'will'}) change:"
    foreach ($r in $results) {
        $a = $r.Analysis
        Write-Host ""
        Write-Host "  +- $($r.RepoFullName) ($($r.Language))" -ForegroundColor Yellow
        if ($a.MissingGitignore) {
            Write-Host "  |  + CREATE .gitignore ($($r.Language) template)" -ForegroundColor Green
        } elseif ($a.WeakGitignore) {
            Write-Host "  |  ~ APPEND to .gitignore: $($a.NeededPatterns.Count) patterns" -ForegroundColor Cyan
        }
        if ($a.NeededPatterns.Count -gt 0) {
            Write-Host "  |  Patterns to add:" -ForegroundColor Gray
            foreach ($pat in $a.NeededPatterns) {
                Write-Host "  |    + $pat" -ForegroundColor DarkGreen
            }
        }
        if ($a.JunkFileCount -gt 0) {
            Write-Host "  |  - UNTRACK $($a.JunkFileCount) junk file(s) via git rm --cached" -ForegroundColor Magenta
            $preview = $a.JunkFiles | Select-Object -First 5
            foreach ($f in $preview) {
                Write-Host "  |    - $f" -ForegroundColor DarkMagenta
            }
            if ($a.JunkFileCount -gt 5) {
                Write-Host "  |    ... and $($a.JunkFileCount - 5) more" -ForegroundColor DarkGray
            }
        }
        Write-Host "  +-" -ForegroundColor Yellow
    }
    Write-Host ""
}

# -- Analysis-only mode: generate reports and exit --------------------------
if ($DryRun) {
    Write-Report -ReportPath $reportFile -Results $results -GitHubUser $GitHubUser -RunDate $runDate -DryRun:$true
    $htmlFile = $reportFile -replace '\.md$', '.html'
    Write-HtmlReport -ReportPath $htmlFile -AllResults $allResults -ProblemResults $results -GitHubUser $GitHubUser -RunDate $runDate -DryRun:$true -TotalScanned $totalScanned
    Write-Log "Report (HTML): $htmlFile"; Write-Log "Report (MD): $reportFile"; Write-Log "Log: $logFile"

    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  Analysis complete!" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  Scanned:  $totalScanned repos" -ForegroundColor White
    Write-Host "  Issues:   $($results.Count)" -ForegroundColor Yellow
    Write-Host "  Report:   $htmlFile" -ForegroundColor White
    Write-Host "  Log:      $logFile" -ForegroundColor White
    Write-Host ""
    Write-Host "  Created by gauravkhurana.com for community" -ForegroundColor DarkCyan
    Write-Host "  #SharingIsCaring" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  Next step: Re-run and choose option [2] PR or [3] Direct merge" -ForegroundColor DarkGray
    Write-Host "  to fix the repos using this analysis." -ForegroundColor DarkGray
    Write-Host "================================================" -ForegroundColor Cyan

    if ($env:OS -eq "Windows_NT") { try { Invoke-Item $htmlFile } catch { Write-Verbose "Could not open report: $_" } }
    exit 0
}

# -- No issues found ---------------------------------------------------------
if ($results.Count -eq 0) {
    Write-Report -ReportPath $reportFile -Results $results -GitHubUser $GitHubUser -RunDate $runDate -DryRun:$DryRun
    $htmlFile = $reportFile -replace '\.md$', '.html'
    Write-HtmlReport -ReportPath $htmlFile -AllResults $allResults -ProblemResults $results -GitHubUser $GitHubUser -RunDate $runDate -DryRun:$DryRun -TotalScanned $totalScanned
    Write-Log "Report (HTML): $htmlFile"; Write-Log "Report (MD): $reportFile"; Write-Log "Log: $logFile"
    Write-Host "`nAll repos look good!" -ForegroundColor Green
    Write-Host "  Report: $htmlFile" -ForegroundColor White
    if ($env:OS -eq "Windows_NT") { try { Invoke-Item $htmlFile } catch { Write-Verbose "Could not open report: $_" } }
    exit 0
}

# -- Repo selection: show numbered list and let user pick -------------------
$action = if ($DirectPush) { "DIRECT MERGE" } else { "PULL REQUEST" }
Write-Host "  ==============================================================" -ForegroundColor Cyan
Write-Host "  $($results.Count) repo(s) have issues -- select which ones to fix ($action)" -ForegroundColor Yellow
Write-Host "  ==============================================================" -ForegroundColor Cyan
Write-Host ""

# Check which repos already have improvement branches/PRs on GitHub
$alreadyProcessed = @{}
if ($script:HasToken) {
    foreach ($r in $results) {
        if ($r.Status -in @('pr-created', 'pushed-no-pr', 'direct-pushed', 'already-processed')) {
            $alreadyProcessed[$r.RepoFullName] = $r.Status
        }
    }
}

# Display numbered list
$pendingCount = 0
$idx = 0
foreach ($r in $results) {
    $idx++
    $junkInfo = if ($r.JunkCount -gt 0) { " | $($r.JunkCount) junk files" } else { "" }
    $langInfo = "($($r.Language))"
    $statusIcon = if ($r.Analysis.MissingGitignore) { "[missing .gitignore]" }
                  elseif ($r.Analysis.WeakGitignore) { "[weak .gitignore]" }
                  else { "[junk tracked]" }

    if ($alreadyProcessed.ContainsKey($r.RepoFullName)) {
        $doneLabel = switch ($alreadyProcessed[$r.RepoFullName]) {
            'pr-created'        { 'PR exists' }
            'pushed-no-pr'      { 'already pushed' }
            'direct-pushed'     { 'already merged' }
            'already-processed' { 'already done' }
            default             { 'done' }
        }
        Write-Host "  [$idx] $($r.RepoFullName) $langInfo $statusIcon$junkInfo" -ForegroundColor DarkGray -NoNewline
        Write-Host " <- $doneLabel" -ForegroundColor DarkYellow
    } else {
        Write-Host "  [$idx] $($r.RepoFullName) $langInfo $statusIcon$junkInfo" -ForegroundColor White
        $pendingCount++
    }
}
Write-Host ""
if ($alreadyProcessed.Count -gt 0) {
    Write-Host "  Note: dimmed repos were already processed. Select them to re-run." -ForegroundColor DarkGray
    Write-Host ""
}
Write-Host "  Enter selection:" -ForegroundColor DarkGray
Write-Host "    - Number(s):  1  or  1,3,5  or  1-5" -ForegroundColor DarkGray
Write-Host "    - 'all' for all $pendingCount pending repos (skips already-processed)" -ForegroundColor DarkGray
Write-Host "    - Press Enter to cancel" -ForegroundColor DarkGray
Write-Host ""
$selection = Read-Host "  Select repos"

if ([string]::IsNullOrWhiteSpace($selection)) {
    Write-Log "User cancelled -- no repos selected."
    Write-Host "  Cancelled." -ForegroundColor Gray
    exit 0
}

# Parse selection into indices
$selectedIndices = [System.Collections.Generic.List[int]]::new()
if ($selection -eq 'all') {
    for ($i = 1; $i -le $results.Count; $i++) {
        $rn = $results[$i - 1].RepoFullName
        if (-not $alreadyProcessed.ContainsKey($rn)) { $selectedIndices.Add($i) }
    }
} else {
    foreach ($part in ($selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($part -match '^\d+$') {
            $n = [int]$part
            if ($n -ge 1 -and $n -le $results.Count) { if (-not $selectedIndices.Contains($n)) { $selectedIndices.Add($n) } }
        } elseif ($part -match '^(\d+)\s*-\s*(\d+)$') {
            $from = [int]$Matches[1]; $to = [int]$Matches[2]
            for ($i = [math]::Max(1,$from); $i -le [math]::Min($to,$results.Count); $i++) {
                if (-not $selectedIndices.Contains($i)) { $selectedIndices.Add($i) }
            }
        }
    }
}

if ($selectedIndices.Count -eq 0) {
    Write-Host "  No valid repos selected. Exiting." -ForegroundColor Yellow
    exit 0
}

$selectedIndices.Sort()
$selectedResults = @($selectedIndices | ForEach-Object { $results[$_ - 1] })

Write-Host ""
Write-Host "  -> Selected $($selectedResults.Count) repo(s) for $($action.ToLower()):" -ForegroundColor Green
foreach ($sr in $selectedResults) {
    Write-Host "    * $($sr.RepoFullName)" -ForegroundColor White
}
Write-Host ""

# Final confirmation for direct merge
if ($DirectPush) {
    $confirm = Read-Host "  Type 'yes' to direct merge these $($selectedResults.Count) repo(s)"
    if ($confirm -ne 'yes') { Write-Host "  Cancelled." -ForegroundColor Gray; exit 0 }
}

# -- Phase 3: Fix + Push + PR -----------------------------------------------
Write-Log ""; Write-Log "PHASE 3: Fixing $($selectedResults.Count) repo(s) ($(if ($DirectPush) { 'direct merge' } else { 'branch + PR' })) ..."

$phase3Index = 0
foreach ($result in $selectedResults) {
    $phase3Index++
    $rn     = $result.RepoFullName
    $rDir   = Join-Path $WorkDir ($rn -replace "/", "_")

    Write-Log ""; Write-Log "-- [$phase3Index/$($selectedResults.Count)] Fixing: $rn --"
    try {
        if (Test-Path $rDir) { Remove-Item -Recurse -Force $rDir }
        $cloneUrl = if ($script:HasToken) {
            "https://x-access-token:${GitHubToken}@github.com/${rn}.git"
        } else {
            "https://github.com/${rn}.git"
        }
        Write-Log "  Cloning ..."
        $cloneOutput = & git clone --depth 1 $cloneUrl $rDir 2>&1
        $cloneExit = $LASTEXITCODE
        foreach ($line in $cloneOutput) {
            $safeLine = "$line" -replace 'x-access-token:[^@]+@', 'x-access-token:***@'
            Write-Log "    $safeLine"
        }
        if ($cloneExit -ne 0) { throw "git clone failed with exit code $cloneExit" }

        Push-Location $rDir
        try {
            git fetch --unshallow 2>&1 | Out-Null
            git config user.email "gitignore-improver@automation.local"
            git config user.name "GitIgnore Improver"

            if (-not $DirectPush) {
                $remoteBranches = git branch -r 2>&1
                if ($remoteBranches -match "origin/$branchName") {
                    Write-Log "  Branch '$branchName' already exists on remote. Skipping." -Level Warn
                    $result.BranchUrl = "https://github.com/$rn/tree/$branchName"
                    $result.Status = "already-processed"
                    continue
                }
                git checkout -b $branchName 2>&1 | Out-Null
            }

            $fix = Invoke-RepoFix -RepoDir $rDir -Analysis $result.Analysis -Language $result.Language

            if ($fix.ChangesMade) {
                git add -A 2>&1 | Out-Null
                $null = git commit -m "chore: improve .gitignore and remove tracked artifacts`n`n$($fix.CommitDetails)" 2>&1
                $hasCommit = ($LASTEXITCODE -eq 0)

                if (-not $hasCommit) {
                    Write-Log "  No actual changes to commit (working tree clean). Skipping push."
                    $result.Status = "no-changes"
                    continue
                }

                if ($DirectPush) {
                    Write-Log "  Pushing directly to $($result.DefaultBranch) ..."
                    git push origin $($result.DefaultBranch) 2>&1 | ForEach-Object {
                        $safeLine = $_ -replace 'x-access-token:[^@]+@', 'x-access-token:***@'
                        Write-Log "    $safeLine"
                    }
                    $result.Status = "direct-pushed"
                } else {
                    Write-Log "  Pushing branch ..."
                    git push origin $branchName 2>&1 | ForEach-Object {
                        $safeLine = $_ -replace 'x-access-token:[^@]+@', 'x-access-token:***@'
                        Write-Log "    $safeLine"
                    }

                    $result.BranchUrl = "https://github.com/$rn/tree/$branchName"

                    $prBody = @"
## Automated .gitignore Improvement

### Changes:
$($fix.CommitDetails)

### Why?
- Committed build artifacts bloat your repo and slow cloning
- They skew GitHub language statistics (e.g. showing mostly HTML)
- A proper .gitignore keeps things clean

### Action:
- **Merge** if it looks good, or **close** if you prefer to handle it yourself.

> Auto-generated on $runDate
"@
                    $pr = GH-CreatePR -Repo $rn -Head $branchName -Base $result.DefaultBranch `
                        -Title "chore: improve .gitignore ($runDate $runTime)" -Body $prBody

                    if ($pr) { $result.PRUrl = $pr.html_url; $result.Status = "pr-created" }
                    else      { $result.Status = "pushed-no-pr" }
                }
            } else {
                Write-Log "  No changes needed after detailed check."
                $result.Status = "no-changes"
            }
        } finally { Pop-Location }
    }
    catch {
        Write-Log "  ERROR: $_" -Level Error
        $result.Status = "error"
    }

    # Show progress after each repo
    $actionDone = if ($result.PRUrl) { "PR: $($result.PRUrl)" }
                  elseif ($result.Status -eq 'direct-pushed') { "Pushed to $($result.DefaultBranch)" }
                  elseif ($result.Status -eq 'error') { "Error -- check log" }
                  else { $result.Status }
    $statusColor = if ($result.Status -eq 'error') { 'Red' } else { 'Green' }
    Write-Host "  [$phase3Index/$($selectedResults.Count)] $rn -> $actionDone" -ForegroundColor $statusColor
}

# -- Phase 4: Report --------------------------------------------------------
Write-Log ""; Write-Log "PHASE 4: Report ..."

# Sync statuses from $results into $allResults (PRs, push status, etc.)
foreach ($r in $results) {
    $match = $allResults | Where-Object { $_.RepoFullName -eq $r.RepoFullName } | Select-Object -First 1
    if ($match) {
        $match.Status    = $r.Status
        $match.PRUrl     = $r.PRUrl
        $match.BranchUrl = $r.BranchUrl
    }
}

Write-Report -ReportPath $reportFile -Results $results -GitHubUser $GitHubUser -RunDate $runDate -DryRun:$DryRun
Write-Log "Report (Markdown): $reportFile"

$htmlFile = $reportFile -replace '\.md$', '.html'
Write-HtmlReport -ReportPath $htmlFile -AllResults $allResults -ProblemResults $results -GitHubUser $GitHubUser -RunDate $runDate -DryRun:$DryRun -TotalScanned $totalScanned
Write-Log "Report (HTML):     $htmlFile"

# JSON export
$jsonFile = $reportFile -replace '\.md$', '.json'
$jsonData = @{
    user      = $GitHubUser
    date      = $runDate
    mode      = if (-not $script:HasToken) { "scan-only" } elseif ($DryRun) { "dry-run" } elseif ($DirectPush) { "direct-push" } else { "live" }
    scanned   = $totalScanned
    problems  = $results.Count
    repos     = @($results | ForEach-Object {
        $a = $_.Analysis
        @{
            name         = $_.RepoFullName
            url          = $_.RepoUrl
            language     = $_.Language
            status       = $_.Status
            prUrl        = $_.PRUrl
            branchUrl    = $_.BranchUrl
            totalFiles   = $a.TotalFiles
            junkFiles    = $a.JunkFileCount
            junkRatio    = [math]::Round($a.JunkRatio * 100, 1)
            missingGI    = $a.MissingGitignore
            weakGI       = $a.WeakGitignore
            patterns     = @($a.NeededPatterns)
            problems     = @($a.Problems | ForEach-Object {
                @{ type = $_.Type; severity = $_.Severity; description = $_.Description }
            })
        }
    })
}
$jsonData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
Write-Log "Report (JSON):     $jsonFile"
Write-Log "Log: $logFile"
Write-Log "===== Done ====="

$prCount     = @($selectedResults | Where-Object { $_.Status -eq "pr-created" }).Count
$directCount = @($selectedResults | Where-Object { $_.Status -eq "direct-pushed" }).Count
$selectedCount = $selectedResults.Count
$mode = if ($script:ChosenMode -eq 'analyze') { "analysis" } elseif ($DirectPush) { "direct push" } else { "PR" }
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Improve-GitHubRepos -- Done! ($mode)" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Scanned:  $totalScanned repos" -ForegroundColor White
Write-Host "  Problems: $($results.Count)" -ForegroundColor Yellow
if ($script:ChosenMode -ne 'analyze') {
    Write-Host "  Selected: $selectedCount repos" -ForegroundColor White
}
if ($DirectPush) {
    Write-Host "  Pushed:   $directCount direct to default branch" -ForegroundColor Green
    Write-Host "  Tip:      Use -Revert to undo if needed" -ForegroundColor DarkYellow
} elseif ($script:ChosenMode -eq 'pr') {
    Write-Host "  PRs:      $prCount" -ForegroundColor Green
} elseif ($script:ChosenMode -eq 'analyze') {
    Write-Host "  Next:     Choose [2] PR or [3] Direct merge to fix" -ForegroundColor DarkYellow
}
Write-Host "  Report:   $htmlFile" -ForegroundColor White
Write-Host "  Markdown: $reportFile" -ForegroundColor White
Write-Host "  JSON:     $jsonFile" -ForegroundColor White
Write-Host "  Log:      $logFile" -ForegroundColor White
Write-Host ""
Write-Host "  Created by gauravkhurana.com for community" -ForegroundColor DarkCyan
Write-Host "  #SharingIsCaring" -ForegroundColor DarkCyan
Write-Host "================================================" -ForegroundColor Cyan

# Auto-open HTML report on Windows
if ($env:OS -eq "Windows_NT") {
    try { Invoke-Item $htmlFile } catch { Write-Log "  Could not auto-open report: $_" -Level Warn }
}

# Cleanup cloned repos if requested
if ($Cleanup -and (Test-Path $WorkDir)) {
    Write-Log "Cleaning up work directory: $WorkDir"
    Remove-Item -Recurse -Force $WorkDir
    Write-Host "  Cleaned up $WorkDir" -ForegroundColor Gray
}
