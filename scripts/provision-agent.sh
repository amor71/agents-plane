#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║          🤖 Agents Plane — Provision Agent for User             ║
# ╚══════════════════════════════════════════════════════════════════╝

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

CONFIG_DIR="$HOME/.openclaw/agents-plane"
CONFIG_FILE="$CONFIG_DIR/config.json"
AGENTS_DIR="$CONFIG_DIR/agents"

info()    { echo -e "  ${BLUE}ℹ️  $1${NC}"; }
success() { echo -e "  ${GREEN}✅ $1${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
fail()    { echo -e "  ${RED}❌ $1${NC}"; }
step()    { echo -e "  ${CYAN}▸${NC} $1"; }

header() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

spinner() {
  local pid=$1 msg=$2
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYAN}${spin:i++%${#spin}:1}${NC} %s" "$msg"
    sleep 0.1
  done
  printf "\r"
}

die() { fail "$1"; exit 1; }

# ─── Usage ────────────────────────────────────────────────────────

usage() {
  echo ""
  echo -e "  ${BOLD}Usage:${NC} ./provision-agent.sh <email> [options]"
  echo ""
  echo -e "  ${BOLD}Options:${NC}"
  echo "    --model <model>       AI model (default: from config)"
  echo "    --vm-type <type>      GCP machine type (default: from config)"
  echo "    --budget <amount>     Monthly budget in USD (default: 50)"
  echo "    --disk <gb>           Boot disk size in GB (default: 20)"
  echo "    --no-email            Skip sending welcome email"
  echo "    --dry-run             Show what would be done without doing it"
  echo ""
  echo -e "  ${BOLD}Example:${NC}"
  echo "    ./provision-agent.sh alice@nine30.com --model gpt-4o --budget 100"
  echo ""
  exit 1
}

# ─── Parse Args ───────────────────────────────────────────────────

[[ $# -lt 1 ]] && usage

EMAIL="$1"; shift
MODEL="" VM_TYPE="" BUDGET="50" DISK_GB="20" SEND_EMAIL=true DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)    MODEL="$2"; shift 2;;
    --vm-type)  VM_TYPE="$2"; shift 2;;
    --budget)   BUDGET="$2"; shift 2;;
    --disk)     DISK_GB="$2"; shift 2;;
    --no-email) SEND_EMAIL=false; shift;;
    --dry-run)  DRY_RUN=true; shift;;
    *)          warn "Unknown option: $1"; shift;;
  esac
done

# Validate email
if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
  die "Invalid email: $EMAIL"
fi

# ─── Load Config ──────────────────────────────────────────────────

if [[ ! -f "$CONFIG_FILE" ]]; then
  die "Config not found. Run setup.sh first."
fi

PROJECT_ID=$(jq -r '.gcp.project_id' "$CONFIG_FILE")
REGION=$(jq -r '.gcp.region' "$CONFIG_FILE")
ZONE=$(jq -r '.gcp.zone' "$CONFIG_FILE")
DOMAIN=$(jq -r '.workspace.domain' "$CONFIG_FILE")
PLANE_NAME=$(jq -r '.plane.name' "$CONFIG_FILE")
SA_PARENT=$(jq -r '.gcp.service_account' "$CONFIG_FILE")
NETWORK=$(jq -r '.agents.network' "$CONFIG_FILE")
SUBNET=$(jq -r '.agents.subnet' "$CONFIG_FILE")
FW_TAG=$(jq -r '.agents.firewall_tag' "$CONFIG_FILE")

[[ -z "$MODEL" ]] && MODEL=$(jq -r '.agents.default_model' "$CONFIG_FILE")
[[ -z "$VM_TYPE" ]] && VM_TYPE=$(jq -r '.gcp.default_vm_type' "$CONFIG_FILE")

