# Improve-GitHubRepos

**One script. Zero dependencies (besides PowerShell + Git).** Download it, run it, done.

Scans all your GitHub repos, finds missing/weak `.gitignore` files, fixes them, and opens PRs — so your profile shows the right language stats and your repos stay lean.

## The Problem

Many developers forget to add a proper `.gitignore`, causing:
- **`node_modules/`**, **`__pycache__/`**, **`bin/obj/`**, etc. to be committed
- **Bloated repositories** that are slow to clone
- **Misleading GitHub language stats** (e.g., showing 80% HTML because coverage reports are committed)

## What This Does

1. **Scans** all your repos via the GitHub API
2. **Detects** missing/weak `.gitignore` and committed junk files (40+ patterns)
3. **Clones** problematic repos locally
4. **Fixes**: adds/improves `.gitignore` + removes junk from git tracking (files stay on disk)
5. **Pushes** a branch named `improvement-YYYY-MM-DD`
6. **Opens a PR** so you can review and merge at will
7. **Generates** a full Markdown report with links to every PR

## Quick Start

### Installation

**Option A: Clone the repo (recommended)**
```bash
git clone https://github.com/gauravkhuraana/fixmyrepos.git
cd fixmyrepos
.\Improve-GitHubRepos.ps1
```

**Option B: Download just the script (no git clone needed)**
```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/gauravkhuraana/fixmyrepos/main/Improve-GitHubRepos.ps1" -OutFile "Improve-GitHubRepos.ps1"
.\Improve-GitHubRepos.ps1
```

> **Note:** Clone if you want automatic updates (`git pull`). Download if you just want a quick one-time run.

### Run it

```powershell
# Just run it — you'll be prompted for everything:
.\Improve-GitHubRepos.ps1
```

That's it. No flags needed. It asks for your username, then token.
- If `$env:GITHUB_TOKEN` is set, it picks it up automatically.
- **No token? Press Enter to skip** — it scans your public repos and generates a report (no PRs).

### Scan without a token (public repos, report only)

```powershell
# Just provide a username — no token needed:
.\Improve-GitHubRepos.ps1 -GitHubUser "octocat"
```

This uses the unauthenticated GitHub API (60 requests/hour, public repos only).
Great for checking someone's profile or your own public repos without any setup.

### With token (full power: private repos + fixes + PRs)

```powershell
# Dry run first (safe — just scans, no changes)
.\Improve-GitHubRepos.ps1 -GitHubUser "your-username" -GitHubToken $env:GITHUB_TOKEN -DryRun

# Full run (fixes + creates PRs)
.\Improve-GitHubRepos.ps1 -GitHubUser "your-username" -GitHubToken $env:GITHUB_TOKEN
```

### Target a specific repo

```powershell
# Fix just one repo (short name or full name both work)
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -RepoName "my-project"

# Fix multiple specific repos (comma-separated)
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -RepoName "repo1,repo2,old-app"

# Full name works too
.\Improve-GitHubRepos.ps1 -GitHubToken $token -RepoName "octocat/Hello-World"
```

One file, one command.

### Push directly to main (no PR)

```powershell
# Skip branch/PR — commit straight to default branch (asks for confirmation)
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -DirectPush

# Direct push on a specific repo
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -DirectPush -RepoName "my-project"
```

### Revert changes

```powershell
# Revert a specific repo (closes PRs, deletes branches, reverts direct-push commits)
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -Revert -RepoName "my-project"

# Revert ALL repos touched by this tool
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -Revert
```

### Manual revert (without the script)

If you prefer to undo changes directly on GitHub or via CLI:

**Revert a merged PR (on github.com):**
1. Go to the repo → **Pull requests** → **Closed**
2. Open the merged PR (titled `chore: improve .gitignore ...`)
3. Click the **"Revert"** button at the bottom of the PR
4. GitHub creates a revert PR — merge it

