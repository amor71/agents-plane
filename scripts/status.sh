#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║          🤖 Agents Plane — Status Dashboard                     ║
# ╚══════════════════════════════════════════════════════════════════╝

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

CONFIG_DIR="$HOME/.openclaw/agents-plane"
CONFIG_FILE="$CONFIG_DIR/config.json"
AGENTS_DIR="$CONFIG_DIR/agents"

die() { echo -e "  ${RED}❌ $1${NC}"; exit 1; }

[[ ! -f "$CONFIG_FILE" ]] && die "Config not found. Run setup.sh first."

PROJECT_ID=$(jq -r '.gcp.project_id' "$CONFIG_FILE")
PLANE_NAME=$(jq -r '.plane.name' "$CONFIG_FILE")
REGION=$(jq -r '.gcp.region' "$CONFIG_FILE")
ZONE=$(jq -r '.gcp.zone' "$CONFIG_FILE")
DOMAIN=$(jq -r '.workspace.domain' "$CONFIG_FILE")

# ─── Banner ───────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  📊 Agents Plane Status — $PLANE_NAME${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Project:  ${BOLD}$PROJECT_ID${NC}"
echo -e "  Domain:   ${BOLD}$DOMAIN${NC}"
echo -e "  Region:   ${BOLD}$REGION${NC}"
echo -e "  Time:     ${DIM}$(date)${NC}"

# ─── Agents ───────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  🤖 Provisioned Agents${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [[ ! -d "$AGENTS_DIR" ]] || [[ -z "$(ls -A "$AGENTS_DIR" 2>/dev/null)" ]]; then
  echo -e "  ${DIM}No agents provisioned yet.${NC}"
  echo -e "  ${DIM}Run: ./provision-agent.sh user@$DOMAIN${NC}"
  echo ""
  exit 0
fi

# Table header
printf "  ${BOLD}%-25s %-15s %-12s %-10s %-8s${NC}\n" "USER" "VM" "STATUS" "MODEL" "BUDGET"
echo -e "  ${DIM}─────────────────────────────────────────────────────────────────${NC}"

TOTAL=0
RUNNING=0
STOPPED=0
MONTHLY_COST=0

for agent_file in "$AGENTS_DIR"/*.json; do
  [[ ! -f "$agent_file" ]] && continue
  ((TOTAL++))

  email=$(jq -r '.email' "$agent_file")
  vm_name=$(jq -r '.vm_name' "$agent_file")
  model=$(jq -r '.model' "$agent_file")
  budget=$(jq -r '.budget_monthly_usd' "$agent_file")
  vm_zone=$(jq -r '.zone' "$agent_file")

  # Get live VM status
  vm_status=$(gcloud compute instances describe "$vm_name" \
    --zone="$vm_zone" --project="$PROJECT_ID" \
    --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

  case "$vm_status" in
    RUNNING)
      status_icon="${GREEN}● RUNNING${NC}"
      ((RUNNING++))
      ;;
    TERMINATED|STOPPED)
      status_icon="${RED}○ STOPPED${NC}"
      ((STOPPED++))
      ;;
    STAGING|PROVISIONING)
      status_icon="${YELLOW}◐ STARTING${NC}"
      ;;
    NOT_FOUND)
      status_icon="${RED}✗ MISSING${NC}"
      ;;
    *)
      status_icon="${YELLOW}? $vm_status${NC}"
      ;;
  esac

  username="${email%%@*}"
  printf "  %-25s %-15s " "$username" "$vm_name"
  printf "${status_icon}"
  printf "  %-10s \$%-7s\n" "$model" "$budget"

  MONTHLY_COST=$((MONTHLY_COST + budget))
done

echo ""
echo -e "  ${DIM}─────────────────────────────────────────────────────────────────${NC}"

# ─── Summary ──────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  📈 Summary${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Total Agents:    ${BOLD}$TOTAL${NC}"
echo -e "  Running:         ${GREEN}$RUNNING${NC}"
echo -e "  Stopped:         ${RED}$STOPPED${NC}"
echo -e "  Budget (total):  ${BOLD}\$${MONTHLY_COST}/mo${NC}"
echo ""

# ─── GCP Costs (if billing API available) ─────────────────────────

echo -e "  ${DIM}For detailed costs, visit:${NC}"
echo -e "  ${CYAN}https://console.cloud.google.com/billing?project=$PROJECT_ID${NC}"
echo ""

# ─── Health Checks ────────────────────────────────────────────────

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  🏥 Infrastructure Health${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check VPC
NETWORK=$(jq -r '.agents.network' "$CONFIG_FILE")
if gcloud compute networks describe "$NETWORK" --project="$PROJECT_ID" &>/dev/null; then
  echo -e "  ${GREEN}✅${NC} VPC Network ($NETWORK)"
else
  echo -e "  ${RED}❌${NC} VPC Network ($NETWORK) — MISSING"
fi

# Check SA
SA=$(jq -r '.gcp.service_account' "$CONFIG_FILE")
if gcloud iam service-accounts describe "$SA" --project="$PROJECT_ID" &>/dev/null; then
  echo -e "  ${GREEN}✅${NC} Service Account"
else
  echo -e "  ${RED}❌${NC} Service Account — MISSING"
fi

# Check APIs
ENABLED_APIS=$(gcloud services list --enabled --format="value(name)" --project="$PROJECT_ID" 2>/dev/null || echo "")
for api in admin.googleapis.com compute.googleapis.com iam.googleapis.com secretmanager.googleapis.com; do
  short="${api%.googleapis.com}"
  if echo "$ENABLED_APIS" | grep -q "$api"; then
    echo -e "  ${GREEN}✅${NC} API: $short"
  else
    echo -e "  ${RED}❌${NC} API: $short — NOT ENABLED"
  fi
done

echo ""
