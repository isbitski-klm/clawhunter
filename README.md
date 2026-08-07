# ClawHunter

**Attacker-first static code analysis with a falsification engine.** Adapted from Capital One's [VulnHunter](https://github.com/capitalone/vulnhunter) for the OpenClaw ecosystem.

Unlike traditional code analysis tools that flag suspicious patterns and flood teams with false positives, ClawHunter reasons through data flows: it identifies which issues are actually exploitable, maps prospective attack paths, and proposes targeted, evidence-backed fixes.

## ⚠️ Cyber-Safeguard Disclaimer

ClawHunter performs dual-use cybersecurity work (vulnerability discovery and exploitation analysis). If you run it against an Anthropic account that is not enrolled in Anthropic's [Cyber Verification Program](https://support.claude.com/en/articles/14604842-real-time-cyber-safeguards-on-claude), real-time cyber safeguards may block requests and your usage may be flagged for cyber abuse. If you intend to use ClawHunter on Anthropic's first-party platforms (Claude API / Claude Code), we strongly recommend enrolling first via the [verification portal](https://portal.anthropic.com/programs/cvp).

## Origin & Attribution

ClawHunter is adapted from **Capital One's VulnHunter**, an open-source agentic AI security tool developed internally at Capital One and released to the community. The original methodology — attacker-first forward analysis with a falsification engine — was designed by Capital One's security team to address the fundamental flaw in traditional SAST: scanning for suspicious patterns backward from sinks, which floods teams with false positives.

VulnHunter runs as three composable [Claude Code](https://docs.claude.com/en/docs/claude-code) skills (`/vulnhunt`, `/vulnhunter-fix`, `/vulnhunt-fix-verify`). ClawHunter adapts the same methodology for OpenClaw, replacing Claude Code-specific plumbing with OpenClaw primitives (sub-agents, tool dispatch, structured prompts).

**Original:** [capitalone/vulnhunter](https://github.com/capitalone/vulnhunter) — Apache 2.0  
**Adaptation:** ClawHunter for OpenClaw — Apache 2.0

## How It Works: The Three Phases

### Phase 1: Reconnaissance (Sub-Agent)

Maps the complete attack surface before looking for specific vulnerabilities. A sub-agent enumerates:
- **Entry points** — every place external data enters the codebase (HTTP handlers, CLI args, message queues, file uploads, etc.)
- **Sinks** — dangerous API calls that could be exploited if reached with attacker-controlled input
- **Partition table** — groups apps/modules by their entry point and sink counts

This phase is mostly grep/glob/read operations. It's cheap, fast, and model-agnostic.

### Phase 2: Hunt + Falsification (Main Agent) ⭐

For each entry point identified in Phase 1, the main agent traces forward through data flows to dangerous sinks using a structured investigation discipline:

1. Read the entry point that receives input
2. Trace forward — follow every function call across files
3. Exhaust ALL code paths (one safe path doesn't clear the input)
4. Follow through stores (databases, caches, queues)
5. Follow outbound responses (response taint propagation)
6. Read source at the sink to confirm unsanitized reachability

Then runs the **Falsification Engine** — actively tries to disprove each candidate finding by checking for input validation, auth checks, scope enforcement, output encoding, and security controls. Only findings that survive falsification are reported.

**This is where a stronger model matters most.** Phase 2 requires holding complex data-flow chains in context while actively trying to disprove them — the kind of deep reasoning where frontier models (Opus, Grok, o3) outperform smaller ones. This is why ClawHunter supports offloading Phase 2 to external LLM APIs.

### Phase 3: Report Findings

For each verified vulnerability, produces a structured report with:
- Attack path (entry point → data flow → sink)
- Exploitability evidence (PoC or static trace)
- Structural flaw explanation
- Proposed fix with diff
- Impact assessment

## Quick Start

### Prerequisites

- OpenClaw installed and running
- A codebase to scan (local directory or cloned repo)

### Run a Scan

```
/clawhunter /path/to/repo --mode read-only
```

Or simply:
```
/clawhunter
```

This scans the current directory. Mode defaults to read-only unless you specify `--mode bash-enabled`.

### Default Behavior: Local Analysis

ClawHunter runs by default using whatever LLM OpenClaw is configured with — no external API keys needed, no extra cost. This is intentional and recommended for most use cases:

- **Local models like Qwen 35B are sufficient** for many real-world codebases. The methodology (attacker-first analysis + falsification) is a reasoning framework, not a model-specific trick. A well-structured prompt with a capable local model will find genuine vulnerabilities in typical web applications, CLIs, and services.
- **Zero marginal cost.** No API calls, no per-token charges. You can scan multiple repos or iterate on findings without worrying about bill shock.
- **Privacy-preserving.** Code never leaves your machine.

### When to Offload Phase 2 to an External LLM

There are cases where a stronger model genuinely helps:

| Scenario | Why external helps |
|----------|-------------------|
| Complex microservices with deep call chains | Stronger models hold longer data-flow traces without losing context |
| Unfamiliar frameworks/stacks | Better at recognizing non-obvious sink patterns and framework-specific input parsing |
| High-stakes audits (pre-release, compliance) | Fewer false negatives on edge cases; better falsification reasoning |
| Large codebases with many entry points | More reliable at exhaustively tracing ALL paths rather than stopping early |

**What you don't get from a stronger model:** Better grep/glob/read. Phase 1 and 3 are tool operations, not reasoning tasks — they work identically regardless of the LLM.

## External API Configuration

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

### How Routing Works

| Setting | Behavior |
|---------|----------|
| `phase2_model: null` (default) | All phases run natively through OpenClaw's current model |
| `phase2_model: "grok"` | Phase 2 routes to the Grok API; Phases 1 & 3 stay local |

**Why only Phase 2?** See above — it's the only phase where a stronger LLM provides meaningful ROI.

### One-Time Override with `--model` Flag

```
/clawhunter --model grok    # Route Phase 2 through Grok for this run only
/clawhunter --model opus    # Route Phase 2 through Anthropic Opus
/clawhunter --model local   # Force local (overrides config)
```

### Setting Up a Provider

1. Set the API key in your environment:
   ```bash
   export GROK_API_KEY="your-key-here"
   # or
   export ANTHROPIC_API_KEY="sk-ant-..."
   # or
   export OPENAI_API_KEY="sk-proj-..."
   ```

2. Enable the provider in `clawhunt.json`:
   ```json
   "grok": { "enabled": true, ... }
   ```

3. Set `phase2_model` to route Phase 2:
   ```json
   "phase2_model": "grok"
   ```

When a provider is enabled but its API key is missing, ClawHunter falls back to local with a warning — it never fails hard.

## File Structure

```
clawhunter/
├── SKILL.md                    # Full skill definition (triggers, workflow, prompts)
├── README.md                   # This file
├── LICENSE                     # Apache 2.0
├── references/
│   └── sink-patterns.md        # Detailed sink patterns by language/framework
└── scripts/
    └── external_llm.sh         # External API routing script (grok, anthropic, openai)
```

## Output Files

All artifacts go into `${TARGET_DIR}/clawhunter_results/`:
- `clawhunter_recon.md` — Reconnaissance output (partition table, input/sink inventories)
- `clawhunter_report.md` — Final vulnerability report with all verified findings

## Operating Principles

1. **Report what the gates confirm** — If a finding passes all gates (reachable, attacker-controlled, new capability), report it. No vague "low impact" hand-waving.
2. **Follow the data** — Every vulnerability must include a concrete data flow from source to sink.
3. **Prove it** — Every finding needs a PoC (runnable or static trace). If you can't demonstrate exploitability, downgrade to "Potential."
4. **Fix it right** — Proposed fixes eliminate the vulnerability class, not just block the specific payload.
5. **Production code only** — Ignore test files, vendored dependencies, generated code, and documentation.

## Security & Responsibility

- Only scan codebases you are explicitly authorized to analyze
- Read-only mode is recommended for untrusted or third-party code
- Bash-enabled mode should only be used on trusted, first-party repositories
- This tool performs dual-use cybersecurity work (vulnerability discovery)

## Author

**Michael Isbitski**

- LinkedIn: [linkedin.com/in/michael-isbitski](https://www.linkedin.com/in/michael-isbitski/)
- Website: [klminnovation.com](https://klminnovation.com)

ClawHunter is maintained as an independent project to help practitioners find real vulnerabilities in their codebases using attacker-first reasoning.

## License

Apache 2.0 — see [LICENSE](LICENSE) for details.
Adapted from Capital One's VulnHunter (also Apache 2.0).
