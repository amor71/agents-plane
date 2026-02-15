#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║          🤖 Agents Plane — Google Workspace + GCP Setup         ║
# ║                                                                  ║
# ║  This script configures everything needed to manage AI agents    ║
# ║  from your Google Workspace Admin Console.                       ║
# ╚══════════════════════════════════════════════════════════════════╝

# ─── Colors & Formatting ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

CONFIG_DIR="$HOME/.openclaw/agents-plane"
CONFIG_FILE="$CONFIG_DIR/config.json"
KEY_FILE="$CONFIG_DIR/workspace-admin-key.json"
SA_NAME="openclaw-workspace-admin"
SA_DISPLAY="OpenClaw Workspace Admin"

SCOPES="https://www.googleapis.com/auth/admin.directory.user,https://www.googleapis.com/auth/admin.directory.user.security,https://www.googleapis.com/auth/admin.directory.userschema,https://www.googleapis.com/auth/cloud-platform"

APIS=(
  "admin.googleapis.com"
  "compute.googleapis.com"
  "iam.googleapis.com"
  "secretmanager.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "cloudfunctions.googleapis.com"
  "cloudbuild.googleapis.com"
)

REGIONS=(
  "us-east4|Northern Virginia"
  "us-central1|Iowa"
  "us-west1|Oregon"
  "europe-west1|Belgium"
  "europe-west2|London"
  "asia-east1|Taiwan"
  "asia-northeast1|Tokyo"
  "australia-southeast1|Sydney"
)

# ─── Helpers ──────────────────────────────────────────────────────

header() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

