#!/usr/bin/env python3
"""
Agent Runner — OpenAPI Tool Server for Open WebUI.

This service is registered as a Global Tool Server in Open WebUI via the
TOOL_SERVER_CONNECTIONS environment variable.  It forwards execution requests
to the interpreter gateway running inside the persistent sandbox container.

Endpoints are described with rich docstrings so that the LLM can understand
what each tool does and how to call it.
"""
from __future__ import annotations

import os
from typing import List, Optional

import httpx
from fastapi import FastAPI, HTTPException, Path
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

GATEWAY_URL = os.getenv("INTERPRETER_GATEWAY_URL", "http://interpreter:8888")

app = FastAPI(
    title="Agent Runner",
    description=(
        "OpenAPI tool server that gives an LLM the ability to dispatch autonomous "
        "agent jobs to a persistent sandbox.  The sandbox has access to Python, a "
        "headless browser (Playwright/Chromium), a vector database (Qdrant), and a "
        "persistent workspace at /workspace.  All job logs and produced files are "
        "stored under ./workspace/agent/jobs/<job_id>/ on the host."
    ),
    version="1.0.0",
)


# ── Pydantic models ────────────────────────────────────────────────────────────

class JobCreate(BaseModel):
    task: str
    model: Optional[str] = None


class JobStatus(BaseModel):
    job_id: str
    task: str
    status: str  # queued | running | done | failed
    created_at: str
    completed_at: Optional[str] = None
    error: Optional[str] = None


# ── Gateway proxy helper ───────────────────────────────────────────────────────

def _gw(path: str, method: str = "GET", **kwargs) -> httpx.Response:
    """Forward a request to the interpreter gateway."""
    try:
        r = httpx.request(method, f"{GATEWAY_URL}{path}", timeout=30, **kwargs)
        r.raise_for_status()
        return r
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=exc.response.status_code, detail=exc.response.text
        ) from exc
    except httpx.RequestError as exc:
        raise HTTPException(
            status_code=503,
            detail=f"Interpreter gateway unavailable: {exc}",
        ) from exc


# ── Tool endpoints ─────────────────────────────────────────────────────────────

@app.post(
    "/agent/jobs",
    response_model=JobStatus,
    status_code=201,
    summary="Create an autonomous agent job",
    description=(
        "Submit a natural-language task for the autonomous agent to execute. "
        "The agent runs fully autonomously in a persistent sandbox with access "
        "to Python, a headless web browser, a vector store, and a persistent "
        "workspace. Returns a job_id immediately; use the status/logs endpoints "
        "to track progress.  All output files are saved under "
        "./workspace/agent/jobs/<job_id>/ on the host."
    ),
)
def create_job(body: JobCreate) -> dict:
    payload: dict = {"task": body.task}
    if body.model:
        payload["model"] = body.model
    return _gw("/jobs", method="POST", json=payload).json()


@app.get(
    "/agent/jobs",
    response_model=List[JobStatus],
    summary="List all agent jobs",
    description=(
        "Returns a list of all agent jobs with their current status "
        "(queued, running, done, or failed)."
    ),
)
def list_jobs() -> list:
    return _gw("/jobs").json()


@app.get(
    "/agent/jobs/{job_id}",
    response_model=JobStatus,
    summary="Get agent job status",
    description="Returns the current status and metadata for a specific agent job.",
)
def get_job(
    job_id: str = Path(..., description="The job ID returned by POST /agent/jobs"),
) -> dict:
    return _gw(f"/jobs/{job_id}").json()


@app.get(
    "/agent/jobs/{job_id}/logs",
    response_class=PlainTextResponse,
    summary="Get agent job logs",
    description=(
        "Returns the full execution log for a specific agent job. "
        "The log captures all interpreter output including code executed "
        "and any errors encountered."
    ),
)
def get_logs(
    job_id: str = Path(..., description="The job ID returned by POST /agent/jobs"),
) -> str:
    return _gw(f"/jobs/{job_id}/logs").text


@app.get(
    "/agent/jobs/{job_id}/artifacts",
    summary="List job artifacts",
    description=(
        "Lists files produced by the agent job in its workspace directory "
        "(./workspace/agent/jobs/<job_id>/ on the host)."
    ),
)
def list_artifacts(
    job_id: str = Path(..., description="The job ID returned by POST /agent/jobs"),
) -> dict:
    return _gw(f"/jobs/{job_id}/artifacts").json()


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}
