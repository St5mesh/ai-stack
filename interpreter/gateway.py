#!/usr/bin/env python3
"""
Interpreter Gateway — internal HTTP API for running Open Interpreter jobs.

This service runs inside the persistent interpreter container and is only
reachable within the ai_internal Docker network.  The agent-runner service
acts as the public OpenAPI tool server and forwards requests here.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

JOBS_DIR = Path(os.getenv("JOBS_DIR", "/workspace/agent/jobs"))
JOB_TIMEOUT = int(os.getenv("JOB_TIMEOUT_SECONDS", "3600"))  # default 1 hour

app = FastAPI(
    title="Interpreter Gateway",
    description="Internal HTTP gateway for running Open Interpreter jobs autonomously.",
    version="1.0.0",
)


# ── Pydantic models ────────────────────────────────────────────────────────────

class JobCreate(BaseModel):
    task: str
    model: str = os.getenv("INTERPRETER_MODEL", "ollama_chat/llama3")


class JobStatus(BaseModel):
    job_id: str
    task: str
    status: str  # queued | running | done | failed
    created_at: str
    completed_at: Optional[str] = None
    error: Optional[str] = None


# ── Helpers ────────────────────────────────────────────────────────────────────

def _meta_path(job_id: str) -> Path:
    return JOBS_DIR / job_id / "task.json"


def _log_path(job_id: str) -> Path:
    return JOBS_DIR / job_id / "stdout.log"


def _read_meta(job_id: str) -> dict:
    p = _meta_path(job_id)
    if not p.exists():
        raise HTTPException(status_code=404, detail=f"Job {job_id!r} not found")
    return json.loads(p.read_text())


# ── Job runner ─────────────────────────────────────────────────────────────────

def _run_job(job_id: str, task: str, model: str) -> None:
    """Execute one job in a background thread.  Each job gets its own Python
    subprocess so interpreter state is fully isolated between runs."""
    job_dir = JOBS_DIR / job_id
    meta_path = _meta_path(job_id)
    log_path = _log_path(job_id)

    # Mark as running
    meta = json.loads(meta_path.read_text())
    meta["status"] = "running"
    meta_path.write_text(json.dumps(meta, indent=2))

    # Write a small per-job runner script so we avoid shell-escaping pitfalls
    runner = job_dir / "run.py"
    runner.write_text(
        f"""
import os, sys, json
os.chdir({repr(str(job_dir))})

from interpreter import interpreter  # type: ignore

interpreter.auto_run = True
# Support both old-style (0.2.x) and new-style (0.3+) attribute paths
try:
    interpreter.llm.model = {repr(model)}
    interpreter.llm.api_base = os.environ.get(
        "OLLAMA_BASE_URL", "http://ollama:11434"
    )
except AttributeError:
    interpreter.model = {repr(model)}
    interpreter.api_base = os.environ.get(
        "OLLAMA_BASE_URL", "http://ollama:11434"
    )

result = interpreter.chat({repr(task)})

with open("output.json", "w") as _f:
    json.dump(result, _f, indent=2, default=str)
"""
    )

    try:
        with open(log_path, "w") as lf:
            proc = subprocess.run(
                [sys.executable, str(runner)],
                stdout=lf,
                stderr=subprocess.STDOUT,
                cwd=str(job_dir),
                env={**os.environ, "PYTHONUNBUFFERED": "1"},
                timeout=JOB_TIMEOUT,
            )
        if proc.returncode == 0:
            meta["status"] = "done"
        else:
            meta["status"] = "failed"
            meta["error"] = f"Process exited with code {proc.returncode}. See logs."
    except subprocess.TimeoutExpired:
        meta["status"] = "failed"
        meta["error"] = f"Job timed out (limit: {JOB_TIMEOUT}s)"
    except Exception as exc:  # noqa: BLE001
        meta["status"] = "failed"
        meta["error"] = str(exc)

    meta["completed_at"] = datetime.now(timezone.utc).isoformat()
    meta_path.write_text(json.dumps(meta, indent=2))


# ── API endpoints ──────────────────────────────────────────────────────────────

@app.post("/jobs", response_model=JobStatus, status_code=201)
def create_job(body: JobCreate) -> dict:
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    job_id = uuid.uuid4().hex[:12]
    job_dir = JOBS_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)

    meta: dict = {
        "job_id": job_id,
        "task": body.task,
        "status": "queued",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "completed_at": None,
        "error": None,
    }
    _meta_path(job_id).write_text(json.dumps(meta, indent=2))

    threading.Thread(
        target=_run_job, args=(job_id, body.task, body.model), daemon=True
    ).start()
    return meta


@app.get("/jobs", response_model=List[JobStatus])
def list_jobs() -> list:
    if not JOBS_DIR.exists():
        return []
    result = []
    for p in sorted(JOBS_DIR.iterdir()):
        meta_p = p / "task.json"
        if meta_p.exists():
            result.append(json.loads(meta_p.read_text()))
    return result


@app.get("/jobs/{job_id}", response_model=JobStatus)
def get_job(job_id: str) -> dict:
    return _read_meta(job_id)


@app.get("/jobs/{job_id}/logs", response_class=PlainTextResponse)
def get_logs(job_id: str) -> str:
    _read_meta(job_id)  # validates existence
    log_p = _log_path(job_id)
    if not log_p.exists():
        return ""
    return log_p.read_text()


@app.get("/jobs/{job_id}/artifacts")
def list_artifacts(job_id: str) -> dict:
    _read_meta(job_id)
    job_dir = JOBS_DIR / job_id
    files = [
        str(f.relative_to(job_dir))
        for f in sorted(job_dir.rglob("*"))
        if f.is_file() and f.name not in {"task.json", "run.py", "stdout.log"}
    ]
    return {"job_id": job_id, "artifacts": files}


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}
