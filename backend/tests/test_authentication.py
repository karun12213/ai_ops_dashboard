import tempfile
import unittest
from pathlib import Path

from fastapi import HTTPException, Request
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.api.routes.auth import login, me
from backend.api.schemas.auth import LoginRequest
from backend.auth.rate_limit import reset_rate_limits
from backend.auth.security import hash_password, verify_password
from backend.database.base import Base
from backend.database.init_db import seed_default_admin
from backend.models.user import User
from backend.utils.config import Settings


def _fake_request(ip: str = "203.0.113.5") -> Request:
    return Request(scope={"type": "http", "client": (ip, 12345), "headers": []})


class AuthenticationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        await reset_rate_limits()
        self.temp_directory = tempfile.TemporaryDirectory()
        database_path = Path(self.temp_directory.name) / "auth-test.db"
        self.engine = create_async_engine(f"sqlite+aiosqlite:///{database_path.as_posix()}")
        self.session_factory = async_sessionmaker(
            bind=self.engine,
            class_=AsyncSession,
            expire_on_commit=False,
        )
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    async def asyncTearDown(self) -> None:
        await self.engine.dispose()
        self.temp_directory.cleanup()

    @staticmethod
    def development_settings(**overrides: object) -> Settings:
        values: dict[str, object] = {
            "app_env": "development",
            "seed_default_admin": True,
            "default_admin_email": "admin@sentinelops.local",
            "default_admin_full_name": "Sentinel Ops Administrator",
            "default_admin_password": "ChangeMe123!",
        }
        values.update(overrides)
        return Settings(_env_file=None, **values)

    async def test_seed_creates_configured_user_when_another_admin_exists(self) -> None:
        async with self.session_factory() as session:
            session.add(
                User(
                    email="existing@example.com",
                    full_name="Existing Administrator",
                    hashed_password=hash_password("DifferentPassword123!"),
                    is_active=True,
                    is_superuser=True,
                )
            )
            await session.commit()

        seeded = await seed_default_admin(
            session_factory=self.session_factory,
            config=self.development_settings(),
        )

        self.assertIsNotNone(seeded)
        assert seeded is not None
        self.assertEqual(seeded.email, "admin@sentinelops.local")
        self.assertTrue(seeded.is_active)
        self.assertTrue(seeded.is_superuser)
        self.assertNotEqual(seeded.hashed_password, "ChangeMe123!")
        self.assertTrue(seeded.hashed_password.startswith("$argon2id$"))
        self.assertTrue(verify_password("ChangeMe123!", seeded.hashed_password))

        second_seed = await seed_default_admin(
            session_factory=self.session_factory,
            config=self.development_settings(),
        )
        self.assertEqual(second_seed.id, seeded.id)
        async with self.session_factory() as session:
            count = await session.scalar(select(func.count()).select_from(User))
        self.assertEqual(count, 2)

    async def test_seed_is_disabled_in_production_even_when_flag_is_true(self) -> None:
        result = await seed_default_admin(
            session_factory=self.session_factory,
            config=self.development_settings(
                app_env="production",
                database_url="postgresql+asyncpg://app@db:5432/app",
                jwt_secret_key="x" * 48,
            ),
        )

        self.assertIsNone(result)
        async with self.session_factory() as session:
            count = await session.scalar(select(func.count()).select_from(User))
        self.assertEqual(count, 0)

    async def test_login_uses_the_seeded_argon2_password(self) -> None:
        await seed_default_admin(
            session_factory=self.session_factory,
            config=self.development_settings(),
        )

        async with self.session_factory() as session:
            tokens = await login(
                _fake_request(),
                LoginRequest(
                    email="admin@sentinelops.local",
                    password="ChangeMe123!",
                ),
                session,
            )
            self.assertTrue(tokens.access_token)
            self.assertTrue(tokens.refresh_token)

            seeded_user = await session.scalar(
                select(User).where(User.email == "admin@sentinelops.local")
            )
            self.assertIsNotNone(seeded_user)
            assert seeded_user is not None
            profile = await me(seeded_user)
            self.assertEqual(profile.email, "admin@sentinelops.local")

            with self.assertRaises(HTTPException) as caught:
                await login(
                    _fake_request(),
                    LoginRequest(
                        email="admin@sentinelops.local",
                        password="WrongPassword123!",
                    ),
                    session,
                )
            self.assertEqual(caught.exception.status_code, 401)
            self.assertEqual(caught.exception.detail, "Incorrect email or password")

    def test_login_schema_accepts_and_normalizes_development_email(self) -> None:
        payload = LoginRequest(
            email=" ADMIN@SENTINELOPS.LOCAL ",
            password="ChangeMe123!",
        )

        self.assertEqual(payload.email, "admin@sentinelops.local")


if __name__ == "__main__":
    unittest.main()
