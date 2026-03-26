# Security Policy

## Token Handling — How Your Token Is Used

This script requires a GitHub Personal Access Token to create branches, push commits, and open PRs. Here's exactly what happens with it:

### What the token IS used for
- **GitHub API calls** — to `api.github.com` only (list repos, fetch trees, create PRs)
- **Authenticated git clone/push** — via `https://x-access-token:<token>@github.com/...`

### What the token is NOT used for
- **Never written to disk** — not in logs, reports, JSON exports, or any file
- **Never sent to third parties** — no analytics, telemetry, or external services
- **Never stored** — the token exists only in memory during the script's execution
- **Never logged** — all git output is redacted before logging (`x-access-token:***@`)

### How to verify this yourself

The script is a single file. You can audit it in under 5 minutes:

```powershell
# 1. Check every line that references the token variable:
Select-String -Path .\Improve-GitHubRepos.ps1 -Pattern 'GitHubToken' | Select-Object LineNumber, Line

# 2. Verify all outbound URLs are GitHub-only:
Select-String -Path .\Improve-GitHubRepos.ps1 -Pattern 'Invoke-RestMethod|Invoke-WebRequest' | Select-Object LineNumber, Line

# 3. Confirm redaction is applied to all git output:
Select-String -Path .\Improve-GitHubRepos.ps1 -Pattern 'x-access-token' | Select-Object LineNumber, Line
```

### Automated verification

The [Security Scan workflow](.github/workflows/security-scan.yml) runs on every push and PR. It includes a **token-leak-check** job that automatically verifies:
- The token is never written to any file
- All API calls go to `github.com` only
- All git output containing tokens is redacted

## Recommended Token Practices

1. **Use a fine-grained PAT** — [Create one here](https://github.com/settings/tokens?type=beta)
2. **Minimum permissions** — only `Contents: Read and write` + `Pull requests: Read and write`
3. **Set an expiration** — 7 days is enough for a one-time cleanup
4. **Revoke after use** — if this was a one-time run, revoke the token immediately
5. **Use `$env:GITHUB_TOKEN`** — avoids typing the token on the command line (which could appear in shell history)

## Reporting a Vulnerability

If you find a security issue in this script, please:

1. **Do NOT open a public issue**
2. Email the maintainer or use [GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
3. Include steps to reproduce

We take security seriously and will respond promptly.