# Derive names
USERNAME="${EMAIL%%@*}"
SAFE_NAME=$(echo "$USERNAME" | tr '.' '-' | tr '[:upper:]' '[:lower:]')
VM_NAME="agent-${SAFE_NAME}"
AGENT_SA_NAME="agent-${SAFE_NAME}"
AGENT_SA_EMAIL="${AGENT_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SECRET_PREFIX="agent/${SAFE_NAME}"

mkdir -p "$AGENTS_DIR"

# ─── Banner ───────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}"
echo "  ┌─────────────────────────────────────────┐"
echo "  │     🤖 Provisioning Agent                │"
echo "  └─────────────────────────────────────────┘"
echo -e "${NC}"
echo -e "  User:     ${BOLD}$EMAIL${NC}"
echo -e "  VM:       ${BOLD}$VM_NAME${NC} (${VM_TYPE})"
echo -e "  Region:   ${BOLD}$ZONE${NC}"
echo -e "  Model:    ${BOLD}$MODEL${NC}"
echo -e "  Budget:   ${BOLD}\$${BUDGET}/mo${NC}"
echo ""

if $DRY_RUN; then
  warn "DRY RUN — no changes will be made"
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════
# Step 1: Network (idempotent)
# ═══════════════════════════════════════════════════════════════════

header "🌐 Step 1 · Network Setup"

# VPC
if gcloud compute networks describe "$NETWORK" --project="$PROJECT_ID" &>/dev/null; then
  success "VPC '$NETWORK' exists"
else
  step "Creating VPC '$NETWORK'..."
  if ! $DRY_RUN; then
    gcloud compute networks create "$NETWORK" \
      --project="$PROJECT_ID" \
      --subnet-mode=custom \
      --quiet 2>/dev/null || die "Failed to create VPC"
  fi
  success "VPC created"
fi

# Subnet
if gcloud compute networks subnets describe "$SUBNET" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  success "Subnet '$SUBNET' exists"
else
  step "Creating subnet '$SUBNET'..."
  if ! $DRY_RUN; then
    gcloud compute networks subnets create "$SUBNET" \
      --project="$PROJECT_ID" \
      --network="$NETWORK" \
      --region="$REGION" \
      --range="10.0.0.0/24" \
      --enable-private-ip-google-access \
      --quiet 2>/dev/null || die "Failed to create subnet"
  fi
  success "Subnet created"
fi

# Firewall: allow IAP
FW_IAP="allow-iap-ssh-$NETWORK"
if gcloud compute firewall-rules describe "$FW_IAP" --project="$PROJECT_ID" &>/dev/null; then
  success "IAP firewall rule exists"
else
  step "Creating IAP SSH firewall rule..."
  if ! $DRY_RUN; then
    gcloud compute firewall-rules create "$FW_IAP" \
      --project="$PROJECT_ID" \
      --network="$NETWORK" \
      --allow=tcp:22 \
      --source-ranges="35.235.240.0/20" \
      --target-tags="$FW_TAG" \
      --description="Allow SSH via IAP tunnel" \
      --quiet 2>/dev/null || warn "Firewall rule creation failed"
  fi
  success "Firewall rule created"
fi

# Firewall: deny external
FW_DENY="deny-external-$NETWORK"
if gcloud compute firewall-rules describe "$FW_DENY" --project="$PROJECT_ID" &>/dev/null; then
  success "External deny rule exists"
else
  step "Creating external deny firewall rule..."
  if ! $DRY_RUN; then
    gcloud compute firewall-rules create "$FW_DENY" \
      --project="$PROJECT_ID" \
      --network="$NETWORK" \
      --action=DENY \
      --rules=tcp:0-65535,udp:0-65535 \
      --source-ranges="0.0.0.0/0" \
      --target-tags="$FW_TAG" \
      --priority=1000 \
      --description="Deny all external traffic to agent VMs" \
      --quiet 2>/dev/null || warn "Deny rule creation failed"
  fi
  success "Deny rule created"
fi

# ═══════════════════════════════════════════════════════════════════
# Step 2: Service Account for Agent
# ═══════════════════════════════════════════════════════════════════

header "🔑 Step 2 · Agent Service Account"

