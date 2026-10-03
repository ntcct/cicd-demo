"""Unit tests for the cicd-demo service."""

from __future__ import annotations

import importlib

from fastapi.testclient import TestClient

import app.main as main_module
from app.config import Settings

client = TestClient(main_module.app)


def test_root_reports_environment(monkeypatch):
    monkeypatch.setenv("APP_ENV", "stage")
    monkeypatch.setenv("APP_VERSION", "1.2.3")
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.json()
    assert body["environment"] == "stage"
    assert body["version"] == "1.2.3"
    assert body["app"] == "cicd-demo"


def test_healthz():
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_readyz():
    resp = client.get("/readyz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ready"}


def test_metrics_is_prometheus_text():
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert "text/plain" in resp.headers["content-type"]
    assert "app_requests_total" in resp.text


def test_settings_defaults(monkeypatch):
    for var in ("APP_NAME", "APP_ENV", "APP_VERSION", "LOG_LEVEL"):
        monkeypatch.delenv(var, raising=False)
    settings = Settings.from_env()
    assert settings.app_name == "cicd-demo"
    assert settings.app_env == "local"
    assert settings.app_version == "0.0.0-dev"
    assert settings.log_level == "info"


def test_settings_from_env(monkeypatch):
    monkeypatch.setenv("APP_ENV", "prod")
    monkeypatch.setenv("LOG_LEVEL", "WARN")
    settings = Settings.from_env()
    assert settings.app_env == "prod"
    assert settings.log_level == "warn"


def test_module_imports_clean():
    # Guard against import-time side effects breaking the app.
    importlib.reload(main_module)
    assert main_module.app is not None