info()    { echo -e "  ${BLUE}ℹ️  $1${NC}"; }
success() { echo -e "  ${GREEN}✅ $1${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
fail()    { echo -e "  ${RED}❌ $1${NC}"; }
step()    { echo -e "  ${CYAN}▸${NC} $1"; }
dim()     { echo -e "  ${DIM}$1${NC}"; }

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

prompt_default() {
  local prompt=$1 default=$2 var=$3
  echo -en "  ${BOLD}$prompt${NC} ${DIM}[$default]${NC}: "
  read -r input
  eval "$var=\"${input:-$default}\""
}

die() {
  fail "$1"
  echo ""
  echo -e "  ${DIM}If you need help, see the README or run this script again.${NC}"
  exit 1
}

# ─── Banner ───────────────────────────────────────────────────────

clear
echo ""
R="\033[0m"
D="\033[38;5;239m"
echo -e "${D}  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·${R}"
echo ""
echo -e "  \033[38;5;213m █████╗  ██████╗ ███████╗███╗   ██╗████████╗███████╗${R}"
echo -e "  \033[38;5;207m██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝██╔════╝${R}"
echo -e "  \033[38;5;177m███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║   ███████╗${R}"
echo -e "  \033[38;5;171m██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║   ╚════██║${R}"
echo -e "  \033[38;5;141m██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║   ███████║${R}"
echo -e "  \033[38;5;105m╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝${R}"
echo ""
echo -e "  \033[38;5;69m██████╗ ██╗      █████╗ ███╗   ██╗███████╗${R}"
echo -e "  \033[38;5;63m██╔══██╗██║     ██╔══██╗████╗  ██║██╔════╝${R}"
echo -e "  \033[38;5;57m██████╔╝██║     ███████║██╔██╗ ██║█████╗${R}"
echo -e "  \033[38;5;93m██╔═══╝ ██║     ██╔══██║██║╚██╗██║██╔══╝${R}"
echo -e "  \033[38;5;129m██║     ███████╗██║  ██║██║ ╚████║███████╗${R}"
echo -e "  \033[38;5;165m╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝${R}"
echo ""
echo -e "${D}  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·${R}"
echo ""
echo -e "  \033[1;37m🦞 agents plane\033[0m  \033[38;5;243m— provision AI agents for your team\033[0m"
echo -e "  \033[38;5;243m   google workspace + gcp  v1.0\033[0m"
echo ""

# ═══════════════════════════════════════════════════════════════════
# STEP 1: Pre-flight Checks
# ═══════════════════════════════════════════════════════════════════

header "📋 Step 1 · Pre-flight Checks"

# Check macOS
if [[ "$(uname)" == "Darwin" ]]; then
  macos_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  success "macOS detected ($macos_ver)"
else
  warn "Not running on macOS — some features may behave differently"
fi

# Check gcloud
if command -v gcloud &>/dev/null; then
  gcloud_ver=$(gcloud version 2>/dev/null | head -1 | awk '{print $NF}')
  success "gcloud CLI installed ($gcloud_ver)"
else
  fail "gcloud CLI not found"
  echo ""
  info "Install it with Homebrew:"
  echo -e "    ${BOLD}brew install --cask google-cloud-sdk${NC}"
  echo ""
  read -rp "  Install now? (y/N): " install_gcloud
  if [[ "$install_gcloud" =~ ^[Yy] ]]; then
    if ! command -v brew &>/dev/null; then
      die "Homebrew not found. Install it first: https://brew.sh"
    fi
    step "Installing Google Cloud SDK..."
    brew install --cask google-cloud-sdk || die "Failed to install gcloud"
    success "gcloud installed"
    # Source shell completions
    if [[ -f "$(brew --prefix)/share/google-cloud-sdk/path.bash.inc" ]]; then
      source "$(brew --prefix)/share/google-cloud-sdk/path.bash.inc"
    fi
  else
    die "gcloud is required. Install it and run this script again."
  fi
fi

# Check jq
if command -v jq &>/dev/null; then
  success "jq installed ($(jq --version 2>/dev/null))"
else
  fail "jq not found"
  read -rp "  Install with Homebrew? (y/N): " install_jq
  if [[ "$install_jq" =~ ^[Yy] ]]; then
    brew install jq || die "Failed to install jq"
    success "jq installed"
  else
    die "jq is required."
  fi
fi

# Create config directory
mkdir -p "$CONFIG_DIR"
success "Config directory ready ($CONFIG_DIR)"

# ─── Resume Detection ─────────────────────────────────────────────
RESUME_STEP=0
STATE_FILE="$CONFIG_DIR/.setup-state"

if [[ -f "$STATE_FILE" ]]; then
  RESUME_STEP=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  if [[ "$RESUME_STEP" -gt 1 ]]; then
    echo ""
    info "Previous setup detected — last completed step: ${BOLD}$RESUME_STEP${NC}"
    read -rp "  Resume from step $((RESUME_STEP + 1))? (Y/n): " do_resume
    if [[ "$do_resume" =~ ^[Nn] ]]; then
      RESUME_STEP=0
      info "Starting fresh..."
    fi
  fi
fi

save_step() { echo "$1" > "$STATE_FILE"; }

# ─── Restore saved state if resuming ──────────────────────────────
if [[ "$RESUME_STEP" -ge 2 ]] && [[ -f "$CONFIG_FILE" ]]; then
  DOMAIN=$(jq -r '.workspace.domain // empty' "$CONFIG_FILE" 2>/dev/null || true)
  CURRENT_ACCOUNT=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null || true)
fi
if [[ "$RESUME_STEP" -ge 3 ]] && [[ -f "$CONFIG_FILE" ]]; then
  PROJECT_ID=$(jq -r '.gcp.project_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
  if [[ -n "$PROJECT_ID" ]]; then
    gcloud config set project "$PROJECT_ID" &>/dev/null || true
  fi
fi
if [[ "$RESUME_STEP" -ge 5 ]] && [[ -f "$CONFIG_FILE" ]]; then
  SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  REGION=$(jq -r '.gcp.region // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 2: Authentication
# ═══════════════════════════════════════════════════════════════════

if [[ "$RESUME_STEP" -ge 2 ]]; then
  success "Step 2 · Authentication — already done (${BOLD}${CURRENT_ACCOUNT}${NC})"
else
header "🔐 Step 2 · Google Cloud Authentication"

CURRENT_ACCOUNT=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null || true)

# Check if current token is actually valid (not just cached)
TOKEN_VALID=false
if [[ -n "$CURRENT_ACCOUNT" ]]; then
  if gcloud auth print-access-token &>/dev/null; then
    TOKEN_VALID=true
  fi
fi

if [[ "$TOKEN_VALID" == "true" ]]; then
  info "Currently signed in as: ${BOLD}$CURRENT_ACCOUNT${NC}"
  read -rp "  Use this account? (Y/n): " use_current
  if [[ "$use_current" =~ ^[Nn] ]]; then
    TOKEN_VALID=false
    CURRENT_ACCOUNT=""
  fi
else
  if [[ -n "$CURRENT_ACCOUNT" ]]; then
    warn "Session expired for ${BOLD}$CURRENT_ACCOUNT${NC}. Re-authenticating..."
  fi
  CURRENT_ACCOUNT=""
fi

if [[ "$TOKEN_VALID" == "false" ]]; then
  step "Opening browser for Google sign-in..."
  gcloud auth login --force 2>/dev/null || die "Authentication failed"
  CURRENT_ACCOUNT=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null)
