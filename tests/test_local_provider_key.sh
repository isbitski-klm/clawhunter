#!/usr/bin/env bash
# Tests for the optional keyed local provider in scripts/external_llm.sh.
# Runs offline: a mock OpenAI-compatible server on 127.0.0.1 and a temp HOME.
# Usage: bash tests/test_local_provider_key.sh
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/external_llm.sh"
TMP="$(mktemp -d)"
trap 'kill "${SERVER_PID:-}" 2>/dev/null; rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
WS="$HOME/.openclaw/workspace"
mkdir -p "$WS/config" "$WS/tmp"
PROMPT="$WS/tmp/prompt.md"
echo "hello" > "$PROMPT"
AUTH_LOG="$TMP/auth.log"
ARGV_LOG="$TMP/argv.log"

# Mock server: records the Authorization header (or NONE) per request.
cat > "$TMP/server.py" <<'PY'
import http.server, json, sys
log = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        with open(log, "a") as f:
            f.write((self.headers.get("Authorization") or "NONE") + "\n")
        body = json.dumps({"choices": [{"message": {"content": "mock-ok"}}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
python3 "$TMP/server.py" 0 "$AUTH_LOG" > "$TMP/port" &
SERVER_PID=$!
for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"

# curl shim: records argv so we can assert the key never appears there.
mkdir -p "$TMP/bin"
REAL_CURL="$(command -v curl)"
cat > "$TMP/bin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
# CURL_SHIM_DRYRUN=1: record argv only and fail like an unreachable host,
# so tests of non-loopback URLs make no DNS lookup or network request.
if [[ "\${CURL_SHIM_DRYRUN:-}" == 1 ]]; then exit 7; fi
exec "$REAL_CURL" "\$@"
SH
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

write_config() { # $1 = extra JSON fields for dsv4, $2 = base_url
    cat > "$WS/config/clawhunter.json" <<JSON
{ "phase2_model": "dsv4",
  "providers": { "dsv4": { "base_url": "$2", "model": "test-model"$1 } } }
JSON
}

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
reset_logs() { : > "$AUTH_LOG"; : > "$ARGV_LOG"; }
LOCAL="http://127.0.0.1:$PORT"
KEY="test-key-0123456789abcdef"

# 1. Keyless (unchanged behavior): no Authorization header.
reset_logs; write_config "" "$LOCAL"
out=$(env -u LOCAL_LLM_API_KEY bash "$SCRIPT" dsv4 "$PROMPT" 2>&1)
[[ "$out" == "mock-ok" && "$(cat "$AUTH_LOG")" == "NONE" ]] && ok "keyless sends no auth header" || bad "keyless: out=$out auth=$(cat "$AUTH_LOG")"

# 2. Keyed: bearer header sent, key not in output or curl argv.
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY"' "$LOCAL"
out=$(LOCAL_LLM_API_KEY="$KEY" bash "$SCRIPT" dsv4 "$PROMPT" 2>&1)
[[ "$out" == "mock-ok" && "$(cat "$AUTH_LOG")" == "Bearer $KEY" ]] && ok "keyed sends bearer header" || bad "keyed: out=$out auth=$(cat "$AUTH_LOG")"
grep -q "$KEY" "$ARGV_LOG" && bad "key appeared in curl argv" || ok "key not in curl argv"
[[ "$out" != *"$KEY"* ]] && ok "key not in script output" || bad "key in script output"

# 3. Named variant LOCAL_LLM_<NAME>_API_KEY is accepted.
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_GATEWAY_API_KEY"' "$LOCAL"
out=$(LOCAL_LLM_GATEWAY_API_KEY="$KEY" bash "$SCRIPT" dsv4 "$PROMPT" 2>&1)
[[ "$out" == "mock-ok" ]] && ok "named key env accepted" || bad "named key env: $out"

# 4. Keyed but env var missing: fail closed, no request.
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY"' "$LOCAL"
out=$(env -u LOCAL_LLM_API_KEY bash "$SCRIPT" dsv4 "$PROMPT" 2>&1); rc=$?
[[ $rc -ne 0 && ! -s "$AUTH_LOG" ]] && ok "missing key fails closed" || bad "missing key: rc=$rc out=$out"

# 5. Env var name outside the allowlist (e.g. a cloud key or PATH): refused.
for name in GROK_API_KEY PATH LOCAL_LLM_API_KEY_X; do
    reset_logs; write_config ", \"api_key_env\": \"$name\"" "$LOCAL"
    out=$(GROK_API_KEY="$KEY" bash "$SCRIPT" dsv4 "$PROMPT" 2>&1); rc=$?
    [[ $rc -ne 0 && ! -s "$AUTH_LOG" ]] && ok "env name $name refused" || bad "env name $name: rc=$rc out=$out"
done

# 6. Key over plain http to a non-loopback host: refused before any request.
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY"' "http://example.invalid:1"
out=$(LOCAL_LLM_API_KEY="$KEY" bash "$SCRIPT" dsv4 "$PROMPT" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"plain http"* ]] && ok "plain http non-loopback refused" || bad "plain http: rc=$rc out=$out"
grep -q . "$ARGV_LOG" && bad "curl ran for refused plain http" || ok "no request for refused plain http"

# 7. Key with characters that could break the curl config line: refused.
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY"' "$LOCAL"
out=$(LOCAL_LLM_API_KEY='abc" -o /tmp/x' bash "$SCRIPT" dsv4 "$PROMPT" 2>&1); rc=$?
[[ $rc -ne 0 && ! -s "$AUTH_LOG" ]] && ok "bad key characters refused" || bad "bad key chars: rc=$rc out=$out"

# 8. base_url forms that bypassed the old http gate: refused before curl runs.
for url in "HTTP://example.invalid:1" "Http://example.invalid:1" "example.invalid:1" \
           "http:/example.invalid:1" "http://127.0.0.1.example.invalid:1" \
           "http://user@example.invalid:1" "http://example.invalid\\x:1" \
           "http://[::1].example.invalid:1"; do
    reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY"' "$url"
    out=$(LOCAL_LLM_API_KEY="$KEY" bash "$SCRIPT" dsv4 "$PROMPT" 2>&1); rc=$?
    [[ $rc -ne 0 && ! -s "$ARGV_LOG" && "$out" != *Traceback* ]] && ok "base_url $url refused" || bad "base_url $url: rc=$rc out=$out"
done

# 9. Key containing CR/LF: refused before curl runs.
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY"' "$LOCAL"
out=$(LOCAL_LLM_API_KEY=$'abc\r\nheader = "X-Injected: 1"' bash "$SCRIPT" dsv4 "$PROMPT" 2>&1); rc=$?
[[ $rc -ne 0 && ! -s "$ARGV_LOG" ]] && ok "CR/LF key refused" || bad "CR/LF key: rc=$rc out=$out"

# 10. allow_insecure_http as the string "true": refused (must be a JSON boolean).
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY", "allow_insecure_http": "true"' "http://example.invalid:1"
out=$(LOCAL_LLM_API_KEY="$KEY" bash "$SCRIPT" dsv4 "$PROMPT" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"plain http"* && ! -s "$ARGV_LOG" ]] && ok "string \"true\" refused" || bad "string true: rc=$rc out=$out"

# 11. allow_insecure_http as boolean true: gate passes with a warning and curl is invoked.
#     The curl shim runs in dry-run mode here, so nothing is resolved or sent.
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY", "allow_insecure_http": true' "http://example.invalid:1"
out=$(CURL_SHIM_DRYRUN=1 LOCAL_LLM_API_KEY="$KEY" bash "$SCRIPT" dsv4 "$PROMPT" 2>&1)
[[ "$out" == *"Warning: sending API key over plain http"* && -s "$ARGV_LOG" ]] && ok "boolean true allowed with warning" || bad "boolean true: out=$out"

# 12. https base_url: gate passes and curl runs (nothing listens, so the request fails afterward).
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY"' "https://127.0.0.1:1"
out=$(LOCAL_LLM_API_KEY="$KEY" bash "$SCRIPT" dsv4 "$PROMPT" 2>&1)
[[ -s "$ARGV_LOG" && "$out" != *"refusing"* && "$out" != *"must start with"* ]] && ok "https base_url accepted by gate" || bad "https: out=$out"
grep -q "$KEY" "$ARGV_LOG" && bad "key in curl argv (https)" || ok "key not in curl argv (https)"

# 13. localhost is loopback.
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY"' "http://localhost:$PORT"
out=$(LOCAL_LLM_API_KEY="$KEY" bash "$SCRIPT" dsv4 "$PROMPT" 2>&1)
[[ "$out" == "mock-ok" ]] && ok "localhost accepted as loopback" || bad "localhost: $out"

# 14. Loopback bypasses a proxy, so the key never reaches it.
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY"' "$LOCAL"
out=$(http_proxy="http://127.0.0.1:9" HTTP_PROXY="http://127.0.0.1:9" all_proxy="http://127.0.0.1:9" \
      LOCAL_LLM_API_KEY="$KEY" bash "$SCRIPT" dsv4 "$PROMPT" 2>&1)
[[ "$out" == "mock-ok" && "$(cat "$AUTH_LOG")" == "Bearer $KEY" ]] && ok "loopback bypasses proxy" || bad "proxy: out=$out"

# 15. Under bash -x the key is not echoed.
reset_logs; write_config ', "api_key_env": "LOCAL_LLM_API_KEY"' "$LOCAL"
out=$(LOCAL_LLM_API_KEY="$KEY" bash -x "$SCRIPT" dsv4 "$PROMPT" 2>&1)
[[ "$out" == *"mock-ok"* && "$out" != *"$KEY"* ]] && ok "key not shown under bash -x" || bad "xtrace leaked key or failed"

echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
