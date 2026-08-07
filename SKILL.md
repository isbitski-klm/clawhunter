---
name: clawhunter
description: >
  Attacker-first static code analysis with falsification engine and pluggable LLM backend.
---

# ClawHunter — Attacker-First Static Code Analysis

## Overview

A structured static analysis workflow that applies proactive, attacker-first reasoning to source code. Unlike traditional pattern-matching scanners that flag suspicious constructs and flood teams with false positives, ClawHunter reasons through data flows: it identifies which issues are actually exploitable, maps prospective attack paths, and proposes targeted, evidence-backed fixes.

**Adapted from Capital One's VulnHunter** (Apache 2.0). The methodology is identical — attacker-first forward analysis, falsification engine, evidence-backed remediation — but the implementation uses OpenClaw primitives with a pluggable LLM backend.

## Trigger

When invoked with any of these patterns:
- `/clawhunter` or `clawhunter`
- "scan this codebase for security vulnerabilities"
- "do a security audit on [path]"
- "find exploitable bugs in [repo]"
- "run clawhunter against [target]"

## Backend Configuration

ClawHunter runs by default using whatever LLM OpenClaw is configured with (local or remote). You can optionally route specific phases through external API providers for stronger reasoning.

### Config File: `~/.openclaw/workspace/config/clawhunter.json`

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

### How It Works

| Setting | Behavior |
|---------|----------|
| `default_backend: "local"` (default) | All phases run natively through OpenClaw's current model |
| `phase2_model: "grok"` | Phase 2 (Hunt + Falsification) routes to the grok provider; Phases 1 & 3 stay local |
| `phase2_model: null` | Same as `"local"` — everything runs natively |

**Why only Phase 2?** Phase 1 (Recon) is mostly grep/glob/read — cheap and fast. Phase 3 (Report) is structured output generation with low reasoning load. Phase 2 is where the heavy lifting happens: holding complex data-flow chains in context while actively trying to disprove findings. That's where a stronger model genuinely pays for itself.

### CLI Flag Override

Use `--model` to override config for a single run:
- `--clawhunter --model grok` — route Phase 2 through Grok API
- `--clawhunter --model opus` — route Phase 2 through Anthropic Opus
- `--clawhunter --model local` — force local (overrides config)

### Provider Setup

**Grok:** Set `GROK_API_KEY` in your environment. The provider uses the xAI Grok API endpoint.

**Anthropic:** Set `ANTHROPIC_API_KEY`. Supports Opus and Sonnet models.

**OpenAI:** Set `OPENAI_API_KEY`. Supports o3 and other reasoning models.

When a provider is enabled but its API key is missing, ClawHunter falls back to local with a warning — it never fails hard.

### How External Routing Works

When Phase 2 needs external inference:
1. The main agent writes the hunt + falsification prompt to a temp file (`/tmp/clawhunter_phase2_prompt.md`)
2. Runs `~/.openclaw/workspace/skills/clawhunter/scripts/external_llm.sh <provider> /tmp/clawhunter_phase2_prompt.md [model]`
3. Reads the response back and continues the analysis workflow
4. If the external call fails (network error, rate limit), falls back to local with a note

The script handles all provider-specific API formatting (headers, auth, message structure). You just enable the provider in config and point Phase 2 at it.

## Operating Principles

1. **Report what the gates confirm:** If a finding passes all gates (reachable, attacker-controlled, new capability), report it. Do not second-guess with vague "low impact" reasoning.
2. **Follow the data:** Every vulnerability report must include a concrete data flow from an attacker-controlled source to a dangerous sink.
3. **Prove it:** Every finding must have a PoC (runnable or static trace). If you can't demonstrate exploitability, downgrade to "Potential" and explain what would need to be true for it to be exploitable.
4. **Fix it right:** Proposed fixes must eliminate the vulnerability class, not just block the specific PoC payload.
5. **Production code only:** Only audit first-party production source code. Always ignore:
   - Test code: `**/test/**`, `**/tests/**`, `**/__tests__/**`, `*_test.go`, `*.test.js`, `*.spec.ts`, `*Test.java`, `*Spec.scala`, `test_*.py`
   - Build/config scripts: `Makefile`, `Dockerfile`, `*.gradle`, `pom.xml`, `package.json`, `setup.py`, `build.sbt`, `*.cmake`, CI/CD configs (except security-relevant infrastructure config like Nginx, reverse proxy, load balancer configs)
   - Vendored/third-party code: `**/vendor/**`, `**/node_modules/**`, `**/third_party/**`, `**/deps/**`
   - Generated code: `**/generated/**`, `**/gen/**`, `**/*.pb.go`, `**/*.generated.*`
   - Documentation: `**/*.md`, `**/*.txt`, `**/*.rst`

If a finding's data flow passes through vendored/third-party code, note the dependency boundary but focus on the first-party code that calls it.

## Analysis Approach

