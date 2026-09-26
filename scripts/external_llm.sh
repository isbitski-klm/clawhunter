#!/usr/bin/env bash
# external_llm.sh - Route a prompt through a configured LLM provider.
#
# Providers come in two classes with different data-flow and risk profiles:
#
#   LOCAL / ON-PREM providers (e.g., "dsv4")
#     - Run against an OpenAI-compatible endpoint you operate yourself
#       (typically vLLM, Ollama, llama.cpp, etc.) on a private network.
#     - Keyless: no API key required; auth is the network boundary.
#     - Prompt text and code under analysis do NOT leave your infrastructure.
#     - base_url is a local secret and MUST come from config/clawhunter.json.
#     - Endpoint may be on a segment not routable from this host; an SSH
#       local-forward tunnel is the standard call path.
#
#   EXTERNAL / CLOUD providers (e.g., "grok", "anthropic", "openai")
#     - Run against a vendor's public API (xAI, Anthropic, OpenAI, ...).
#     - Require an API key from the environment (see api_key_env in config).
#     - Prompt text and the code under analysis LEAVE your infrastructure
#       to the vendor's servers. Treat this as a data-flow risk decision.
#
# Usage: ./external_llm.sh <provider> <prompt_file> [model_override]
#   provider:     grok | anthropic | openai | dsv4   (or any configured name)
#   prompt_file:  path to file containing the prompt text
#   model_override: optional model name (uses config default if omitted)
#
# Outputs the LLM response to stdout.
# Returns exit code 1 if provider is unavailable or config is missing.

set -euo pipefail

# Whitelist allowed provider values
case "${1:-}" in
    grok|anthropic|openai|dsv4) ;;
    *) echo "Error: unknown provider '${1:-}'. Supported: grok, anthropic, openai, dsv4" >&2; exit 1 ;;
esac

PROVIDER="${1:-}"
PROMPT_FILE="${2:-}"
MODEL_OVERRIDE="${3:-}"

if [[ -z "$PROMPT_FILE" ]]; then
    echo "Usage: $0 <provider> <prompt_file> [model_override]" >&2
    exit 1
fi

# Canonicalize prompt file path and verify it is within the workspace directory
REAL_PROMPT_FILE=$(realpath --relative-to="$HOME/.openclaw/workspace" "$PROMPT_FILE" 2>/dev/null || echo "")
if [[ -z "$REAL_PROMPT_FILE" || "$REAL_PROMPT_FILE" == ..* ]]; then
    echo "Error: prompt file must be within $HOME/.openclaw/workspace/" >&2
    exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: prompt file not found: $PROMPT_FILE" >&2
    exit 1
fi

CONFIG_DIR="$HOME/.openclaw/workspace/config"
CONFIG_FILE="$CONFIG_DIR/clawhunter.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config not found at $CONFIG_FILE" >&2
    exit 1
fi

# Read provider config from clawhunter.json using python3 (no jq dependency)
read_provider_config() {
    local key="$1"
    python3 -c "
import json, sys
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
providers = cfg.get('providers', {})
provider = providers.get('$PROVIDER', {})
keys = '$key'.split('.')
val = provider
for k in keys:
    if isinstance(val, dict):
        val = val.get(k)
    else:
        val = None
        break
if val is None:
    sys.exit(1)
print(val if isinstance(val, str) else json.dumps(val))
" 2>/dev/null
}

# ---- Provider gates ---------------------------------------------------------
# LOCAL providers (dsv4) are keyless: no enabled flag, no API key.
# EXTERNAL providers require: enabled=true, an api_key_env name on the
# whitelist, and a non-empty key in that environment variable.
if [[ "$PROVIDER" != "dsv4" ]]; then
    ENABLED=$(read_provider_config "enabled")
    if [[ "$ENABLED" != "true" ]]; then
        echo "Error: provider '$PROVIDER' is not enabled in config. Set 'enabled': true." >&2
        exit 1
    fi

    # Get API key env var name and read the actual key
    API_KEY_ENV=$(read_provider_config "api_key_env")
    if [[ -z "$API_KEY_ENV" ]]; then
        echo "Error: no api_key_env configured for '$PROVIDER'" >&2
        exit 1
    fi

    # Whitelist allowed API key env var names to prevent reading arbitrary env vars
    case "$API_KEY_ENV" in
        GROK_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY) ;;
        *) echo "Error: invalid api_key_env '$API_KEY_ENV'. Must be one of: GROK_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY" >&2; exit 1 ;;
    esac

    # Read the actual API key from environment
    eval "API_KEY=\"\${$API_KEY_ENV:-}\""
    if [[ -z "$API_KEY" ]]; then
        echo "Error: API key not found. Set environment variable: $API_KEY_ENV" >&2
        exit 1
    fi
