# AI Stack

This repository is a Docker Compose stack that wires together:

1. **Ollama** for on‑prem LLM inference (GPU-backed)
2. **Open WebUI** for a browser-based chat interface
3. **Qdrant** as the vector store
4. **Playwright** and **Open Interpreter** for optional agent automation

The goal is a single host that can run everything locally while keeping the services isolated behind an internal bridge network (`ai_internal`).

## Getting the code

Clone your fork of this repository and enter the directory:

```bash
git clone https://github.com/<your-username>/ai-stack.git
cd ai-stack
```

## Prerequisites

Install the following before running the stack.

### Docker Engine + Compose plugin

Follow the official install guide for your OS:
<https://docs.docker.com/engine/install/>

After installing, verify both are available:

```bash
docker --version
docker compose version
```

Make sure your user can run Docker without `sudo` (add yourself to the `docker` group and re-login if needed):

```bash
sudo usermod -aG docker $USER
# then log out and back in, or run: newgrp docker
```

### NVIDIA Container Toolkit (GPU only)

Required for Ollama to use the GPU. Skip if you are running CPU-only.

Follow the official guide:
<https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html>

After installing, restart Docker and verify the runtime is registered:

```bash
sudo systemctl restart docker
docker info | grep -i nvidia   # should list "nvidia" under Runtimes
nvidia-smi                     # should show your GPU and driver version
```

## First-time setup

Make the setup script executable (only needed once after a fresh clone), then run it:

```bash
chmod +x setup.sh
./setup.sh
```

The script performs the remaining deployment steps:

1. Validates Docker, Compose, and (optionally) the NVIDIA runtime
2. Ensures the persistent bind-mount folders (`ollama`, `openwebui`, `qdrant`, `workspace`) exist
3. Prompts whether to pull the latest images before starting the stack
4. Starts the core services (and, optionally, the `interpreter` profile)
5. Waits for Ollama, shows existing models, and suggests VRAM-based model combinations for you to pull
6. Detects whether Open WebUI already has users; if not, it guides you through creating the first admin account
7. Summarizes the stack status and downloaded models

If you already know what you want to do and prefer not to use the script, you can replicate the above manually:

```bash
# Core services
docker compose pull
docker compose up -d

# Optional agent (builds the interpreter image locally first)
docker compose build interpreter
docker compose --profile agent up -d

docker exec ollama ollama pull <model>
docker exec ollama ollama list
# Interact with Open WebUI once http://127.0.0.1:3000 is ready
```

## Accessing the stack

- **Open WebUI** — `http://127.0.0.1:3000`. Signup is disabled by default, so create the admin account via the setup script or by posting to `/api/v1/auths/signup`.
- **Ollama API** — available internally at `http://ollama:11434`; use `docker exec ollama ...` for CLI operations.
- **Qdrant** — REST on `http://qdrant:6333`, gRPC on `:6334` (both internal).
- **Playwright** — runs idle unless you attach to the container; used by the `interpreter` agent.
- **Interpreter profile** — run `docker compose --profile agent up -d` (the script can prompt to enable it). The repo-mounted `workspace` directory maps to `/workspace` inside that container.

## Playwright MCP server

The `playwright` service is intended to back MCP-style web interactions (e.g., automated QA or agent workflows that need a browser). It uses `mcr.microsoft.com/playwright:v1.55.0-jammy`, has 1 GB of shared memory, and is kept running idle so other services (like `interpreter`) can connect.

To exercise Playwright manually:

```bash
docker compose up -d playwright
docker compose exec playwright npx playwright test   # add your own tests inside ./workspace if desired
```

For reproducible agent demos, the `interpreter` container depends on `playwright`, so running `./setup.sh` (which starts all services) already brings the MCP server online.

## Recommended models by GPU VRAM

| GPU VRAM | Suggested models |
| --- | --- |
| 6 GB | `llama3-small`, `gemma2-medium` |
| 8 GB | `llama3-medium`, `mistral-7b-instruct` |
| 12 GB | `llama3-large`, `gemma3-mini` |
| 16 GB | `llama3-13b`, `gemma3` |
| 24 GB | `llama3-70b`, `gemma3-large` |

The setup script highlights the row that best fits the detected VRAM so you can copy those names when it prompts for model downloads.

## Managing the stack

- Start core services: `docker compose up -d`
- Start the optional agent: `docker compose --profile agent up -d`
- Check status/logs: `docker compose logs -f <service>`
- Restart a service: `docker compose restart <service>`
- Stop and remove everything: `docker compose down`

Use `docker exec ollama ollama list` to view downloaded models and `docker exec ollama ollama pull <model>` to install more.

## Verifying runtimes and workflows

After the stack starts (either through `./setup.sh` or manual compose commands), verify each runtime with:

```bash
docker compose ps
docker compose exec playwright npx playwright --version
docker compose exec interpreter python --version  # only if the agent profile is running
curl -sf http://127.0.0.1:3000/health
docker exec ollama ollama list
```

The setup script already performs these checks for you and prints the summarized status, but running them manually can help diagnose issues (e.g., Playwright build, interpreter readiness, Open WebUI health, or Ollama model availability) before handing the stack to another workflow.

## Persistent data and conventions

- The directories `./ollama`, `./openwebui`, `./qdrant`, and `./workspace` are bind-mounted into the corresponding containers for persistence. Do not commit their contents.
- All containers drop capabilities (`cap_drop: ALL`), disable signup for Open WebUI, and run with `no-new-privileges`.
- The `workspace` directory is the shared volume used by Open Interpreter; treat it as the working area for scripted agents.

## Troubleshooting

- If the stack fails to start, inspect logs (`docker compose logs <service>`). Ensure the NVIDIA toolkit is installed if you're on GPU hardware.
- The setup script waits for `ollama list` to succeed; if it times out, rerun `./setup.sh` after checking hardware resources.
- For admin creation issues, use `curl -X POST http://127.0.0.1:3000/api/v1/auths/signup` with the same JSON payload the script uses.
