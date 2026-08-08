# ClawHunter

**Attacker-first static code analysis with a falsification engine.** Adapted from Capital One's [VulnHunter](https://github.com/capitalone/vulnhunter) for the OpenClaw ecosystem.

Unlike traditional code analysis tools that flag suspicious patterns and flood teams with false positives, ClawHunter reasons through data flows: it identifies which issues are actually exploitable, maps prospective attack paths, and proposes targeted, evidence-backed fixes.

## ⚠️ Cyber-Safeguard Disclaimer

ClawHunter performs dual-use cybersecurity work: vulnerability discovery and exploitation analysis. This means it can trigger safety mechanisms at multiple layers, not just from the LLM provider but also from the platform running it.

### What can trigger safeguards

**LLM providers.** Frontier model providers (Anthropic, OpenAI, xAI, etc.) have increasingly aggressive real-time cyber guardrails. ClawHunter's prompts contain attacker-first reasoning patterns: data-flow tracing toward dangerous sinks, falsification of security controls, and exploitability assessment. These patterns may be flagged as potentially malicious even when used for legitimate security auditing. If you run it against an Anthropic account not enrolled in their [Cyber Verification Program](https://support.claude.com/en/articles/14604842-real-time-cyber-safeguards-on-claude), requests may be blocked and your usage flagged for abuse review.

**OpenClaw.** OpenClaw itself has safety layers that monitor agent behavior. Because ClawHunter instructs the model to reason about exploitability, trace attack paths, and propose fixes for real vulnerabilities, it can trigger OpenClaw's own content filters or behavioral safeguards, especially in sessions with stricter moderation settings. You may see warnings, blocked tool calls, or session interruptions.

**Your own infrastructure.** If ClawHunter is running in a CI/CD pipeline, shared workspace, or multi-user environment, the output (exploit traces, vulnerability reports) contains sensitive information about your codebase's security posture. Treat it like any other security audit artifact. Restrict access and do not commit findings to public repos without redaction.

### Proceed with caution

- **Only scan codebases you are explicitly authorized to analyze.** This includes third-party dependencies only if you have permission from the owner or maintainer.
- **Be aware of what you're testing.** ClawHunter does more than find bugs. It constructs plausible attack narratives. Understanding the methodology helps you interpret results correctly and avoid false confidence in either direction (over-reporting or under-reporting).
- **Use read-only mode for untrusted code.** Bash-enabled mode installs dependencies and can execute proof-of-concept exploits. Never use this on codebases where you don't have explicit authorization to modify state.
- **Follow responsible disclosure best practices.** If ClawHunter finds vulnerabilities in third-party software, report them through the maintainer's preferred channel (security.txt, vulnerability database, direct contact). Don't publish exploit details publicly without coordination.
- **Enroll in provider verification programs if you plan heavy use.** Anthropic's [Cyber Verification Program](https://portal.anthropic.com/programs/cvp) is designed for exactly this kind of work. It reduces the chance of false-positive abuse flags and gives you access to stronger models optimized for security analysis.

ClawHunter is a tool, not a verdict. The findings it produces are starting points for human review, not automated determinations of exploitability or risk.

## Origin & Attribution

ClawHunter is adapted from **Capital One's VulnHunter**, an open-source agentic AI security tool developed internally at Capital One and released to the community. The original methodology (attacker-first forward analysis with a falsification engine) was designed by Capital One's security team to address the fundamental flaw in traditional static analysis: scanning for suspicious patterns backward from sinks, which floods teams with false positives.

VulnHunter runs as three composable [Claude Code](https://docs.claude.com/en/docs/claude-code) skills (`/vulnhunt`, `/vulnhunter-fix`, `/vulnhunt-fix-verify`). ClawHunter adapts the same methodology for OpenClaw, replacing Claude Code-specific plumbing with OpenClaw primitives (sub-agents, tool dispatch, structured prompts).

**Original:** [capitalone/vulnhunter](https://github.com/capitalone/vulnhunter) (Apache 2.0)
**Adaptation:** ClawHunter for OpenClaw (Apache 2.0)

## How It Works: The Three Phases

### Phase 1: Reconnaissance (Sub-Agent)

Maps the complete attack surface before looking for specific vulnerabilities. A sub-agent enumerates:
- **Entry points**: every place external data enters the codebase (HTTP handlers, CLI args, message queues, file uploads, etc.)
- **Sinks**: dangerous API calls that could be exploited if reached with attacker-controlled input
- **Partition table**: groups apps/modules by their entry point and sink counts

This phase is mostly grep/glob/read operations. It's cheap, fast, and model-agnostic.

### Phase 2: Hunt + Falsification (Main Agent) ⭐

For each entry point identified in Phase 1, the main agent traces forward through data flows to dangerous sinks using a structured investigation discipline:

1. Read the entry point that receives input
2. Trace forward: follow every function call across files
3. Exhaust ALL code paths (one safe path doesn't clear the input)
4. Follow through stores (databases, caches, queues)
5. Follow outbound responses (response taint propagation)
6. Read source at the sink to confirm unsanitized reachability

Then runs the **Falsification Engine**: it actively tries to disprove each candidate finding by checking for input validation, auth checks, scope enforcement, output encoding, and security controls. Only findings that survive falsification are reported.

**This is where a stronger model matters most.** Phase 2 requires holding complex data-flow chains in context while actively trying to disprove them. This is the kind of deep reasoning where frontier models (Opus, Grok, o3) outperform smaller ones. This is why ClawHunter supports offloading Phase 2 to external LLM APIs.

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

ClawHunter runs by default using whatever LLM OpenClaw is configured with. No external API keys needed, no extra cost. This is intentional and recommended for most use cases:

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

**What you don't get from a stronger model:** Better grep/glob/read. Phase 1 and 3 are tool operations, not reasoning tasks. They work identically regardless of the LLM.

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

**Why only Phase 2?** As noted above: it is the only phase where a stronger LLM provides meaningful ROI.

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

When a provider is enabled but its API key is missing, ClawHunter falls back to local with a warning. It never fails hard.

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
- `clawhunter_recon.md`: Reconnaissance output (partition table, input/sink inventories)
- `clawhunter_report.md`: Final vulnerability report with all verified findings

## Operating Principles

1. **Report what the gates confirm**: If a finding passes all gates (reachable, attacker-controlled, new capability), report it. No vague "low impact" hand-waving.
2. **Follow the data**: Every vulnerability must include a concrete data flow from source to sink.
3. **Prove it**: Every finding needs a PoC (runnable or static trace). If you can't demonstrate exploitability, downgrade to "Potential."
4. **Fix it right**: Proposed fixes eliminate the vulnerability class, not just block the specific payload.
5. **Production code only**: Ignore test files, vendored dependencies, generated code, and documentation.

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

Apache 2.0. See [LICENSE](LICENSE) for details.
Adapted from Capital One's VulnHunter (also Apache 2.0).