**Revert a direct-push commit (on github.com):**
1. Go to the repo → **Commits** tab (on the `Code` page)
2. Find the commit titled `chore: improve .gitignore and remove tracked artifacts`
3. Click on the commit → look for a **Revert** button (top-right area)
4. If no Revert button appears (GitHub doesn't always show it for direct commits), use CLI instead

**Revert via CLI (works for any commit):**
```bash
# Find the commit hash
git log --oneline

# Revert it (creates a new undo commit, preserves history)
git revert <commit-hash>
git push origin main

# Or revert by message pattern
git log --oneline --grep="chore: improve .gitignore" | head -1
# Copy the hash, then: git revert <hash>
```

**Delete leftover branches (on github.com):**
1. Go to the repo → **Branches** (click the branch dropdown or go to `/<repo>/branches`)
2. Find any `improvement-*` branches
3. Click the trash icon to delete

### Exclude specific repos

```powershell
# Scan everything EXCEPT these repos
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -ExcludeRepo "old-junk,experiments,dotfiles"
```

## Prerequisites

- **PowerShell 7+** (recommended) or Windows PowerShell 5.1
- **Git** installed and on PATH (the script checks for this upfront)
- **GitHub Personal Access Token** with `repo` scope
  - [Create one here](https://github.com/settings/tokens) → Classic token → check **`repo`**

## All Options

```powershell
# Custom work directory
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -WorkDir "D:\temp\repos"

# Include forks and archived repos
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -SkipForks $false -SkipArchived $false

# Auto-delete cloned repos after creating PRs
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -Cleanup

# Pause every 10 repos during analysis (default: 30)
.\Improve-GitHubRepos.ps1 -GitHubUser "you" -GitHubToken $token -BatchSize 10
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `GitHubUser` | No* | prompted | GitHub username |
| `GitHubToken` | No | `$env:GITHUB_TOKEN` or prompted | GitHub PAT. Skip for scan-only mode (public repos) |
| `RepoName` | No | all repos | Target specific repo(s) — `"repo"`, `"user/repo"`, or `"a,b,c"` |
| `WorkDir` | No | `./work` | Directory to clone repos into |
| `DryRun` | No | `false` | Scan and report only, no changes |
| `DirectPush` | No | `false` | Push fixes directly to default branch (no branch/PR). Asks for confirmation |
| `Revert` | No | `false` | Undo all changes: close PRs, delete branches, revert direct-push commits |
| `ExcludeRepo` | No | none | Exclude repo(s) from scanning — `"repo"`, `"user/repo"`, or `"a,b,c"` |
| `Cleanup` | No | `false` | Delete cloned repos from `WorkDir` after finishing |
| `SkipArchived` | No | `true` | Skip archived repositories |
| `SkipForks` | No | `true` | Skip forked repositories |
| `BatchSize` | No | `30` | Pause for confirmation every N repos during analysis |

\* If not provided, you'll be prompted interactively. Token also checks `$env:GITHUB_TOKEN`. **No token = scan-only mode** (public repos, no PRs).

## Output

After running, you get three files in the `logs/` folder:

- **`run-YYYY-MM-DD-HHmmss.log`** — timestamped log of every action taken
- **`report-YYYY-MM-DD-HHmmss.md`** — Markdown report with:
  - Summary table (repo, language, issue, status, PR link)
  - Per-repo detailed findings with severity ratings
  - Junk file lists (collapsible)
  - One-click action links to review/merge each PR
- **`report-YYYY-MM-DD-HHmmss.json`** — machine-readable JSON with the same data (for dashboards, CI, scripts)

### Example report

```
| # | Repository         | Language   | Issue                  | Junk Files | Status     | Action                  |
|---|--------------------|------------|------------------------|------------|------------|-------------------------|
| 1 | user/my-app        | JavaScript | missing .gitignore     | 1503       | PR Created | [Review PR](https://...) |
| 2 | user/api-server    | Python     | weak .gitignore        | 47         | PR Created | [Review PR](https://...) |
```

## What Gets Detected

40+ patterns across all major languages:

| Language | Patterns |
|----------|----------|
| JavaScript/TypeScript | `node_modules/`, `dist/`, `build/`, `.next/`, `.nuxt/`, `coverage/` |
| Python | `__pycache__/`, `*.pyc`, `.venv/`, `venv/`, `.tox/`, `.mypy_cache/` |
| C# / .NET | `bin/`, `obj/`, `packages/`, `.vs/` |
| Java/Kotlin | `target/`, `*.class`, `.gradle/`, `.idea/` |
| Go | `vendor/` |
| Rust | `target/` |
| PHP | `vendor/` |
| Universal | `.DS_Store`, `Thumbs.db`, `.env`, `*.log`, `.cache/`, `tmp/` |

## DryRun Preview

When you use `-DryRun`, the script shows a visual preview of exactly what it would change:

```
  ┌─ octocat/my-app (JavaScript)
  │  + CREATE .gitignore (JavaScript template)
  │  Patterns to add:
  │    + node_modules/
  │    + dist/
  │    + coverage/
  │  - UNTRACK 1503 junk file(s) via git rm --cached
  │    - node_modules/express/index.js
  │    - node_modules/lodash/lodash.js
  │    ... and 1498 more
  └─
```

This lets you review everything before committing to a full run.

## How the Branch & PR Work

- Branch: **`improvement-YYYY-MM-DD-HHmmss`** (e.g., `improvement-2026-03-17-163045`)
- PR includes a clear description of what changed and why
- **You choose** whether to merge — full control stays with you
- Uses `git rm --cached` — files are **untracked but not deleted** from disk

## Project Structure

```
fixmyrepos/
├── Improve-GitHubRepos.ps1   # Everything in one file — just download and run
├── README.md
├── .gitignore
├── .github/
│   └── workflows/
│       └── improve-gitignore.yml  # GitHub Actions — scheduled/manual runs
├── logs/                      # Generated logs & reports (auto-created)
└── work/                      # Cloned repos (auto-created, temporary)
```

## Security & Trust

> **"Why should I paste my token into a random script?"** — Fair question. Here's why this is safe, and how to verify it yourself.

[![Security Scan](https://github.com/gauravkhuraana/fixmyrepos/actions/workflows/security-scan.yml/badge.svg)](https://github.com/gauravkhuraana/fixmyrepos/actions/workflows/security-scan.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/gauravkhuraana/fixmyrepos/badge)](https://securityscorecards.dev/viewer/?uri=github.com/gauravkhuraana/fixmyrepos)

### Token guarantees

| Claim | How to verify |
|-------|---------------|
| Token is **never written to disk** (logs, reports, files) | `Select-String -Path .\Improve-GitHubRepos.ps1 -Pattern 'GitHubToken' \| Select-String 'Set-Content\|Add-Content\|Out-File'` — returns nothing |
| Token is **only sent to `github.com`** | `Select-String -Path .\Improve-GitHubRepos.ps1 -Pattern 'Invoke-RestMethod'` — every URL is `api.github.com` or `raw.githubusercontent.com` |
| All git output is **redacted** before logging | `Select-String -Path .\Improve-GitHubRepos.ps1 -Pattern 'x-access-token'` — every usage is followed by `replace 'x-access-token:[^@]+@', 'x-access-token:***@'` |
| **No telemetry**, no analytics, no external calls | It's one file — read it. There are zero non-GitHub network calls |

### Automated scanning (CI)

Every push and PR runs [`.github/workflows/security-scan.yml`](.github/workflows/security-scan.yml):

- **PSScriptAnalyzer** — static analysis for PowerShell anti-patterns and security rules
- **CodeQL** — GitHub's semantic code analysis
- **OpenSSF Scorecard** — supply chain security grading
- **Token leak check** — custom job that fails if the token could be logged, saved, or sent to non-GitHub URLs

### Recommended token practices

1. Use a **[fine-grained PAT](https://github.com/settings/tokens?type=beta)** (not classic) — minimum permissions
2. Only grant **Contents: Read/Write** + **Pull requests: Read/Write**
3. Set a **7-day expiration** — one cleanup run is all you need
4. **Revoke the token** immediately after use
5. Use `$env:GITHUB_TOKEN` to avoid token in shell history

### Audit it yourself

It's a single `.ps1` file. No hidden dependencies, no build step, no compiled binaries. Read it — it's straightforward.

See [SECURITY.md](SECURITY.md) for the full security policy and vulnerability reporting.

## Smart Behavior

- **Git check** — verifies `git` is installed before doing anything; clear error message if missing
- **Rate limit detection** — if the GitHub API returns a 403/429, the script tells you why and how to fix it
- **Progress counter** — shows `[3/47]` during analysis so you know it's not stuck
- **Branch-exists guard** — if `improvement-YYYY-MM-DD` already exists on a repo (re-run same day), it skips instead of failing
- **DirectPush confirmation** — requires typing 'yes' before committing directly to default branches
- **Revert safety** — `-Revert` undoes everything: closes PRs, deletes branches, and `git revert`s direct-push commits
- **Token redaction** — any git output that might contain the token is automatically scrubbed before logging
- **Auto-open report** — on Windows, the Markdown report opens automatically when finished
- **Cleanup flag** — pass `-Cleanup` to delete cloned repos from `WorkDir` after PRs are created
- **ExcludeRepo** — skip specific repos when scanning all: `-ExcludeRepo "old-junk,experiments"`
- **DryRun preview** — shows exactly what patterns would be added and files untracked, per repo
- **JSON export** — every run produces a `.json` alongside the Markdown report, ready for dashboards or CI

## GitHub Actions

A ready-made workflow is included at `.github/workflows/improve-gitignore.yml`.

**Setup:**

1. Add your PAT as a repository secret named `IMPROVE_GH_TOKEN`
2. Edit the workflow — set `GITHUB_USER` to your username
3. Push — it runs monthly (1st of each month, DryRun) or on-demand from the Actions tab

Manual runs let you choose: dry run, target specific repos, exclude repos, or direct push.

Reports are uploaded as **workflow artifacts** (retained 30 days).

## License

MIT — use freely, improve freely.
