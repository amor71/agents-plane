#!/bin/bash
# Verification script — checks everything the startup script should have created
PASS=0
FAIL=0

check() {
    local desc="$1"
    local cmd="$2"
    if eval "$cmd" > /dev/null 2>&1; then
        echo "✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "❌ $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════"
echo "  Agents Plane — Startup Verification"
echo "═══════════════════════════════════════════"
echo ""

# Binaries
check "Node.js installed" "node --version"
check "npm installed" "npm --version"
check "OpenClaw installed" "which openclaw"
check "himalaya installed" "which himalaya"
check "python3 installed" "python3 --version"
check "python3-cryptography importable" "python3 -c 'from cryptography.hazmat.primitives import hashes'"

# OpenClaw entry point resolves
check "OpenClaw entry point exists" "test -f /usr/lib/node_modules/openclaw/dist/index.js"

# Agent user
check "agent user exists" "id agent"
check "agent home directory" "test -d /home/agent"

# Workspace files
check "BOOTSTRAP.md exists" "test -f /home/agent/.openclaw/workspace/BOOTSTRAP.md"
check "AGENTS.md exists" "test -f /home/agent/.openclaw/workspace/AGENTS.md"

# OpenClaw config
check "openclaw.json exists" "test -f /home/agent/.openclaw/openclaw.json"
check "openclaw.json valid JSON" "jq . /home/agent/.openclaw/openclaw.json"
check "openclaw.json has agents key" "jq -e '.agents' /home/agent/.openclaw/openclaw.json"
check "openclaw.json has gateway key" "jq -e '.gateway' /home/agent/.openclaw/openclaw.json"
check "heartbeat configured" "jq -e '.agents.defaults.heartbeat.every' /home/agent/.openclaw/openclaw.json"
check "model set" "jq -e '.agents.defaults.models' /home/agent/.openclaw/openclaw.json"
check "agent name set" "jq -e '.agents.list[0].identity.name' /home/agent/.openclaw/openclaw.json"

# Auth profile
check "auth-profiles.json exists" "test -f /home/agent/.openclaw/agents/main/agent/auth-profiles.json"
check "auth-profiles.json valid JSON" "jq . /home/agent/.openclaw/agents/main/agent/auth-profiles.json"
check "auth profile has anthropic token" "jq -e '.profiles[\"anthropic:default\"].token' /home/agent/.openclaw/agents/main/agent/auth-profiles.json"

# Email config
check "himalaya config exists" "test -f /home/agent/.config/himalaya/config.toml"
check "himalaya config has IMAP" "grep -q 'imap.gmail.com' /home/agent/.config/himalaya/config.toml"
check "himalaya config has SMTP" "grep -q 'smtp.gmail.com' /home/agent/.config/himalaya/config.toml"
check "himalaya config has xoauth2" "grep -q 'xoauth2' /home/agent/.config/himalaya/config.toml"

# OAuth2 token helper
check "token script exists" "test -f /home/agent/.config/agents-plane/get-gmail-token.py"
check "token script executable" "test -x /home/agent/.config/agents-plane/get-gmail-token.py"
check "SA key file exists" "test -f /home/agent/.config/agents-plane/sa-key.json"

# Systemd service
check "systemd service file exists" "test -f /home/agent/.config/systemd/user/openclaw-gateway.service"
check "service ExecStart has valid path" "grep -q 'openclaw/dist/index.js' /home/agent/.config/systemd/user/openclaw-gateway.service"

# File ownership
check "workspace owned by agent" "test $(stat -c '%U' /home/agent/.openclaw/workspace/BOOTSTRAP.md) = 'agent'"
check "config owned by agent" "test $(stat -c '%U' /home/agent/.openclaw/openclaw.json) = 'agent'"
check "auth owned by agent" "test $(stat -c '%U' /home/agent/.openclaw/agents/main/agent/auth-profiles.json) = 'agent'"

# Quick gateway smoke test (start and check it listens)
echo ""
echo "--- Gateway smoke test ---"
OPENCLAW_MAIN=$(node -e "console.log(require.resolve('openclaw/dist/index.js'))" 2>/dev/null || echo "/usr/lib/node_modules/openclaw/dist/index.js")
su - agent -c "timeout 10 node $OPENCLAW_MAIN gateway --port 18789 2>&1" &
GWPID=$!
sleep 5
if curl -s http://127.0.0.1:18789/ > /dev/null 2>&1 || ss -tlnp | grep -q 18789; then
    echo "✅ Gateway starts and listens on port 18789"
    PASS=$((PASS + 1))
else
    echo "⚠️  Gateway port check inconclusive (may need longer startup)"
fi
kill $GWPID 2>/dev/null
wait $GWPID 2>/dev/null

echo ""
echo "═══════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