fi


# Get model name (use override if provided, otherwise config default)
MODEL=""
case "$PROVIDER" in
    grok)
        MODEL=$(read_provider_config "model")
        ;;
    anthropic)
        # Use first available model or override
        MODELS_JSON=$(read_provider_config "models")
        if [[ -n "$MODEL_OVERRIDE" ]]; then
            MODEL="$MODEL_OVERRIDE"
        else
            MODEL=$(echo "$MODELS_JSON" | python3 -c "import json,sys; models=json.loads(sys.stdin.read()); print(models[0] if models else '')")
        fi
        ;;
    openai)
        if [[ -n "$MODEL_OVERRIDE" ]]; then
            MODEL="$MODEL_OVERRIDE"
        else
            MODEL=$(read_provider_config "model")
        fi
        ;;
    dsv4)
        if [[ -n "$MODEL_OVERRIDE" ]]; then
            MODEL="$MODEL_OVERRIDE"
        else
            MODEL=$(read_provider_config "model")
        fi
        ;;
esac

if [[ -z "$MODEL" ]]; then
    echo "Error: no model configured for '$PROVIDER'" >&2
    exit 1
fi

# Read the prompt
PROMPT=$(cat "$PROMPT_FILE")

# Route to provider-specific endpoint
case "$PROVIDER" in
    grok)
        # xAI Grok API (https://docs.x.ai/docs/overview)
        PROMPT_ENCODED=$(echo "$PROMPT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
        RESPONSE=$(curl -s -X POST "https://api.x.ai/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_KEY" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [
                    {\"role\": \"system\", \"content\": \"You are a security analysis assistant. Provide thorough, evidence-based findings.\"},
                    {\"role\": \"user\", \"content\": $PROMPT_ENCODED}
                ],
                \"max_tokens\": 8192,
                \"temperature\": 0.1
            }")
        echo "$RESPONSE" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data['choices'][0]['message']['content'])"
        ;;

    anthropic)
        # Anthropic Claude API (https://docs.anthropic.com/en/api/claude-api)
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        PROMPT_ENCODED=$(echo "$PROMPT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

        RESPONSE=$(curl -s -X POST "https://api.anthropic.com/v1/messages" \
            -H "Content-Type: application/json" \
            -H "x-api-key: $API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -H "anthropic-dangerous-direct-browser-access: true" \
            -d "{
                \"model\": \"$MODEL\",
                \"max_tokens\": 8192,
                \"messages\": [
                    {\"role\": \"user\", \"content\": $PROMPT_ENCODED}
                ]
            }")
        echo "$RESPONSE" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data['content'][0]['text'])"
        ;;

    openai)
        # OpenAI API (https://platform.openai.com/docs/api-reference/chat/create)
        PROMPT_ENCODED=$(echo "$PROMPT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
        RESPONSE=$(curl -s -X POST "https://api.openai.com/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_KEY" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [
                    {\"role\": \"system\", \"content\": \"You are a security analysis assistant. Provide thorough, evidence-based findings.\"},
                    {\"role\": \"user\", \"content\": $PROMPT_ENCODED}
                ],
                \"max_tokens\": 8192,
                \"temperature\": 0.1
            }")
        echo "$RESPONSE" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data['choices'][0]['message']['content'])"
        ;;

    dsv4)
        # LOCAL inference provider: OpenAI-compatible endpoint on a private
        # network (typically vLLM), keyless. Reached via an SSH local-forward
        # tunnel configured in the local environment.
        # base_url is a local secret: it must come from config/clawhunter.json,
        # never hardcoded here.
        #
        # Data flow: prompt text and code under analysis stay within your
        # infrastructure. This is the preferred default when code is
        # sensitive, proprietary, or under active legal/regulatory review.
        BASE_URL=$(read_provider_config "base_url")
        if [[ -z "$BASE_URL" ]]; then
            echo "Error: no base_url configured for dsv4 in $CONFIG_FILE" >&2
            exit 1
        fi
        PROMPT_ENCODED=$(echo "$PROMPT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
        RESPONSE=$(curl -s -m 600 -X POST "$BASE_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [
                    {\"role\": \"system\", \"content\": \"You are a security analysis assistant. Provide thorough, evidence-based findings.\"},
                    {\"role\": \"user\", \"content\": $PROMPT_ENCODED}
                ],
                \"max_tokens\": 8192,
                \"temperature\": 0.1
            }")
        echo "$RESPONSE" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data['choices'][0]['message']['content'])"
        ;;

    *)
        echo "Error: unknown provider '$PROVIDER'. Supported: grok, anthropic, openai, dsv4" >&2
        exit 1
        ;;
esac
