import asyncio
from logging.config import fileConfig

from alembic import context
from sqlalchemy.ext.asyncio import create_async_engine

from backend.database.base import Base
from backend.models import (  # noqa: F401  (register tables on Base.metadata)
    DashboardActivity,
    DashboardDailySnapshot,
    DashboardHourlySales,
    RefreshSession,
    ReportDailySales,
    ReportLocation,
    User,
)
from backend.utils.config import get_settings

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def get_url() -> str:
    """Resolve the migration URL from Alembic or application settings."""
    configured = context.config.get_main_option("sqlalchemy.url")
    if configured:
        return configured
    return get_settings().database_url


def run_migrations_offline() -> None:
    """Run migrations without creating a live database connection."""
    context.configure(
        url=get_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def _do_run_migrations(connection) -> None:
    context.configure(connection=connection, target_metadata=target_metadata)
    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    """Run migrations through the configured asynchronous database driver."""
    engine = create_async_engine(get_url())
    async with engine.connect() as connection:
        await connection.run_sync(_do_run_migrations)
    await engine.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