Use available tools — **Grep**, **Glob**, and **Read** — as primary analysis instruments:
- **Glob** for file discovery by language/pattern
- **Grep** for dangerous API calls, sinks, entry points, symbol usages
- **Read** files to inspect full function bodies, context, validation logic

### Investigation Discipline

For each input from the inventory, follow this tool-first order when tracing forward. Each step gates the next:

1. **Read the entry point** that receives this input (HTTP handler, CLI command, queue consumer, gRPC method). Identify every place the input variable is used — assignments, function arguments, template interpolations, string concatenation.
2. **Trace forward using Grep.** For each function the input is passed to, grep for that function's definition, then read the body. Follow it across files and through intermediate functions until it reaches a sink, is sanitized, or exits the codebase. **Never stop at an abstraction boundary.** When the trace reaches a dispatching function (router, middleware chain, strategy selector), you MUST trace into each target.
3. **Exhaust ALL code paths.** If input is used in 3 places, trace all 3. A safe path does NOT clear the input — only proving ALL paths are safe does. Check for early-return guard clauses but verify validation is complete (e.g., `input != null` doesn't protect against injection).
4. **Follow through stores.** If input is written to a database, cache, or queue, trace who reads from that store and continue following the data.
5. **Follow through outbound responses (response taint propagation).** If user input controls the scheme, host, or port of an outbound HTTP request URL, the response body is attacker-controlled. Trace where that response flows — if it reaches HTML rendering sinks (`innerHTML`, `dangerouslySetInnerHTML`), that's DOM XSS.
6. **Read source at the sink** — Only after steps 1-5 identify a potential sink, read actual code to confirm input reaches it without effective sanitization.
7. **Transitive caller search on the sink.** When a forward trace identifies a candidate sink, grep for ALL callers of the sink function and continue until you reach entry points or exhaust the chain.

## Workflow: Hunt → Report

### Step 0: Resolve Target & Mode

**Target:** The current directory, unless invocation names a path. Confirm in one line.

**Mode:** If not already specified, ask via menu:
- **Read-only** (static analysis only — exploit tests written but not run; safest)
- **Bash-enabled** (install deps + run exploit tests; needs Bash; trusted code only)

Do NOT start Phase 1 until mode is resolved.

### Step 1: Dependency Installation (Bash-enabled only)

Detect package manager and install:
- `package.json` → `npm install`
- `requirements.txt` / `pyproject.toml` → `pip install -r requirements.txt`
- `go.mod` → `go mod download`
- `pom.xml` → `mvn dependency:resolve`

If it fails or sandbox blocks, give the user the exact command and STOP. Do NOT proceed until deps are installed or user says "skip."

### Phase 1: Reconnaissance (Sub-Agent)

Launch a sub-agent for attack surface mapping. The sub-agent receives this prompt:

```
Your scan directory is: ${TARGET_DIR}

Goal: Map the complete attack surface before looking for specific vulnerabilities.

Step 1: Structural Overview
- Glob all production source files by language extension (*.js, *.ts, *.go, *.java, *.py, etc.)
- Exclude test, vendor, generated, third-party directories
- Identify languages used, frameworks in use (web frameworks, ORMs, crypto libraries), module structure

Step 2: Sink Enumeration Pre-Pass
- Grep for ALL dangerous sink patterns adapted to detected frameworks, including template-level sinks ([href], v-html)
- Record each sink's file:line to create a sink inventory
- Completeness cross-check: confirm every app/module has at least one sink entry; if zero, run targeted grep within that directory
- URL-path-concatenation sweep: grep for string concatenation/interpolation into HTTP client URL arguments (SSRF/path-traversal sinks)

Step 3: Input Inventory (CRITICAL — drives entire audit)
Enumerate every point where external data enters the codebase. Search for detected framework's input-parsing APIs and read each entry point to enumerate its inputs.

Where to look:
- HTTP: req.params, req.query, req.body, req.headers, req.cookies; Spring @RequestParam, @PathVariable, @RequestBody; Go r.URL.Query(), r.FormValue(); Flask/Django request.args, request.form, request.json
- gRPC/RPC: protobuf message fields in service method signatures
- CLI: flag definitions, argparse arguments, process.argv
- Message queues: Kafka/SQS/RabbitMQ consumer message bodies and headers
- Serverless: event object fields (API Gateway, SQS trigger, S3 event)
- WebSocket: message handler payloads
- File processors: file content, file names, MIME types from uploads/watched dirs
- HTTP middleware/interceptors that pass request data to sinks

What to enumerate for each entry point:
- Route parameters, query strings, request bodies, headers, cookies
- File uploads (content, names, MIME types)
- URL/path components used in downstream logic
- Environment variables/config values an attacker could influence
- Message queue/event consumer inputs

Output format — write to ${TARGET_DIR}/clawhunter_recon.md:

## Partition Table
| Partition ID | App/Module | Entry Points (count) | Sinks (count) | Files |
|-------------|------------|---------------------|---------------|-------|

## Input Inventory
| # | Type | Source Location | Framework Field | Description |
|---|------|----------------|-----------------|-------------|

## Sink Inventory
| # | File:Line | Sink Pattern | Risk Level | Language |
|---|----------|--------------|------------|----------|

Return only a one-line confirmation. Do not include analysis in your response.
```

After sub-agent completes, verify the recon file exists. Read ONLY the partition table and input inventory for dispatch — not the full analysis.

### Phase 2: Hunt + Falsification (Main Agent)

For each entry point from the input inventory, trace forward to dangerous sinks using the Investigation Discipline above. For each candidate vulnerability found, run the **Falsification Engine**:

#### Falsification Checklist

Before reporting a finding, actively try to disprove it by checking:

1. **Input validation:** Is there sanitization, type checking, length limits, format validation on this input before it reaches the sink?
2. **Authentication/Authorization:** Does every code path require auth? Are there authorization checks at the handler level or middleware?
3. **Scope enforcement:** Is there tenant/user scoping that prevents cross-resource access?
4. **Output encoding:** Is data escaped/encoded before reaching rendering sinks (HTML, SQL, command line)?
5. **Security controls:** WAF rules, CSP headers, rate limiting, input length limits at the framework level
6. **Code path coverage:** Have I checked ALL paths, or just one? An unsanitized path on one branch doesn't mean all branches are vulnerable

**Disposition rules:**
- If falsification finds a blocking control → mark as "Blocked" and move on (do NOT report)
- If falsification finds gaps in only some paths → report the unsafe paths specifically
- If falsification cannot disprove the finding after thorough attempt → **REPORT IT** with full evidence

### Phase 3: Report Findings

For each verified vulnerability, produce a structured report:

```markdown
## VULN-NNN: [Short Title]

**Severity:** Critical / High / Medium / Low
**CWE:** CWE-XXX (e.g., CWE-89 SQL Injection)
**Status:** Verified Exploitable / Potential

### Attack Path
1. Entry point: [file:line, framework field] — attacker controls this input
2. Data flow: [intermediate functions/files with line numbers]
3. Sink: [file:line, dangerous API call] — unsanitized input reaches here

### Exploitability Evidence
- [Concrete proof: runnable PoC, static trace, or explanation of what would need to be true for "Potential"]
- [Specific capabilities/access an attacker gains]

### Structural Flaw
[Why this exists at the code level — not just "input isn't sanitized" but which validation is missing and why the architecture allows it]

### Proposed Fix
```diff
[file:line]
- [vulnerable code]
+ [fixed code with explanation]
```

### Impact
[What an attacker can do if this is exploited — data access, privilege escalation, RCE, etc.]
```

Write full report to `${TARGET_DIR}/clawhunter_report.md`.

## Sink Reference (Common Patterns)

See `references/sink-patterns.md` for detailed sink patterns by language/framework.

### Injection Sinks
- **SQL:** `execute()`, `query()`, raw SQL strings with string interpolation/concatenation
- **Command Injection:** `exec()`, `spawn()`, `system()`, backtick execution, shell=True
- **XSS:** `innerHTML`, `dangerouslySetInnerHTML`, `v-html`, unescaped template output to HTML
- **LDAP/OSI/NOSQL:** Unsanitized input in query filters or search strings

### SSRF Sinks
- HTTP client calls where URL/host/port comes from user input (string concatenation, template interpolation)
- XML external entity processing with user-controlled content

### Path Traversal Sinks
- File read/write operations using user-controllable paths
- Archive extraction without path validation

### Deserialization Sinks
- `pickle.load()`, `yaml.load()` (unsafe), `ObjectInputStream.readObject()`, untrusted JSON deserialization to objects

### Authorization Bypass Patterns
- IDOR: resource identifiers from user input used in database queries/API calls without ownership verification
- Horizontal/vertical privilege escalation via manipulated role/permission fields

## Output Files

All artifacts go into `${TARGET_DIR}/clawhunter_results/` (create if needed):
- `clawhunter_recon.md` — Reconnaissance output (partition table, input/sink inventories)
- `clawhunter_report.md` — Final vulnerability report with all verified findings

## Automation Notes

For batch scanning or CI/CD integration:
1. Clone target repo to a temp directory
2. Run `/clawhunter` against it
3. Collect `${TARGET_DIR}/clawhunter_results/clawhunter_report.md`
4. File GitHub issues for confirmed Critical/High findings using `gh issue create`

## Security & Responsibility

- Only scan codebases you are explicitly authorized to analyze
- Read-only mode is recommended for untrusted or third-party code
- Bash-enabled mode should only be used on trusted, first-party repositories
- This tool performs dual-use cybersecurity work (vulnerability discovery)

---

*Adapted from Capital One's VulnHunter (Apache 2.0). Original methodology: attacker-first forward analysis with falsification engine.*
