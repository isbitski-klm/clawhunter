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

ClawHunter can route each phase through one of two classes of LLM providers. **The class matters: it determines where the code under analysis flows, which is a data-handling and risk decision, not just a capability choice.**

### Two classes of providers

| Class | Examples | Data flow | Auth | Typical use |
|-------|----------|-----------|------|-------------|
| **Local / on-prem** | `dsv4` (DeepSeek-V4-Flash on vLLM), or any self-hosted OpenAI-compatible endpoint | Prompt + code stay inside your infrastructure | None (keyless; the network boundary is the auth) | Code that is proprietary, under NDA, subject to regulatory review, or simply should not leave your network |
| **External / cloud** | `grok` (xAI), `anthropic` (Anthropic), `openai` (OpenAI) | Prompt + code **leave your infrastructure** to the vendor's servers | API key in an environment variable | Stronger reasoning for public, open-source, or code you're comfortable sending to a third party |

**Decision rule:** If the code under analysis is anything other than public open-source you'd freely share, default to a **local provider**. Routing to a cloud provider is an explicit choice that sends the full source text (including any secrets, credentials, or business logic in the scanned files) to a third-party API.

### Config file: `~/.openclaw/workspace/config/clawhunter.json`

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
    },
    "dsv4": {
      "base_url": "http://127.0.0.1:<TUNNEL_PORT>",
      "model": "deepseek-v4-flash"
    }
  }
}
```

Notes:
- `dsv4` is the **local** provider. It has no `enabled` flag and no `api_key_env` — it's keyless, and `base_url` is the only required field. The `enabled` flag is intentionally absent for local providers because "disabling" a local endpoint means the endpoint is down, not that you opted out.
- Cloud providers (`grok`, `anthropic`, `openai`) require `enabled: true` **and** the key in the named environment variable. Missing either → the script fails with a clear error before any data leaves the machine.

### How it works

| Setting | Behavior |
|---------|----------|
| `default_backend: "local"` (default) | All phases run natively through OpenClaw's current model (whatever that is — local or cloud) |
| `phase2_model: "dsv4"` | Phase 2 (Hunt + Falsification + Fix) routes to the **local** inference endpoint; Phases 1 & 3 stay local |
| `phase2_model: "grok"` | Phase 2 (Hunt + Falsification + Fix) routes to the **xAI cloud** API; Phases 1 & 3 stay local |
| `phase2_model: null` | Same as `"local"` — everything runs natively |

**Why only Phase 2?** Phase 1 (Recon) is mostly grep/glob/read — cheap and fast. Phase 3 (Report) is structured output formatting with low reasoning load — it lays out what Phase 2 already determined. Phase 2 is where the heavy lifting happens: holding complex data-flow chains in context while actively trying to disprove findings **and** reasoning through the correct fix (eliminating the vulnerability class, not just patching the PoC). That's where a stronger model genuinely pays for itself — and that's also where the data-flow risk is highest, because Phase 2 sends the most context out of the door.

### CLI flag override

Use `--model` to override config for a single run:
- `--clawhunter --model dsv4` — route Phase 2 through the **local** inference endpoint (recommended default; code stays in your network)
- `--clawhunter --model grok` — route Phase 2 through the **xAI cloud** API (code leaves your network)
- `--clawhunter --model opus` — route Phase 2 through **Anthropic cloud** (code leaves your network)
- `--clawhunter --model local` — force the current OpenClaw model for all phases

### Provider setup

#### Local providers (recommended default for non-public code)

**`dsv4` — DeepSeek-V4-Flash on a self-hosted inference cluster.**

Any OpenAI-compatible endpoint works here. The default example is DeepSeek-V4-Flash served by vLLM on a small local GPU cluster, but the same config shape works with Ollama, llama.cpp, or any other local serving stack.

The endpoint lives on a private network not routable from the host running ClawHunter. The call path is an **SSH local-forward tunnel** to a local port. Set up the tunnel using your own SSH config and infrastructure details — they are **local secrets** and never appear in this document, the scripts, or any committed file.

```bash
# Example shape only. Replace <USER>, <HEAD_NODE>, <LOCAL_PORT>, <REMOTE_PORT>
# with your actual values. These belong in your local SSH config / shell profile,
# not in any file that gets committed.
ssh -f -N -L <LOCAL_PORT>:127.0.0.1:<REMOTE_PORT> <USER>@<HEAD_NODE>
```

Verify: `curl -s <base_url>/v1/models` should list the model. Then `--model dsv4` (or `phase2_model: "dsv4"`) works — no API key, no egress cost, no rate limit (it's your hardware).

**`base_url`, tunnel ports, and SSH hosts are local secrets.** They belong in `config/clawhunter.json` (gitignored, local only) or environment variables — never in the skill document, scripts, or committed code.

#### External / cloud providers (code leaves your infrastructure)

| Provider | API key env var | Vendor |
|----------|----------------|--------|
| `grok` | `GROK_API_KEY` | xAI |
| `anthropic` | `ANTHROPIC_API_KEY` | Anthropic (Opus, Sonnet) |
| `openai` | `OPENAI_API_KEY` | OpenAI (o3, others) |

**Before enabling a cloud provider, confirm you're comfortable sending the scanned code (including any embedded secrets, config files, or business logic) to that vendor's servers.** For proprietary, NDA-covered, or regulated code, prefer a local provider.

When a cloud provider is enabled but its API key is missing, ClawHunter falls back to local with a warning — it never fails hard, and it never sends partial data to the vendor.

### How provider routing works

When Phase 2 is routed to a non-default provider:
1. The main agent writes the hunt + falsification prompt to a file **inside the workspace** (the script rejects paths outside `$HOME/.openclaw/workspace/`). Use `~/.openclaw/workspace/tmp/clawhunter_phase2_prompt.md`.
2. Runs `~/.openclaw/workspace/skills/clawhunter/scripts/external_llm.sh <provider> ~/.openclaw/workspace/tmp/clawhunter_phase2_prompt.md [model]`.
   - For **local** providers: the prompt goes over the private network / tunnel. Nothing leaves your infrastructure.
   - For **cloud** providers: the prompt is POSTed to the vendor's API. The full prompt text (which includes the code under analysis) crosses the wire.
3. Reads the response back and continues the analysis workflow.
4. If the call fails (network error, rate limit, missing key), falls back to the local model with a note.

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

### Phase 2: Hunt + Falsification + Fix (Main Agent)

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
