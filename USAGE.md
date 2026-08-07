# ClawHunter — Usage Guide

Detailed usage instructions for ClawHunter, the attacker-first static code analysis skill adapted from Capital One's VulnHunter.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Scan Modes](#scan-modes)
- [External API Routing](#external-api-routing)
  - [Configuring Providers](#configuring-providers)
  - [Routing Phase 2 to External LLMs](#routing-phase-2-to-external-llms)
  - [One-Time Override with --model Flag](#one-time-override-with--model-flag)
- [Understanding the Output](#understanding-the-output)
- [CI/CD Integration](#cicd-integration)
- [Troubleshooting](#troubleshooting)

---

## Basic Usage

### Scan Current Directory

```
/clawhunter
```

Scans the current working directory using read-only mode by default.

### Scan a Specific Path

```
/clawhunter /path/to/repo
```

### Full Command Syntax

```
/clawhunter [target_path] [--mode read-only|bash-enabled] [--model local|grok|opus]
```

| Argument | Default | Description |
|----------|---------|-------------|
| `target_path` | Current directory | Directory to scan |
| `--mode` | `read-only` | Analysis mode (see below) |
| `--model` | Config default | LLM backend for Phase 2 |

## Scan Modes

### Read-Only (Recommended Default)

Static analysis only. The agent reads code, traces data flows, and identifies vulnerabilities — but does not execute any code or install dependencies. This is the safest mode and appropriate for:
- Third-party codebases you're auditing
- Production repositories where you don't want to modify state
- Initial reconnaissance before a deeper scan

### Bash-Enabled

Installs dependencies and runs exploit tests against identified vulnerabilities. Use only on trusted, first-party repositories where you have explicit authorization to execute code. This mode:
- Detects the package manager (npm, pip, go mod, maven)
- Installs dependencies automatically
- Writes and optionally executes proof-of-concept exploits
- Can modify system state

**Warning:** Bash-enabled mode should never be used on untrusted or third-party codebases without explicit authorization.

## External API Routing

### Why Offload Phase 2?

ClawHunter's three-phase workflow has different reasoning requirements:

| Phase | Reasoning Load | Local Model OK? |
|-------|---------------|-----------------|
| **1 — Recon** | Low (grep/glob/read) | ✅ Yes, always |
| **2 — Hunt + Falsification** | High (deep data-flow tracing, active disproval) | ⚠️ Depends on complexity |
| **3 — Report** | Low (structured output) | ✅ Yes, always |

Phase 2 is where a stronger model provides real value. It requires:
- Holding complex multi-hop data flows in context
- Actively trying to disprove its own findings (falsification)
- Recognizing non-obvious security controls and validation patterns
- Exhaustively tracing ALL code paths, not just the obvious ones

Smaller models like Qwen 35B handle straightforward cases well. But for complex microservices with deep call chains, unfamiliar frameworks, or high-stakes audits, offloading Phase 2 to a frontier model reduces false negatives significantly.

### Configuring Providers

Edit `~/.openclaw/workspace/config/clawhunter.json`:

```json
{
  "default_backend": "local",
  "phase2_model": null,
  "providers": {
    "grok": {
      "enabled": false,
      "api_key_env": "GROK_API_KEY",
      "model": "grok-4-fast"
    },
    "anthropic": {
      "enabled": false,
      "api_key_env": "ANTHROPIC_API_KEY",
      "models": ["claude-opus-4-0", "claude-sonnet-4-0"]
    },
    "openai": {
      "enabled": false,
      "api_key_env": "OPENAI_API_KEY",
      "model": "o3"
    }
  }
}
```

**Provider options:**

| Provider | API Key Env Var | Models Available | Best For |
|----------|-----------------|------------------|----------|
| **Grok** (xAI) | `GROK_API_KEY` | grok-4-fast, grok-4, etc. | Cost-effective strong reasoning |
| **Anthropic** | `ANTHROPIC_API_KEY` | Opus 4, Sonnet 4 | Deepest reasoning, best falsification |
| **OpenAI** | `OPENAI_API_KEY` | o3, o4-mini-reasoning | Structured reasoning tasks |

### Routing Phase 2 to External LLMs

To permanently route Phase 2 through an external provider:

1. Set the API key in your environment (add to shell profile for persistence):
   ```bash
   echo 'export GROK_API_KEY="your-key-here"' >> ~/.bashrc
   source ~/.bashrc
   ```

2. Enable the provider and set `phase2_model`:
   ```json
   {
     "default_backend": "local",
     "phase2_model": "grok",
     "providers": {
       "grok": {
         "enabled": true,
         "api_key_env": "GROK_API_KEY",
         "model": "grok-4-fast"
       }
     }
   }
   ```

3. Run ClawHunter normally — Phase 2 will automatically route through the configured provider:
   ```
   /clawhunter
   ```

### One-Time Override with --model Flag

For a single scan without changing config:

```bash
/clawhunter --model grok    # Use Grok for this run only
/clawhunter --model opus    # Use Anthropic Opus for this run only
/clawhunter --model local   # Force local (overrides any config setting)
```

### Fallback Behavior

If the external API call fails (network error, rate limit, invalid key), ClawHunter automatically falls back to local analysis with a warning message. It never aborts the scan entirely.

## Understanding the Output

All output files are written to `${TARGET_DIR}/clawhunter_results/`:

### `clawhunter_recon.md` — Reconnaissance Report

Contains:
- **Partition Table** — Groups apps/modules by entry point and sink counts
- **Input Inventory** — Every place external data enters the codebase
- **Sink Inventory** — All dangerous API calls found in the codebase

### `clawhunter_report.md` — Final Vulnerability Report

For each verified finding:

```markdown
## VULN-001: SQL Injection in User Search

**Severity:** High
**CWE:** CWE-89 (SQL Injection)
**Status:** Verified Exploitable

### Attack Path
1. Entry point: `src/handlers/user.ts:42` — `req.query.search` parameter
2. Data flow: `searchUsers()` → `buildQuery()` → raw SQL string concatenation
3. Sink: `src/db/query.ts:87` — `connection.execute(rawSQL)` with unsanitized input

### Exploitability Evidence
- Static trace confirms user-controlled `req.query.search` reaches `execute()` without sanitization
- PoC: `GET /api/users?search=' OR '1'='1` returns all users

### Structural Flaw
The query builder accepts raw strings for the search parameter but only validates length (max 200 chars). No parameterized queries or ORM abstraction is used. The architecture allows direct SQL construction from user input because the `buildQuery()` function was designed as a performance optimization to avoid ORM overhead.

### Proposed Fix
```diff
- const query = `SELECT * FROM users WHERE name LIKE '%${search}%'`;
+ const query = 'SELECT * FROM users WHERE name LIKE ?';
+ connection.execute(query, [`%${search}%`]);
```

### Impact
An attacker can extract all user records, bypass authentication, or potentially execute arbitrary SQL commands including data exfiltration and schema modification.
```

**Severity levels:** Critical → High → Medium → Low  
**Status:** Verified Exploitable (PoC demonstrated) / Potential (what would need to be true)

## CI/CD Integration

For automated scanning in your pipeline:

1. Clone the target repo to a temp directory
2. Run ClawHunter against it (via OpenClaw CLI or API)
3. Collect `${TARGET_DIR}/clawhunter_results/clawhunter_report.md`
4. Parse findings and file issues / block merges on Critical/High results

Example workflow:
```bash
# 1. Clone target
git clone https://github.com/org/target-repo.git /tmp/clawhunter-scan

# 2. Run scan (via OpenClaw)
openclaw session send "run clawhunter against /tmp/clawhunter-scan --mode read-only"

# 3. Collect results
cat /tmp/clawhunter-scan/clawhunter_results/clawhunter_report.md > report.md

# 4. Check for critical findings
grep -c "Severity: Critical\|Severity: High" report.md || echo "No high-severity findings"
```

## Troubleshooting

### "Provider not enabled" Error

The provider is disabled in config. Set `"enabled": true` in `clawhunt.json`.

### "API key not found" Warning

The environment variable specified in the provider config isn't set. Check:
```bash
echo $GROK_API_KEY    # or ANTHROPIC_API_KEY, OPENAI_API_KEY
```

### "Falling back to local" Message

The external API call failed (network error, rate limit, invalid response). The scan continues locally. Check your network connection and API key validity.

### Too Many False Positives

This usually means the model isn't strong enough for the falsification phase. Try:
- Offloading Phase 2 to a stronger model (`--model opus`)
- Increasing the scope of falsification checks in the prompt
- Manually reviewing findings against the falsification checklist in SKILL.md

### Scan Takes Too Long

Phase 1 (Recon) on large codebases can be slow due to extensive grep/glob operations. Consider:
- Scanning a specific subdirectory instead of the full repo
- Using `--mode read-only` (faster than bash-enabled which installs deps)
- Excluding known non-source directories in your target path