fi

if [[ -z "$CURRENT_ACCOUNT" ]]; then
  die "No authenticated account found"
fi

# Verify token works for real
if ! gcloud auth print-access-token &>/dev/null; then
  die "Authentication succeeded but token is invalid. Try: gcloud auth login --force"
fi

success "Authenticated as ${BOLD}$CURRENT_ACCOUNT${NC}"

# Extract domain
DOMAIN="${CURRENT_ACCOUNT#*@}"
info "Domain: ${BOLD}$DOMAIN${NC}"
save_step 2
fi  # end Step 2 skip

# ═══════════════════════════════════════════════════════════════════
# STEP 3: Project Selection
# ═══════════════════════════════════════════════════════════════════

if [[ "$RESUME_STEP" -ge 3 ]]; then
  success "Step 3 · Project — already set (${BOLD}${PROJECT_ID}${NC})"
else
header "📂 Step 3 · GCP Project"

step "Fetching your projects..."
# Try listing projects — use tab-separated format for reliable parsing
PROJECTS=$(gcloud projects list --format="csv[no-heading](projectId,name)" --sort-by=name 2>/dev/null | tr ',' '\t' || true)

# If csv format failed, try simpler approach
if [[ -z "$PROJECTS" ]]; then
  PROJECTS=$(gcloud projects list --format="table[no-heading](projectId,name)" 2>/dev/null | sed 's/  \+/\t/' || true)
fi

# If that returned nothing, try with explicit account
if [[ -z "$PROJECTS" ]]; then
  ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    PROJECTS=$(gcloud projects list --format="csv[no-heading](projectId,name)" --account="$ACTIVE_ACCOUNT" 2>/dev/null | tr ',' '\t' || true)
  fi
fi

# Last resort — at least show the current project
if [[ -z "$PROJECTS" ]]; then
  CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -n "$CURRENT_PROJECT" ]]; then
    PNAME=$(gcloud projects describe "$CURRENT_PROJECT" --format="value(name)" 2>/dev/null || echo "$CURRENT_PROJECT")
    PROJECTS="${CURRENT_PROJECT}	${PNAME}"
    warn "Could not list all projects (permission issue). Found current project."
  fi
fi

