"""Environment-driven configuration (12-factor).

All settings come from environment variables so the exact same image can be
promoted unchanged across dev -> stage -> prod. Nothing environment-specific
is baked into the artifact.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Immutable application settings sourced from the environment."""

    app_name: str
    app_env: str
    app_version: str
    log_level: str

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            app_name=os.getenv("APP_NAME", "cicd-demo"),
            app_env=os.getenv("APP_ENV", "local"),
            app_version=os.getenv("APP_VERSION", "0.0.0-dev"),
            log_level=os.getenv("LOG_LEVEL", "info").lower(),
        )


def get_settings() -> Settings:
    """Return settings loaded from the current environment."""
    return Settings.from_env()
