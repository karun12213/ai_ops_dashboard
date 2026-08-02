from functools import lru_cache
from typing import List, Optional

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "Restaurant Ops API"
    app_env: str = "development"
    debug: bool = False
    docs_enabled: bool = True
    api_v1_prefix: str = "/api/v1"

    # Keep local development self-contained. Docker and production override this
    # with PostgreSQL through DATABASE_URL.
    database_url: str = "sqlite+aiosqlite:///./backend/restaurant_ops.db"
    auto_create_tables: Optional[bool] = None

    # Development bootstrap account. Its values must come from the environment;
    # production always ignores the seed flag, even if it is set accidentally.
    seed_default_admin: bool = False
    default_admin_email: Optional[str] = None
    default_admin_full_name: Optional[str] = None
    default_admin_password: Optional[SecretStr] = None

    jwt_secret_key: str = Field(default="change-this-development-secret-to-at-least-32-chars", min_length=32)
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = Field(default=30, ge=5, le=1440)
    refresh_token_expire_days: int = Field(default=7, ge=1, le=90)

    cors_origins: str = "http://localhost:3000,http://localhost:8080,http://localhost:5000"
    cors_origin_regex: Optional[str] = None

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    @property
    def cors_origin_list(self) -> List[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]

    @property
    def should_auto_create_tables(self) -> bool:
        if self.auto_create_tables is not None:
            return self.auto_create_tables
        return self.app_env.lower() in {"development", "dev", "local", "test"}

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
