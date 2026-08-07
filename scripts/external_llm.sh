#!/usr/bin/env bash
# external_llm.sh — Route a prompt through an external LLM API provider.
# Usage: ./external_llm.sh <provider> <prompt_file> [model_override]
#   provider: grok | anthropic | openai
#   prompt_file: path to file containing the prompt text
#   model_override: optional model name (uses config default if omitted)
#
# Reads API key from environment variable specified in clawhunter.json.
# Outputs the LLM response to stdout.
# Returns exit code 1 if provider is unavailable or key missing.

set -euo pipefail

PROVIDER="${1:-}"
PROMPT_FILE="${2:-}"
MODEL_OVERRIDE="${3:-}"

if [[ -z "$PROVIDER" || -z "$PROMPT_FILE" ]]; then
    echo "Usage: $0 <provider> <prompt_file> [model_override]" >&2
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

# Check if provider is enabled
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

API_KEY="${!API_KEY_ENV:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: API key not found. Set environment variable: $API_KEY_ENV" >&2
    exit 1
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
        RESPONSE=$(curl -s -X POST "https://api.x.ai/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_KEY" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [
                    {\"role\": \"system\", \"content\": \"You are a security analysis assistant. Provide thorough, evidence-based findings.\"},
                    {\"role\": \"user\", \"content\": \"$PROMPT\"}
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
        RESPONSE=$(curl -s -X POST "https://api.openai.com/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_KEY" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [
                    {\"role\": \"system\", \"content\": \"You are a security analysis assistant. Provide thorough, evidence-based findings.\"},
                    {\"role\": \"user\", \"content\": \"$PROMPT\"}
                ],
                \"max_tokens\": 8192,
                \"temperature\": 0.1
            }")
        echo "$RESPONSE" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data['choices'][0]['message']['content'])"
        ;;

    *)
        echo "Error: unknown provider '$PROVIDER'. Supported: grok, anthropic, openai" >&2
        exit 1
        ;;
esac
