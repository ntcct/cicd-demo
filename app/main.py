"""FastAPI service for the CI/CD demo.

The service is intentionally small. Its job is to make the pipeline visible:
the root endpoint reports which environment the running pod believes it is in,
so you can confirm that dev / stage / prod are genuinely distinct deployments
of the same immutable image.
"""

from __future__ import annotations

from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse

from app.config import Settings, get_settings

app = FastAPI(title="cicd-demo", docs_url="/docs")

# Minimal Prometheus-style counters (no external deps) to demonstrate that
# observability hooks exist and are part of the deployable contract.
_request_count = 0


@app.middleware("http")
async def _count_requests(request, call_next):
    global _request_count
    _request_count += 1
    return await call_next(request)


@app.get("/")
def root() -> JSONResponse:
    """Report identity + which environment this pod thinks it is."""
    settings: Settings = get_settings()
    return JSONResponse(
        {
            "app": settings.app_name,
            "environment": settings.app_env,
            "version": settings.app_version,
            "message": f"Hello from {settings.app_env}!",
        }
    )


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness probe: process is up and able to serve."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, str]:
    """Readiness probe: safe to receive traffic."""
    return {"status": "ready"}


@app.get("/metrics")
def metrics() -> Response:
    """Expose minimal Prometheus-format metrics."""
    settings = get_settings()
    body = (
        "# HELP app_requests_total Total HTTP requests handled.\n"
        "# TYPE app_requests_total counter\n"
        f'app_requests_total{{env="{settings.app_env}"}} {_request_count}\n'
    )
    return Response(content=body, media_type="text/plain; version=0.0.4")
