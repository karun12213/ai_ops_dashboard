import tempfile
import unittest
from pathlib import Path
from typing import AsyncIterator

from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.auth.rate_limit import reset_rate_limits
from backend.auth.security import create_access_token, hash_password
from backend.database.base import Base
from backend.database.session import get_db
from backend.main import app
from backend.models.user import User
from backend.utils.config import get_settings

settings = get_settings()


class AuthenticationHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        await reset_rate_limits()
        self.temp_directory = tempfile.TemporaryDirectory()
        database_path = Path(self.temp_directory.name) / "auth-http-test.db"
        self.engine = create_async_engine(f"sqlite+aiosqlite:///{database_path.as_posix()}")
        self.session_factory = async_sessionmaker(
            bind=self.engine,
            class_=AsyncSession,
            expire_on_commit=False,
        )
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

        session_factory = self.session_factory

        async def override_get_db() -> AsyncIterator[AsyncSession]:
            async with session_factory() as session:
                try:
                    yield session
                except Exception:
                    await session.rollback()
                    raise

        app.dependency_overrides[get_db] = override_get_db
        self.client = AsyncClient(
            transport=ASGITransport(
                app=app,
                client=("203.0.113.100", 43120),
                raise_app_exceptions=True,
            ),
            base_url="http://testserver",
        )

    async def asyncTearDown(self) -> None:
        await self.client.aclose()
        app.dependency_overrides.clear()
        await self.engine.dispose()
        self.temp_directory.cleanup()
        await reset_rate_limits()

    async def _register(
        self,
        *,
        email: str = "operator@example.com",
        password: str = "StrongPassword123!",
    ):
        return await self.client.post(
            "/api/v1/auth/register",
            json={
                "email": email,
                "full_name": "Test Operator",
                "password": password,
            },
        )

    async def _login(
        self,
        *,
        email: str = "operator@example.com",
        password: str = "StrongPassword123!",
    ):
        return await self.client.post(
            "/api/v1/auth/login",
            json={"email": email, "password": password},
        )

    async def test_register_persists_a_hashed_operator_and_rejects_duplicates(self) -> None:
        response = await self._register(email=" New.Operator@Example.com ")
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.json()["email"], "new.operator@example.com")
        self.assertNotIn("hashed_password", response.json())

        async with self.session_factory() as session:
            user = await session.scalar(
                select(User).where(User.email == "new.operator@example.com")
            )
        self.assertIsNotNone(user)
        assert user is not None
        self.assertTrue(user.hashed_password.startswith("$argon2id$"))
        self.assertNotEqual(user.hashed_password, "StrongPassword123!")

        duplicate = await self._register(email="new.operator@example.com")
        self.assertEqual(duplicate.status_code, 409)
        self.assertEqual(duplicate.json()["detail"], "Email is already registered")

    async def test_login_and_me_use_the_http_bearer_contract(self) -> None:
        self.assertEqual((await self._register()).status_code, 201)
        login_response = await self._login()
        self.assertEqual(login_response.status_code, 200)
        tokens = login_response.json()
        self.assertEqual(tokens["token_type"], "bearer")
        self.assertTrue(tokens["access_token"])
        self.assertTrue(tokens["refresh_token"])

        unauthorized = await self.client.get("/api/v1/auth/me")
        self.assertEqual(unauthorized.status_code, 401)
        self.assertEqual(unauthorized.headers["www-authenticate"], "Bearer")

        profile = await self.client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {tokens['access_token']}"},
        )
        self.assertEqual(profile.status_code, 200)
        self.assertEqual(profile.json()["email"], "operator@example.com")
        self.assertEqual(profile.headers["x-content-type-options"], "nosniff")
        self.assertEqual(profile.headers["x-frame-options"], "DENY")

    async def test_refresh_rotates_and_logout_revokes_the_new_session(self) -> None:
        await self._register()
        original = (await self._login()).json()

        refresh_response = await self.client.post(
            "/api/v1/auth/refresh",
            json={"refresh_token": original["refresh_token"]},
        )
        self.assertEqual(refresh_response.status_code, 200)
        rotated = refresh_response.json()
        self.assertNotEqual(rotated["refresh_token"], original["refresh_token"])

        logout_response = await self.client.post(
            "/api/v1/auth/logout",
            headers={"Authorization": f"Bearer {rotated['access_token']}"},
            json={"refresh_token": rotated["refresh_token"]},
        )
        self.assertEqual(logout_response.status_code, 204)

        rejected = await self.client.post(
            "/api/v1/auth/refresh",
            json={"refresh_token": rotated["refresh_token"]},
        )
        self.assertEqual(rejected.status_code, 401)

    async def test_inactive_users_cannot_login_or_use_existing_access_tokens(self) -> None:
        async with self.session_factory() as session:
            user = User(
                email="inactive@example.com",
                full_name="Inactive Operator",
                hashed_password=hash_password("StrongPassword123!"),
                is_active=False,
            )
            session.add(user)
            await session.commit()
            await session.refresh(user)
            access_token = create_access_token(str(user.id))

        login_response = await self._login(email="inactive@example.com")
        self.assertEqual(login_response.status_code, 403)
        self.assertEqual(login_response.json()["detail"], "Account is disabled")

        profile = await self.client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        self.assertEqual(profile.status_code, 401)

    async def test_login_endpoint_enforces_the_per_ip_request_budget(self) -> None:
        for index in range(settings.rate_limit_login_ip_max):
            response = await self._login(
                email=f"missing{index}@example.com",
                password="WrongPassword123!",
            )
            self.assertEqual(response.status_code, 401)

        throttled = await self._login(
            email="one-more@example.com",
            password="WrongPassword123!",
        )
        self.assertEqual(throttled.status_code, 429)
        self.assertGreater(int(throttled.headers["retry-after"]), 0)

    async def test_register_endpoint_enforces_the_per_ip_request_budget(self) -> None:
        for index in range(settings.rate_limit_register_ip_max):
            response = await self._register(email=f"new{index}@example.com")
            self.assertEqual(response.status_code, 201)

        throttled = await self._register(email="one-more@example.com")
        self.assertEqual(throttled.status_code, 429)
        self.assertGreater(int(throttled.headers["retry-after"]), 0)

    async def test_refresh_endpoint_enforces_the_per_ip_request_budget(self) -> None:
        invalid_token = "x" * 20
        for _ in range(settings.rate_limit_refresh_ip_max):
            response = await self.client.post(
                "/api/v1/auth/refresh",
                json={"refresh_token": invalid_token},
            )
            self.assertEqual(response.status_code, 401)

        throttled = await self.client.post(
            "/api/v1/auth/refresh",
            json={"refresh_token": invalid_token},
        )
        self.assertEqual(throttled.status_code, 429)
        self.assertGreater(int(throttled.headers["retry-after"]), 0)

    async def test_repeated_failures_lock_an_account_before_password_verification(self) -> None:
        await self._register(email="locked@example.com")
        for _ in range(settings.rate_limit_login_lockout_threshold):
            response = await self._login(
                email="locked@example.com",
                password="WrongPassword123!",
            )
            self.assertEqual(response.status_code, 401)

        locked = await self._login(
            email="locked@example.com",
            password="StrongPassword123!",
        )
        self.assertEqual(locked.status_code, 429)
        self.assertGreater(int(locked.headers["retry-after"]), 0)


if __name__ == "__main__":
    unittest.main()