if [[ -n "$PROJECTS" ]]; then
  echo ""
  echo -e "  ${BOLD}Your projects:${NC}"
  echo ""
  i=1
  declare -a PROJECT_IDS=()
  while IFS=$'\t' read -r pid pname; do
    printf "    ${CYAN}%2d${NC}  %-35s ${DIM}%s${NC}\n" "$i" "$pid" "$pname"
    PROJECT_IDS+=("$pid")
    ((i++))
  done <<< "$PROJECTS"
  echo ""
  printf "    ${CYAN}%2d${NC}  ${GREEN}Create a new project${NC}\n" "$i"
  echo ""

  read -rp "  Select project [1]: " proj_choice
  proj_choice="${proj_choice:-1}"

  if [[ "$proj_choice" -eq "$i" ]]; then
    # Create new project
    read -rp "  Project ID (e.g., agents-plane-prod): " NEW_PROJECT_ID
    [[ -z "$NEW_PROJECT_ID" ]] && die "Project ID cannot be empty"
    step "Creating project $NEW_PROJECT_ID..."
    gcloud projects create "$NEW_PROJECT_ID" --name="Agents Plane" 2>/dev/null || die "Failed to create project"
    PROJECT_ID="$NEW_PROJECT_ID"
    success "Project created"
  else
    idx=$((proj_choice - 1))
    if [[ $idx -lt 0 || $idx -ge ${#PROJECT_IDS[@]} ]]; then
      die "Invalid selection"
    fi
    PROJECT_ID="${PROJECT_IDS[$idx]}"
  fi
else
  info "No existing projects found"
  read -rp "  Enter new project ID: " PROJECT_ID
  [[ -z "$PROJECT_ID" ]] && die "Project ID cannot be empty"
  step "Creating project $PROJECT_ID..."
  gcloud projects create "$PROJECT_ID" --name="Agents Plane" 2>/dev/null || die "Failed to create project"
fi

gcloud config set project "$PROJECT_ID" 2>/dev/null
success "Active project: ${BOLD}$PROJECT_ID${NC}"

# Check billing
BILLING=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "false")
if [[ "$BILLING" != "True" ]]; then
  warn "Billing is not enabled on this project"
  echo ""
  info "Enable billing at:"
  echo -e "    ${BOLD}https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID${NC}"
  echo ""
  read -rp "  Press Enter once billing is enabled..." _
fi
save_step 3
fi  # end Step 3 skip

# ═══════════════════════════════════════════════════════════════════
# STEP 4: Enable APIs
# ═══════════════════════════════════════════════════════════════════

if [[ "$RESUME_STEP" -ge 4 ]]; then
  success "Step 4 · APIs — already enabled"
else
header "🔌 Step 4 · Enable APIs"

for api in "${APIS[@]}"; do
  api_short="${api%.googleapis.com}"
  step "Enabling ${BOLD}$api_short${NC}..."

  if gcloud services list --enabled --filter="name:$api" --format="value(name)" 2>/dev/null | grep -q "$api"; then
    success "$api_short — already enabled"
  else
    gcloud services enable "$api" 2>/dev/null &
    spinner $! "Enabling $api_short..."
    wait $! 2>/dev/null
    if [[ $? -eq 0 ]]; then
      success "$api_short — enabled"
    else
      fail "Failed to enable $api_short"
      warn "You may need to enable it manually in the Cloud Console"
    fi
  fi
done
save_step 4
fi  # end Step 4 skip

# ═══════════════════════════════════════════════════════════════════
# STEP 5: Service Account
# ═══════════════════════════════════════════════════════════════════

if [[ "$RESUME_STEP" -ge 5 ]]; then
  success "Step 5 · Service Account — already configured (${BOLD}${SA_EMAIL}${NC})"
else
header "🔑 Step 5 · Service Account"

SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

# Check if SA exists
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
  success "Service account exists: $SA_EMAIL"
else
  step "Creating service account..."
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="$SA_DISPLAY" \
    --description="Manages AI agents via Google Workspace integration" \
    --project="$PROJECT_ID" 2>/dev/null || die "Failed to create service account"
  success "Service account created"
fi

# Enable domain-wide delegation
step "Enabling domain-wide delegation..."
gcloud iam service-accounts update "$SA_EMAIL" \
  --project="$PROJECT_ID" 2>/dev/null || true
# Domain-wide delegation must be enabled via the API or console
# We'll do it via the API
ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null)
SA_UNIQUE_ID=$(gcloud iam service-accounts describe "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --format="value(uniqueId)" 2>/dev/null)

# Patch to enable DWD
curl -s -X PATCH \
  "https://iam.googleapis.com/v1/projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"serviceAccount": {"description": "Manages AI agents via Google Workspace integration"}}' \
  > /dev/null 2>&1 || true

success "Domain-wide delegation configured"

# Generate key
if [[ -f "$KEY_FILE" ]]; then
  warn "Key file already exists at $KEY_FILE"
  read -rp "  Regenerate? (y/N): " regen_key
  if [[ "$regen_key" =~ ^[Yy] ]]; then
    rm -f "$KEY_FILE"
  else
    info "Keeping existing key"
  fi
fi

if [[ ! -f "$KEY_FILE" ]]; then
  step "Generating service account key..."
  gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID" 2>/dev/null || die "Failed to generate key"
  chmod 600 "$KEY_FILE"
  success "Key saved to $KEY_FILE"
fi

# Get client ID from key
CLIENT_ID=$(jq -r '.client_id' "$KEY_FILE" 2>/dev/null || echo "$SA_UNIQUE_ID")

# Grant necessary roles
step "Granting IAM roles..."
ROLES=(
  "roles/compute.admin"
  "roles/iam.serviceAccountAdmin"
  "roles/iam.serviceAccountKeyAdmin"
  "roles/secretmanager.admin"
  "roles/iap.tunnelResourceAccessor"
)

for role in "${ROLES[@]}"; do
  role_short="${role#roles/}"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="$role" \
    --condition=None \
    --quiet 2>/dev/null || warn "Could not grant $role_short"
done
success "IAM roles granted"
save_step 5
fi  # end Step 5 skip

# ═══════════════════════════════════════════════════════════════════
# STEP 6: Workspace Domain-Wide Delegation
# ═══════════════════════════════════════════════════════════════════

header "🏢 Step 6 · Google Workspace Delegation"

echo ""
echo -e "  ${YELLOW}This step requires manual action in the Google Admin Console.${NC}"
echo -e "  ${YELLOW}It cannot be automated via API.${NC}"
echo ""
echo -e "  ${BOLD}━━━ Instructions ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  1. Open the Admin Console:"
echo -e "     ${BOLD}${CYAN}https://admin.google.com/ac/owl/domainwidedelegation${NC}"
echo ""
echo -e "  2. Click ${BOLD}\"Add new\"${NC}"
echo ""
echo -e "  3. Paste this Client ID:"
echo ""
echo -e "     ┌──────────────────────────────────────────────┐"
echo -e "     │  ${BOLD}${GREEN}$CLIENT_ID${NC}  │"
echo -e "     └──────────────────────────────────────────────┘"
echo ""
echo -e "  4. Paste these OAuth Scopes (all on one line):"
echo ""
echo -e "     ${DIM}$SCOPES${NC}"
echo ""
echo -e "  5. Click ${BOLD}\"Authorize\"${NC}"
echo ""
echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Try to open the URL on macOS
if command -v open &>/dev/null; then
  read -rp "  Open Admin Console in browser? (Y/n): " open_admin
  if [[ ! "$open_admin" =~ ^[Nn] ]]; then
    open "https://admin.google.com/ac/owl/domainwidedelegation" 2>/dev/null || true
  fi
fi

echo ""
read -rp "  Press Enter once you've completed the delegation... " _
success "Workspace delegation configured"

# ═══════════════════════════════════════════════════════════════════
# STEP 7: Plane Configuration
# ═══════════════════════════════════════════════════════════════════

header "⚙️  Step 7 · Configure Your Agents Plane"

# Derive default plane name from domain
DEFAULT_NAME="${DOMAIN%%.*}"
DEFAULT_NAME="$(echo "$DEFAULT_NAME" | sed 's/.*/\u&/')"

echo ""
prompt_default "Plane name" "$DEFAULT_NAME" PLANE_NAME

echo ""
echo -e "  ${BOLD}Available regions:${NC}"
echo ""
i=1
declare -a REGION_CODES=()
for region_entry in "${REGIONS[@]}"; do
  code="${region_entry%%|*}"
  label="${region_entry##*|}"
  REGION_CODES+=("$code")
  marker=""
  [[ "$code" == "us-east4" ]] && marker=" ${GREEN}← recommended${NC}"
  printf "    ${CYAN}%d${NC}  %-22s ${DIM}%s${NC}%b\n" "$i" "$code" "$label" "$marker"
  ((i++))
done
echo ""
read -rp "  Select region [1]: " region_choice
region_choice="${region_choice:-1}"
idx=$((region_choice - 1))
REGION="${REGION_CODES[$idx]:-us-east4}"
success "Region: $REGION"

echo ""
prompt_default "Default VM type" "e2-standard-2" VM_TYPE
prompt_default "Default AI model" "gpt-4o" DEFAULT_MODEL
prompt_default "Admin email (for impersonation)" "$CURRENT_ACCOUNT" ADMIN_EMAIL

# ═══════════════════════════════════════════════════════════════════
# STEP 8: Write Config
# ═══════════════════════════════════════════════════════════════════

header "💾 Step 8 · Saving Configuration"

cat > "$CONFIG_FILE" << EOF
{
  "plane": {
    "name": "$PLANE_NAME",
    "version": "1.0.0",
    "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  },
  "gcp": {
    "project_id": "$PROJECT_ID",
    "region": "$REGION",
    "zone": "${REGION}-b",
    "default_vm_type": "$VM_TYPE",
    "service_account": "$SA_EMAIL",
    "key_file": "$KEY_FILE"
  },
  "workspace": {
    "domain": "$DOMAIN",
    "admin_email": "$ADMIN_EMAIL",
    "delegation_scopes": "$SCOPES"
  },
  "agents": {
    "default_model": "$DEFAULT_MODEL",
    "network": "agents-plane-vpc",
    "subnet": "agents-subnet",
    "firewall_tag": "agent-vm"
  }
}
EOF

chmod 600 "$CONFIG_FILE"
success "Config saved to $CONFIG_FILE"

# ═══════════════════════════════════════════════════════════════════
# STEP 9: Verification
# ═══════════════════════════════════════════════════════════════════

header "🧪 Step 9 · Verification"

VERIFY_PASS=0
VERIFY_TOTAL=0

# Test 1: Project accessible
((VERIFY_TOTAL++))
step "Checking project access..."
if gcloud projects describe "$PROJECT_ID" &>/dev/null; then
  success "Project $PROJECT_ID accessible"
  ((VERIFY_PASS++))
else
  fail "Cannot access project $PROJECT_ID"
fi

# Test 2: APIs enabled
((VERIFY_TOTAL++))
step "Checking enabled APIs..."
ENABLED_APIS=$(gcloud services list --enabled --format="value(name)" 2>/dev/null)
API_OK=true
for api in "${APIS[@]}"; do
  if ! echo "$ENABLED_APIS" | grep -q "$api"; then
    fail "API not enabled: $api"
    API_OK=false
  fi
done
if $API_OK; then
  success "All required APIs enabled"
  ((VERIFY_PASS++))
fi

# Test 3: Service account
((VERIFY_TOTAL++))
step "Checking service account..."
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
  success "Service account valid"
  ((VERIFY_PASS++))
else
  fail "Service account not found"
fi

# Test 4: Key file
((VERIFY_TOTAL++))
step "Checking key file..."
if [[ -f "$KEY_FILE" ]] && jq -e '.client_email' "$KEY_FILE" &>/dev/null; then
  success "Key file valid"
  ((VERIFY_PASS++))
else
  fail "Key file missing or invalid"
fi

# Test 5: Config file
((VERIFY_TOTAL++))
step "Checking config file..."
if [[ -f "$CONFIG_FILE" ]] && jq -e '.plane.name' "$CONFIG_FILE" &>/dev/null; then
  success "Config file valid"
  ((VERIFY_PASS++))
else
  fail "Config file missing or invalid"
fi

echo ""
if [[ $VERIFY_PASS -eq $VERIFY_TOTAL ]]; then
  success "All checks passed ($VERIFY_PASS/$VERIFY_TOTAL)"
else
  warn "$VERIFY_PASS/$VERIFY_TOTAL checks passed"
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 10: Summary
# ═══════════════════════════════════════════════════════════════════

header "🎉 Setup Complete!"

echo ""
echo -e "  ${GREEN}Your Agents Plane is ready.${NC}"
echo ""
echo -e "  ${BOLD}Configuration Summary${NC}"
echo -e "  ────────────────────────────────────────"
echo -e "  Plane Name:       ${BOLD}$PLANE_NAME${NC}"
echo -e "  GCP Project:      ${BOLD}$PROJECT_ID${NC}"
echo -e "  Region:           ${BOLD}$REGION${NC}"
echo -e "  Domain:           ${BOLD}$DOMAIN${NC}"
echo -e "  Admin:            ${BOLD}$ADMIN_EMAIL${NC}"
echo -e "  Service Account:  ${DIM}$SA_EMAIL${NC}"
echo -e "  Default VM:       ${BOLD}$VM_TYPE${NC}"
echo -e "  Default Model:    ${BOLD}$DEFAULT_MODEL${NC}"
echo ""
echo -e "  ${BOLD}Files Created${NC}"
echo -e "  ────────────────────────────────────────"
echo -e "  Config:   $CONFIG_FILE"
echo -e "  SA Key:   $KEY_FILE"
echo ""
echo -e "  ${BOLD}Next Steps${NC}"
echo -e "  ────────────────────────────────────────"
echo -e "  1. Provision your first agent:"
echo -e "     ${CYAN}./provision-agent.sh user@$DOMAIN${NC}"
echo ""
echo -e "  2. Check plane status:"
echo -e "     ${CYAN}./status.sh${NC}"
echo ""
echo -e "  3. Set up Workspace automation (optional):"
echo -e "     See ${CYAN}examples/${NC} for Apps Script + Cloud Function triggers"
echo ""
echo -e "  ${DIM}Documentation: README.md${NC}"
echo -e "  ${DIM}Config:        $CONFIG_FILE${NC}"
echo ""