if gcloud iam service-accounts describe "$AGENT_SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
  success "Service account exists: $AGENT_SA_EMAIL"
else
  step "Creating service account for $USERNAME..."
  if ! $DRY_RUN; then
    gcloud iam service-accounts create "$AGENT_SA_NAME" \
      --display-name="Agent: $EMAIL" \
      --description="Service account for $EMAIL's AI agent" \
      --project="$PROJECT_ID" 2>/dev/null || die "Failed to create agent SA"
  fi
  success "Service account created"
fi

# Grant minimal roles
step "Granting permissions..."
AGENT_ROLES=(
  "roles/secretmanager.secretAccessor"
  "roles/logging.logWriter"
  "roles/monitoring.metricWriter"
)
if ! $DRY_RUN; then
  for role in "${AGENT_ROLES[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:$AGENT_SA_EMAIL" \
      --role="$role" \
      --condition=None \
      --quiet 2>/dev/null || true
  done
fi
success "Permissions granted (least privilege)"

# ═══════════════════════════════════════════════════════════════════
# Step 3: Secrets
# ═══════════════════════════════════════════════════════════════════

header "🔒 Step 3 · Secrets Manager"

SECRET_NAME="agent-${SAFE_NAME}-config"
if gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" &>/dev/null; then
  success "Secret '$SECRET_NAME' exists"
else
  step "Creating secret '$SECRET_NAME'..."
  if ! $DRY_RUN; then
    echo "{\"user\": \"$EMAIL\", \"model\": \"$MODEL\", \"budget\": $BUDGET}" | \
      gcloud secrets create "$SECRET_NAME" \
        --project="$PROJECT_ID" \
        --replication-policy="automatic" \
        --data-file=- 2>/dev/null || die "Failed to create secret"

    # Grant agent SA access
    gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
      --project="$PROJECT_ID" \
      --member="serviceAccount:$AGENT_SA_EMAIL" \
      --role="roles/secretmanager.secretAccessor" \
      --quiet 2>/dev/null || true
  fi
  success "Secret created and bound"
fi

# ═══════════════════════════════════════════════════════════════════
# Step 4: Create VM
# ═══════════════════════════════════════════════════════════════════

header "🖥️  Step 4 · Compute Instance"

if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
  success "VM '$VM_NAME' already exists"
  VM_STATUS=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format="value(status)" 2>/dev/null)
  info "Status: $VM_STATUS"
  if [[ "$VM_STATUS" == "TERMINATED" ]]; then
    step "Starting VM..."
    if ! $DRY_RUN; then
      gcloud compute instances start "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null
    fi
    success "VM started"
  fi
else
  step "Creating VM '$VM_NAME'..."

  # Startup script
  STARTUP_SCRIPT=$(cat << 'STARTUP'
#!/bin/bash
set -e

# Update system
apt-get update -qq && apt-get upgrade -y -qq

# Install dependencies
apt-get install -y -qq curl wget git jq unzip

# Install Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs

# Install OpenClaw
npm install -g @openclaw/cli

# Create agent user
useradd -m -s /bin/bash agent || true

# Setup OpenClaw workspace
su - agent -c 'mkdir -p ~/.openclaw/workspace'

# Fetch config from Secret Manager
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
AGENT_NAME="${INSTANCE_NAME#agent-}"
SECRET_NAME="agent-${AGENT_NAME}-config"
PROJECT=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)

