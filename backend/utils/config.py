import secrets
from functools import lru_cache
from typing import List, Optional

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_KNOWN_PLACEHOLDER_JWT_SECRETS = frozenset(
    {
        "change-this-development-secret-to-at-least-32-chars",
        "local-development-secret-change-before-production",
        "replace-with-a-long-random-secret-at-least-32-characters",
    }
)
_PLACEHOLDER_JWT_MARKERS = (
    "change-this-",
    "change-before-production",
    "local-development-",
    "replace-with-",
    "your-secret",
    "example-secret",
    "development-secret",
    "test-secret",
)


def _generate_development_jwt_secret() -> str:
    """Return an ephemeral local secret when none was configured."""
    return secrets.token_urlsafe(48)


class Settings(BaseSettings):
    app_name: str = "Restaurant Ops API"
    app_env: str = "development"
    debug: bool = False
    docs_enabled: Optional[bool] = None
    api_v1_prefix: str = "/api/v1"

    # Keep local development self-contained. Docker and production override this
    # with PostgreSQL through DATABASE_URL.
    database_url: str = "sqlite+aiosqlite:///./backend/restaurant_ops.db"
    auto_create_tables: Optional[bool] = None

    audio_local_storage_path: str = "./backend/audio_uploads"
    audio_max_upload_bytes: int = Field(default=100 * 1024 * 1024, ge=1, le=100 * 1024 * 1024)

    # Development bootstrap account. Its values must come from the environment;
    # production always ignores the seed flag, even if it is set accidentally.
    seed_default_admin: bool = False
    default_admin_email: Optional[str] = None
    default_admin_full_name: Optional[str] = None
    default_admin_password: Optional[SecretStr] = None

    jwt_secret_key: str = Field(default_factory=_generate_development_jwt_secret, min_length=32)
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = Field(default=30, ge=5, le=1440)
    refresh_token_expire_days: int = Field(default=7, ge=1, le=90)

    cors_origins: str = "http://localhost:3000,http://localhost:8080,http://localhost:5000"
    cors_origin_regex: Optional[str] = None

    # Per-source-IP request budgets for the authentication endpoints.
    rate_limit_login_ip_max: int = Field(default=10, ge=1)
    rate_limit_login_ip_window_seconds: float = Field(default=60.0, gt=0)
    rate_limit_register_ip_max: int = Field(default=5, ge=1)
    rate_limit_register_ip_window_seconds: float = Field(default=3600.0, gt=0)
    rate_limit_refresh_ip_max: int = Field(default=30, ge=1)
    rate_limit_refresh_ip_window_seconds: float = Field(default=60.0, gt=0)

    # Temporary, self-expiring lockout after repeated failed logins for a
    # given email. Never a permanent ban: once the lockout duration elapses
    # the account is fully usable again with a fresh failure count.
    rate_limit_login_lockout_threshold: int = Field(default=5, ge=1)
    rate_limit_login_lockout_window_seconds: float = Field(default=60.0, gt=0)
    rate_limit_login_lockout_duration_seconds: float = Field(default=300.0, gt=0)

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    @model_validator(mode="after")
    def _validate_production_safety(self) -> "Settings":
        if self.app_env.lower() != "production":
            return self

        if "jwt_secret_key" not in self.model_fields_set:
            raise ValueError("JWT_SECRET_KEY must be explicitly configured in production.")
        normalized_secret = self.jwt_secret_key.strip().lower()
        if self.jwt_secret_key in _KNOWN_PLACEHOLDER_JWT_SECRETS or any(
            marker in normalized_secret for marker in _PLACEHOLDER_JWT_MARKERS
        ):
            raise ValueError(
                "JWT_SECRET_KEY must be a unique random value and must not use a "
                "documented development or placeholder secret in production."
            )
        if self.database_url.strip().lower().startswith("sqlite"):
            raise ValueError("DATABASE_URL must use PostgreSQL rather than SQLite in production.")
        if self.auto_create_tables is True:
            raise ValueError(
                "AUTO_CREATE_TABLES=true is forbidden in production; apply Alembic "
                "migrations before application startup."
            )
        return self

    @property
    def cors_origin_list(self) -> List[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]

    @property
    def should_auto_create_tables(self) -> bool:
        if self.auto_create_tables is not None:
            return self.auto_create_tables
        return self.app_env.lower() in {"development", "dev", "local", "test"}

    @property
    def should_enable_docs(self) -> bool:
        """Enable API documentation by default outside production."""
        if self.docs_enabled is not None:
            return self.docs_enabled
        return self.app_env.lower() != "production"

    @property
    def is_development(self) -> bool:
        return self.app_env.lower() in {"development", "dev", "local"}

    @property
    def should_seed_default_admin(self) -> bool:
        return self.is_development and self.seed_default_admin

    @property
    def effective_cors_origin_regex(self) -> Optional[str]:
        if self.cors_origin_regex and self.cors_origin_regex.strip():
            return self.cors_origin_regex.strip()
        if self.app_env.lower() in {"development", "dev", "local", "test"}:
            # Flutter's web runner normally selects an available random port.
            return r"^https?://(?:localhost|127\.0\.0\.1)(?::\d+)?$"
        return None


@lru_cache
def get_settings() -> Settings:
    return Settings()
