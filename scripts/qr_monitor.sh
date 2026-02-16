#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# QR Monitor — watches gateway log, emails QR instantly
# Runs as a systemd service. No LLM in the critical path.
#
# When whatsapp_login generates a QR, the base64 PNG appears in
# the session transcript. This script watches for it and emails
# via send_qr.py within seconds.
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

AGENT_NAME="${1:-$(whoami)}"
AGENT_HOME="$(eval echo ~$AGENT_NAME)"
OWNER_EMAIL="${2:-${AGENT_NAME}@nine30.com}"
SEND_QR="$AGENT_HOME/.config/agents-plane/send_qr.py"
SESSION_DIR="$AGENT_HOME/.openclaw/agents/main/sessions"
LAST_QR_HASH=""
CHECK_INTERVAL=2  # seconds

echo "[qr-monitor] Starting for $AGENT_NAME ($OWNER_EMAIL)"
echo "[qr-monitor] Watching $SESSION_DIR for QR codes..."

while true; do
    # Find the latest session transcript
    TRANSCRIPT=$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -1)
    if [ -z "$TRANSCRIPT" ]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # Look for base64 PNG QR data in tool results from whatsapp_login
    # The tool result contains "data:image/png;base64,..." 
    QR_DATA=$(grep -o 'data:image/png;base64,[A-Za-z0-9+/=]\{100,\}' "$TRANSCRIPT" 2>/dev/null | tail -1)
    
    if [ -n "$QR_DATA" ]; then
        # Hash to avoid re-sending same QR
        QR_HASH=$(echo "$QR_DATA" | md5sum | cut -d' ' -f1)
        
        if [ "$QR_HASH" != "$LAST_QR_HASH" ]; then
            echo "[qr-monitor] $(date +%H:%M:%S) New QR detected! Hash: $QR_HASH"
            
            # Strip prefix and pipe to send_qr.py
            B64=$(echo "$QR_DATA" | sed 's|data:image/png;base64,||')
            echo "$B64" | python3 "$SEND_QR" "$OWNER_EMAIL" -
            
            if [ $? -eq 0 ]; then
                echo "[qr-monitor] $(date +%H:%M:%S) ✅ QR emailed to $OWNER_EMAIL"
                LAST_QR_HASH="$QR_HASH"
            else
                echo "[qr-monitor] $(date +%H:%M:%S) ❌ Email failed, will retry next cycle"
            fi
        fi
    fi
    
    sleep "$CHECK_INTERVAL"
done