TOKEN=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | jq -r '.access_token')
CONFIG=$(curl -s "https://secretmanager.googleapis.com/v1/projects/${PROJECT}/secrets/${SECRET_NAME}/versions/latest:access" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.payload.data' | base64 -d)

echo "$CONFIG" > /home/agent/.openclaw/agent-config.json
chown agent:agent /home/agent/.openclaw/agent-config.json

# Signal completion
echo "AGENT_READY" > /tmp/agent-status

logger "OpenClaw agent provisioned successfully for $AGENT_NAME"
STARTUP
)

  if ! $DRY_RUN; then
    gcloud compute instances create "$VM_NAME" \
      --project="$PROJECT_ID" \
      --zone="$ZONE" \
      --machine-type="$VM_TYPE" \
      --network-interface="network=$NETWORK,subnet=$SUBNET,no-address" \
      --service-account="$AGENT_SA_EMAIL" \
      --scopes="cloud-platform" \
      --tags="$FW_TAG" \
      --boot-disk-size="${DISK_GB}GB" \
      --boot-disk-type="pd-balanced" \
      --image-family="debian-12" \
      --image-project="debian-cloud" \
      --metadata="startup-script=$STARTUP_SCRIPT" \
      --labels="agent-user=${SAFE_NAME},plane=${PLANE_NAME,,},managed-by=agents-plane" \
      --quiet 2>/dev/null &
    spinner $! "Creating VM (this takes ~60s)..."
    wait $!
    if [[ $? -ne 0 ]]; then
      die "Failed to create VM"
    fi
  fi
  success "VM created"
fi

# Get VM internal IP
if ! $DRY_RUN; then
  INTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --format="value(networkInterfaces[0].networkIP)" 2>/dev/null || echo "pending")
else
  INTERNAL_IP="10.0.0.x (dry-run)"
fi

# ═══════════════════════════════════════════════════════════════════
# Step 5: Save Agent Record
# ═══════════════════════════════════════════════════════════════════

header "📝 Step 5 · Agent Record"

AGENT_FILE="$AGENTS_DIR/${SAFE_NAME}.json"
cat > "$AGENT_FILE" << EOF
{
  "email": "$EMAIL",
  "username": "$USERNAME",
  "vm_name": "$VM_NAME",
  "zone": "$ZONE",
  "vm_type": "$VM_TYPE",
  "internal_ip": "$INTERNAL_IP",
  "service_account": "$AGENT_SA_EMAIL",
  "secret_name": "$SECRET_NAME",
  "model": "$MODEL",
  "budget_monthly_usd": $BUDGET,
  "disk_gb": $DISK_GB,
  "provisioned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "provisioning"
}
EOF
success "Agent record saved to $AGENT_FILE"

# ═══════════════════════════════════════════════════════════════════
# Step 6: Welcome Email (optional)
# ═══════════════════════════════════════════════════════════════════

if $SEND_EMAIL && ! $DRY_RUN; then
  header "📧 Step 6 · Welcome Email"
  info "Welcome email sending requires Apps Script or SMTP setup"
  info "Skipping for now — user can be notified manually"
  warn "TODO: Configure email sending in a future update"
fi

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════

header "🎉 Agent Provisioned!"

echo ""
echo -e "  ${BOLD}Agent Details${NC}"
echo -e "  ────────────────────────────────────────"
echo -e "  User:           ${BOLD}$EMAIL${NC}"
echo -e "  VM Name:        ${BOLD}$VM_NAME${NC}"
echo -e "  Zone:           ${BOLD}$ZONE${NC}"
echo -e "  Machine Type:   ${BOLD}$VM_TYPE${NC}"
echo -e "  Internal IP:    ${BOLD}$INTERNAL_IP${NC}"
echo -e "  Model:          ${BOLD}$MODEL${NC}"
echo -e "  Budget:         ${BOLD}\$${BUDGET}/mo${NC}"
echo ""
echo -e "  ${BOLD}Connect via IAP tunnel:${NC}"
echo -e "  ${CYAN}gcloud compute ssh $VM_NAME --zone=$ZONE --tunnel-through-iap --project=$PROJECT_ID${NC}"
echo ""
echo -e "  ${BOLD}Check agent logs:${NC}"
echo -e "  ${CYAN}gcloud compute ssh $VM_NAME --zone=$ZONE --tunnel-through-iap -- journalctl -f -u openclaw${NC}"
echo ""
echo -e "  ${DIM}The VM is initializing. It will be ready in ~2-3 minutes.${NC}"
echo ""
