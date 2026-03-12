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

# ─── 2. Persistent directories ─────────────────────────────────────────────────
echo
info "Ensuring persistent directories exist for persistent storage..."
DATA_DIRS=(ollama openwebui qdrant workspace workspace/agent/jobs)
for DIR in "${DATA_DIRS[@]}"; do
    if [[ -d "$DIR" ]]; then
        info "Using existing ./$DIR"
    else
        info "Creating ./$DIR"
        mkdir -p "$DIR"
    fi
done

# ─── 3. Pull latest images ─────────────────────────────────────────────────────
echo
ask "Pull the latest Docker images before launching? [Y/n]"
read -r PULL_IMAGES
if [[ "$PULL_IMAGES" =~ ^[Nn]$ ]]; then
    info "Skipping docker compose pull."
else
    info "Pulling latest images..."
    if docker compose pull; then
        success "Pulled latest Compose images."
    else
        warn "docker compose pull failed (see above); proceeding with existing images."
    fi
fi

# ─── 4. Start services ───────────────────────────────────────────────────────
echo
info "Starting services (including interpreter sandbox and agent-runner)..."
docker compose up -d

# ─── 5. Wait for Ollama ──────────────────────────────────────────────────────
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

# ─── 5b. Wait for agent-runner ───────────────────────────────────────────────
echo
info "Waiting for agent-runner (OpenAPI tool server) to become ready..."
RETRIES=40
until docker exec agent-runner python -c \
          "import urllib.request; urllib.request.urlopen('http://localhost:9000/health')" \
          &>/dev/null 2>&1; do
    RETRIES=$((RETRIES - 1))
    if [[ $RETRIES -le 0 ]]; then
        warn "agent-runner did not become ready in time; it may still be building."
        warn "Check: docker compose logs agent-runner"
        break
    fi
    sleep 3
done
if docker exec agent-runner python -c \
       "import urllib.request; urllib.request.urlopen('http://localhost:9000/health')" \
       &>/dev/null 2>&1; then
    success "agent-runner is ready."
fi

# ─── 6. Verify runtimes and workflows ────────────────────────────────────────
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
    warn "Playwright service is not running; verify \`docker compose up playwright\`."
fi

info "Checking interpreter gateway..."
if docker compose exec interpreter python --version &>/dev/null 2>&1; then
    INTERP_PY=$(docker compose exec interpreter python --version 2>/dev/null)
    success "Interpreter container reports: $INTERP_PY"
else
    warn "Interpreter container not ready yet; check: docker compose logs interpreter"
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
        echo -e "${BOLD}┌──────────────────────────────────────────────────────┐${RESET}"
        echo -e "${BOLD}│          Admin Account Setup — Hold Point            │${RESET}"
        echo -e "${BOLD}└──────────────────────────────────────────────────────┘${RESET}"
        echo
        echo -e "  No admin account exists yet. Sign-up is currently ${RED}DISABLED${RESET} (secure default)."
        echo
        echo -e "  ${BOLD}Instructions:${RESET}"
        echo -e "    1. Open ${CYAN}http://127.0.0.1:3000${RESET} in your browser."
        echo -e "    2. Press ${BOLD}[any key]${RESET} below to ${GREEN}temporarily enable sign-up${RESET}."
        echo -e "    3. Create your admin account in the browser."
        echo -e "    4. Press ${BOLD}[x + Enter]${RESET} below to ${RED}re-disable sign-up${RESET} and secure the instance."
        echo
        ask "Press any key then Enter to temporarily enable sign-up  (or type 's' and Enter to skip):"
        read -r SIGNUP_KEY
        echo

        if [[ "$SIGNUP_KEY" != "s" && "$SIGNUP_KEY" != "S" ]]; then
            info "Enabling sign-up temporarily via Open WebUI config..."
            docker exec openwebui sqlite3 /app/backend/data/webui.db \
                "UPDATE config SET data = json_set(data, '$.ENABLE_SIGNUP', json('true'));" \
                2>/dev/null || true

            success "Sign-up is now ${GREEN}ENABLED${RESET}."
            echo
            echo -e "  ${BOLD}→ Go to ${CYAN}http://127.0.0.1:3000${RESET} and create your admin account now.${RESET}"
            echo
            ask "When done, press [x + Enter] to re-disable sign-up:"
            while true; do
                read -r CLOSE_KEY
                [[ "$CLOSE_KEY" == "x" || "$CLOSE_KEY" == "X" ]] && break
                echo -e "  Please type ${BOLD}x${RESET} and press Enter to confirm."
            done

            info "Re-disabling sign-up..."
            docker exec openwebui sqlite3 /app/backend/data/webui.db \
                "UPDATE config SET data = json_set(data, '$.ENABLE_SIGNUP', json('false'));" \
                2>/dev/null || true
            success "Sign-up is now ${RED}DISABLED${RESET}. Instance is secured."
        else
            info "Skipped admin setup. Enable sign-up manually if needed."
        fi
    else
        info "Open WebUI already has user accounts; skipping admin setup."
    fi
fi

# ─── 9. Summary ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Stack is up!${RESET}"
echo -e "  Open WebUI      → ${CYAN}http://127.0.0.1:3000${RESET}"
echo -e "  Ollama API      → internal (ollama:11434)"
echo -e "  Qdrant REST     → internal (qdrant:6333)"
echo -e "  Interpreter GW  → internal (open-interpreter:8888)"
echo -e "  Agent Runner    → internal (agent-runner:9000)"
echo
echo -e "  ${BOLD}Agent tool server${RESET} is pre-registered in Open WebUI."
echo -e "  To use it, click ${CYAN}➕${RESET} in the chat input area and toggle on"
echo -e "  the Agent Runner tools (hidden by default per user)."
echo
echo -e "  Job logs & artifacts: ${CYAN}./workspace/agent/jobs/<job_id>/${RESET}"
echo

MODELS_NOW=$(docker exec ollama ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
if [[ -n "$MODELS_NOW" ]]; then
    echo -e "  Downloaded models:"
    echo "$MODELS_NOW" | sed 's/^/    /'
else
    warn "No models downloaded yet. Run: docker exec ollama ollama pull <model>"
fi

echo -e "\n  To stop the stack: ${CYAN}docker compose down${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}\n"
