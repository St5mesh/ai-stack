#!/usr/bin/env bash
set -euo pipefail

# ─── colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[•]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
die()     { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
ask()     { echo -e "${BOLD}${CYAN}[?]${RESET} $*"; }

cd "$(dirname "$0")"
GPU_VRAM_MI=""

echo -e "\n${BOLD}╔══════════════════════════════════╗"
echo -e "║      AI Stack Setup              ║"
echo -e "╚══════════════════════════════════╝${RESET}\n"

# ─── 1. Prerequisites ────────────────────────────────────────────────────────
info "Checking prerequisites..."

command -v docker &>/dev/null          || die "docker is not installed."
docker compose version &>/dev/null     || die "'docker compose' plugin not found."
docker info &>/dev/null 2>&1           || die "Docker daemon is not running or not accessible."
success "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

# NVIDIA runtime
if docker info 2>/dev/null | grep -q "nvidia"; then
    GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    GPU_VRAM_MI=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || true)
    if [[ -n "$GPU_VRAM_MI" ]]; then
        success "NVIDIA runtime available ($GPU, ${GPU_VRAM_MI} MiB VRAM)"
    else
        success "NVIDIA runtime available ($GPU)"
    fi
else
    warn "NVIDIA runtime not detected. Ollama will run on CPU only."
    warn "If you have a GPU, install nvidia-container-toolkit and restart Docker."
    echo
    ask "Continue without GPU support? [y/N]"
    read -r REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
fi

# ─── 2. Agent profile ────────────────────────────────────────────────────────
echo
ask "Start the optional open-interpreter agent (profile: agent)? [y/N]"
read -r START_AGENT
COMPOSE_PROFILES=""
if [[ "$START_AGENT" =~ ^[Yy]$ ]]; then
    COMPOSE_PROFILES="--profile agent"
    info "Agent profile enabled."
fi

# ─── 3. Persistent directories ─────────────────────────────────────────────────
echo
info "Ensuring persistent directories exist for persistent storage..."
DATA_DIRS=(ollama openwebui qdrant workspace)
for DIR in "${DATA_DIRS[@]}"; do
    if [[ -d "$DIR" ]]; then
        info "Using existing ./$DIR"
    else
        info "Creating ./$DIR"
        mkdir -p "$DIR"
    fi
done

# ─── 4. Pull latest images ─────────────────────────────────────────────────────
echo
ask "Pull the latest Docker images before launching? [Y/n]"
read -r PULL_IMAGES
if [[ "$PULL_IMAGES" =~ ^[Nn]$ ]]; then
    info "Skipping docker compose pull."
else
    info "Pulling latest images..."
    if docker compose $COMPOSE_PROFILES pull; then
        success "Pulled latest Compose images."
    else
        warn "docker compose pull failed (see above); proceeding with existing images."
    fi
fi

# ─── 5. Start services ───────────────────────────────────────────────────────
echo
info "Starting core services..."
# shellcheck disable=SC2086
docker compose $COMPOSE_PROFILES up -d

# ─── 6. Wait for Ollama ──────────────────────────────────────────────────────
echo
info "Waiting for Ollama to become ready..."
RETRIES=30
until docker exec ollama ollama list &>/dev/null 2>&1; do
    RETRIES=$((RETRIES - 1))
    if [[ $RETRIES -le 0 ]]; then
        die "Ollama did not become ready in time. Check: docker compose logs ollama"
    fi
    sleep 2
done
success "Ollama is ready."

# ─── 7. Verify runtimes and workflows ────────────────────────────────────────
echo
info "Verifying service status and runtimes..."
docker compose ps

if docker compose ps | grep -q "^ *playwright"; then
    info "Checking Playwright installation..."
    if PLAYWRIGHT_VERSION=$(docker compose exec playwright npx playwright --version 2>/dev/null); then
        success "Playwright reports: $PLAYWRIGHT_VERSION"
    else
        warn "Playwright container is running but version check failed."
    fi
else
    warn "Playwright service is not running; verify `docker compose up playwright`."
fi

if [[ "$COMPOSE_PROFILES" =~ agent ]]; then
    info "Checking interpreter agent runtime..."
    if INTERPRETER_VERSION=$(docker compose exec interpreter python --version 2>/dev/null); then
        success "Interpreter container reports: $INTERPRETER_VERSION"
    else
        warn "Interpreter profile is enabled but python version check failed."
    fi
fi

