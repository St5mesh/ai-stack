# AI Stack

This repository is a Docker Compose stack that wires together:

1. **Ollama** for on‑prem LLM inference (GPU-backed)
2. **Open WebUI** for a browser-based chat interface
3. **Qdrant** as the vector store
4. **Playwright** for headless browser automation (agent workflows)
5. **Open Interpreter** sandbox — a persistent Python + browser environment for running agent jobs
6. **Agent Runner** — an OpenAPI tool server that lets Open WebUI dispatch autonomous agent tasks

The goal is a single host that can run everything locally while keeping the services isolated behind an internal bridge network (`ai_internal`).

## Agent system overview

The agent system consists of two services that start automatically with `docker compose up -d`:

```
Open WebUI  ──tool call──▶  agent-runner  ──HTTP──▶  interpreter gateway
                              (port 9000)               (port 8888, internal)
                                 │
                           reads workspace
                           ./workspace/agent/jobs/
```

| Component | Description |
| --- | --- |
| **interpreter** | Persistent Python 3.11 container running a FastAPI HTTP gateway. Receives job requests, spawns Open Interpreter as an isolated subprocess per job, and stores all output in the workspace. |
| **agent-runner** | Lightweight FastAPI service that exposes an OpenAPI spec (`/openapi.json`). Open WebUI is pre-configured to use it as a Global Tool Server via `TOOL_SERVER_CONNECTIONS`. |

### Enabling agent tools in Open WebUI

The agent tool server is registered as a **Global Tool Server** in Open WebUI.  Global tools are **hidden by default** and must be activated per user/chat:

1. Open a new chat in Open WebUI (`http://127.0.0.1:3000`).
2. Click the **➕** button in the chat input area.
3. Toggle on the **Agent Runner** tools (e.g. *Create an autonomous agent job*).
4. The LLM can now create and monitor jobs in the persistent sandbox.

This opt-in behaviour is intentional — the agent tools are powerful and should not run on every LLM call.

### Workspace and job artifacts

All job data lives under `./workspace/agent/jobs/<job_id>/`:

```
./workspace/agent/jobs/
└── <job_id>/
    ├── task.json       ← job metadata (status, created_at, error)
    ├── run.py          ← auto-generated runner script for the job
    ├── stdout.log      ← full interpreter output / execution log
    └── output.json     ← structured result returned by Open Interpreter
    └── <other files>   ← any files the agent created during the run
```

You can inspect jobs from the host at any time without entering the container.

### Security notes

- **No Docker socket** is mounted anywhere in the stack.
- The interpreter container has `cap_drop: ALL`, `no-new-privileges`, and a `pids_limit`.
- All services communicate over the internal bridge network `ai_internal` (`internal: true`), which prevents containers from making outbound internet connections by default.  If the agent needs web access, remove `internal: true` from the `ai_internal` network definition and consider adding fine-grained egress controls.
- Each agent job runs in its own Python subprocess so jobs cannot share interpreter state.

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
2. Ensures persistent bind-mount folders exist (`ollama`, `openwebui`, `qdrant`, `workspace`, `workspace/agent/jobs`)
3. Prompts whether to pull the latest images before starting the stack
4. Starts all services including the interpreter sandbox and agent-runner
5. Waits for Ollama and agent-runner to be healthy
6. Shows existing models and suggests VRAM-based model combinations for you to pull
7. **Interactive admin account setup** — guides you through a safe sign-up flow using a hold point that temporarily enables Open WebUI sign-up via a SQLite update, then re-secures it once your account is created
8. Summarizes the stack status and downloaded models

If you prefer manual setup:

```bash
# Build and start all services
docker compose build
docker compose up -d

docker exec ollama ollama pull <model>
docker exec ollama ollama list
# Interact with Open WebUI once http://127.0.0.1:3000 is ready
```

## Accessing the stack

- **Open WebUI** — `http://127.0.0.1:3000`. Sign-up is disabled by default; the setup script guides you through a safe first-boot flow to create the admin account.
- **Ollama API** — available internally at `http://ollama:11434`; use `docker exec ollama ...` for CLI operations.
- **Qdrant** — REST on `http://qdrant:6333`, gRPC on `:6334` (both internal).
- **Playwright** — headless browser available to the interpreter container for web automation.
- **Interpreter gateway** — internal at `http://open-interpreter:8888`; managed by agent-runner.
- **Agent Runner** — internal at `http://agent-runner:9000`; auto-registered in Open WebUI.

## Playwright MCP server

The `playwright` service backs agent workflows that need a browser (web scraping, automated QA, etc.). It uses `mcr.microsoft.com/playwright:v1.55.0-jammy`, has 1 GB of shared memory, and is kept running idle so the interpreter container can connect.

To exercise Playwright manually:

```bash
docker compose exec playwright npx playwright test   # add your own tests inside ./workspace if desired
```

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

- Start all services: `docker compose up -d`
- Check status/logs: `docker compose logs -f <service>`
- Restart a service: `docker compose restart <service>`
- Stop and remove everything: `docker compose down`

Use `docker exec ollama ollama list` to view downloaded models and `docker exec ollama ollama pull <model>` to install more.

## Verifying runtimes and workflows

After the stack starts, verify each runtime with:

```bash
docker compose ps
docker compose exec playwright npx playwright --version
docker compose exec interpreter python --version
curl -sf http://127.0.0.1:3000/health
docker exec ollama ollama list
```

The setup script already performs these checks for you and prints the summarized status.

## Persistent data and conventions

- The directories `./ollama`, `./openwebui`, `./qdrant`, and `./workspace` are bind-mounted into the corresponding containers for persistence. Do not commit their contents.
- Agent job data lives under `./workspace/agent/jobs/<job_id>/` — logs, artifacts, and metadata are all in that directory.
- All containers drop capabilities (`cap_drop: ALL`), disable sign-up for Open WebUI by default, and run with `no-new-privileges`.
- The `workspace` directory is the shared volume used by the interpreter sandbox; treat it as the working area for all agent runs.

## Troubleshooting

- If the stack fails to start, inspect logs (`docker compose logs <service>`). Ensure the NVIDIA toolkit is installed if you're on GPU hardware.
- The setup script waits for `ollama list` to succeed; if it times out, rerun `./setup.sh` after checking hardware resources.
- If the interpreter or agent-runner containers are still building when the script runs, wait for them to finish: `docker compose logs -f interpreter agent-runner`.
- For admin creation issues, run `./setup.sh` again (it detects existing users and skips if already set up) or toggle sign-up manually:
  ```bash
  # Enable sign-up
  docker exec openwebui sqlite3 /app/backend/data/webui.db \
    "UPDATE config SET data = json_set(data, '$.ENABLE_SIGNUP', json('true'));"
  # Disable sign-up again after creating your account
  docker exec openwebui sqlite3 /app/backend/data/webui.db \
    "UPDATE config SET data = json_set(data, '$.ENABLE_SIGNUP', json('false'));"
  ```
- To change the model used by the interpreter, set `INTERPRETER_MODEL` in `docker-compose.yml` under the `interpreter` service (default: `ollama_chat/llama3`).

