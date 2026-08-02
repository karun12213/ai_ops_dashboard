import asyncio
import logging

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from backend.auth.security import hash_password, verify_password
from backend.database.base import Base
from backend.database.session import AsyncSessionLocal, engine
from backend.models.user import User
from backend.utils.config import Settings, get_settings

logger = logging.getLogger(__name__)
settings = get_settings()


async def seed_default_admin(
    *,
    session_factory: async_sessionmaker[AsyncSession] = AsyncSessionLocal,
    config: Settings = settings,
) -> User | None:
    """Create or synchronize the configured administrator in development only."""
    if not config.should_seed_default_admin:
        return None

    email = (config.default_admin_email or "").strip().lower()
    full_name = (config.default_admin_full_name or "").strip()
    password = (
        config.default_admin_password.get_secret_value()
        if config.default_admin_password is not None
        else ""
    )
    if not email or not full_name or len(password) < 8 or len(password) > 128:
        raise RuntimeError(
            "Development administrator seed requires DEFAULT_ADMIN_EMAIL, "
            "DEFAULT_ADMIN_FULL_NAME, and an 8-128 character "
            "DEFAULT_ADMIN_PASSWORD"
        )

    async with session_factory() as session:
        user = await session.scalar(select(User).where(User.email == email))
        if user is None:
            user = User(
                email=email,
                full_name=full_name,
                hashed_password=hash_password(password),
                is_active=True,
                is_superuser=True,
            )
            session.add(user)
        else:
            user.full_name = full_name
            if not verify_password(password, user.hashed_password):
                user.hashed_password = hash_password(password)
            user.is_active = True
            user.is_superuser = True

        await session.commit()
        await session.refresh(user)
        logger.info("Development administrator seed is ready")
        return user


async def init_db() -> None:
    """Create tables for local/bootstrap environments.

    Production deployments should set AUTO_CREATE_TABLES=false and use managed
    migrations before rollout.
    """
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    await seed_default_admin()


def main() -> None:
    """Run the development schema/bootstrap seed from the command line."""
    if not settings.is_development:
        raise SystemExit("Development user seeding is disabled outside development mode")
    if not settings.should_seed_default_admin:
        raise SystemExit("Set SEED_DEFAULT_ADMIN=true to run the development seed")
    asyncio.run(init_db())


if __name__ == "__main__":
    main()