# ─── 7. Pull models ──────────────────────────────────────────────────────────
echo
declare -A RECOMMENDED_MODELS=(
    [6]="llama3-small, gemma2-medium"
    [8]="llama3-medium, mistral-7b-instruct"
    [12]="llama3-large, gemma3-mini"
    [16]="llama3-13b, gemma3"
    [24]="llama3-70b, gemma3-large"
)
RECOMMENDED_ORDER=(6 8 12 16 24)
HIGHLIGHT_GB=""
if [[ -n "$GPU_VRAM_MI" ]]; then
    info "Detected GPU VRAM: ${GPU_VRAM_MI} MiB (~$(( (GPU_VRAM_MI + 512) / 1024 )) GB)"
    for GB in "${RECOMMENDED_ORDER[@]}"; do
        if (( GPU_VRAM_MI >= GB * 1024 )); then
            HIGHLIGHT_GB="$GB"
        fi
    done
fi
info "Recommended model sets by GPU VRAM:"
for GB in "${RECOMMENDED_ORDER[@]}"; do
    LINE="${GB}GB → ${RECOMMENDED_MODELS[$GB]}"
    if [[ -n "$HIGHLIGHT_GB" && "$GB" -eq "$HIGHLIGHT_GB" ]]; then
        echo -e "    ${BOLD}${LINE}${RESET} ${CYAN}(best match for this host)${RESET}"
    else
        echo "    $LINE"
    fi
done
echo
EXISTING=$(docker exec ollama ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' || true)

if [[ -n "$EXISTING" ]]; then
    info "Already downloaded models:"
    echo "$EXISTING" | sed 's/^/    /'
    echo
fi

while true; do
    ask "Enter a model name to pull (e.g. llama3, mistral, gemma3), or press Enter to skip:"
    read -r MODEL
    [[ -z "$MODEL" ]] && break

    info "Pulling '$MODEL'..."
    if docker exec -it ollama ollama pull "$MODEL"; then
        success "Pulled '$MODEL'."
    else
        warn "Failed to pull '$MODEL'. Check the model name at https://ollama.com/library"
    fi

    ask "Pull another model? [y/N]"
    read -r ANOTHER
    [[ "$ANOTHER" =~ ^[Yy]$ ]] || break
done

# ─── 8. Configure Open WebUI admin account ───────────────────────────────────
echo
info "Checking Open WebUI..."
RETRIES=20
until curl -sf http://127.0.0.1:3000/health | grep -q '"status":"ok"' 2>/dev/null; do
    RETRIES=$((RETRIES - 1))
    if [[ $RETRIES -le 0 ]]; then
        warn "Open WebUI did not become ready in time; skipping admin setup."
        break
    fi
    sleep 2
done

if curl -sf http://127.0.0.1:3000/health | grep -q '"status":"ok"' 2>/dev/null; then
    success "Open WebUI is ready at http://127.0.0.1:3000"

    # Check whether any admin account already exists
    USER_COUNT=$(curl -sf http://127.0.0.1:3000/api/v1/auths/ 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "")

    if [[ "$USER_COUNT" == "0" || -z "$USER_COUNT" ]]; then
        echo
        ask "Create an initial admin account for Open WebUI? [Y/n]"
        read -r CREATE_ADMIN
        if [[ ! "$CREATE_ADMIN" =~ ^[Nn]$ ]]; then
            ask "  Admin name:"
            read -r ADMIN_NAME
            ask "  Admin email:"
            read -r ADMIN_EMAIL
            ask "  Admin password:"
            read -rs ADMIN_PASS
            echo

            RESULT=$(curl -sf -X POST http://127.0.0.1:3000/api/v1/auths/signup \
                -H "Content-Type: application/json" \
                -d "{\"name\":\"$ADMIN_NAME\",\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" \
                2>/dev/null || true)

            if echo "$RESULT" | grep -q '"token"'; then
                success "Admin account created for '$ADMIN_EMAIL'."
            else
                warn "Account creation may have failed. Try signing up at http://127.0.0.1:3000"
                warn "Response: $RESULT"
            fi
        fi
    else
        info "Open WebUI already has user accounts; skipping admin setup."
    fi
fi

# ─── 9. Summary ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══════════════════════════════════${RESET}"
echo -e "${BOLD}  Stack is up!${RESET}"
echo -e "  Open WebUI   → ${CYAN}http://127.0.0.1:3000${RESET}"
echo -e "  Ollama API   → internal (ollama:11434)"
echo -e "  Qdrant REST  → internal (qdrant:6333)"
echo

MODELS_NOW=$(docker exec ollama ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
if [[ -n "$MODELS_NOW" ]]; then
    echo -e "  Downloaded models:"
    echo "$MODELS_NOW" | sed 's/^/    /'
else
    warn "No models downloaded yet. Run: docker exec ollama ollama pull <model>"
fi

echo -e "\n  To stop the stack: ${CYAN}docker compose down${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════${RESET}\n"
