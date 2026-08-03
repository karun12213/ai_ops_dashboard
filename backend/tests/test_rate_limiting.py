import asyncio
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi import HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.api.routes.auth import login, refresh, register
from backend.api.schemas.auth import LoginRequest, RefreshRequest, RegisterRequest
from backend.auth.rate_limit import FailureLockout, InMemoryRateLimiter, reset_rate_limits
from backend.auth.security import verify_password as real_verify_password
from backend.auth.security import hash_password
from backend.database.base import Base
from backend.models.user import User
from backend.services.user_service import UserService
from backend.utils.config import get_settings

settings = get_settings()


def _fake_request(ip: str = "203.0.113.5") -> Request:
    return Request(scope={"type": "http", "client": (ip, 12345), "headers": []})


class RateLimiterPrimitiveTests(unittest.IsolatedAsyncioTestCase):
    """Unit tests for the limiter/lockout primitives, independent of the
    route wiring and the real (multi-minute) configured durations."""

    async def test_allows_requests_below_the_limit(self) -> None:
        limiter = InMemoryRateLimiter()
        for _ in range(3):
            self.assertIsNone(await limiter.hit("k", limit=3, window_seconds=60))

    async def test_blocks_requests_above_the_limit(self) -> None:
        limiter = InMemoryRateLimiter()
        for _ in range(3):
            await limiter.hit("k", limit=3, window_seconds=60)
        retry_after = await limiter.hit("k", limit=3, window_seconds=60)
        self.assertIsNotNone(retry_after)
        self.assertGreater(retry_after, 0)

    async def test_lockout_triggers_after_threshold_failures(self) -> None:
        lockout = FailureLockout()
        for _ in range(4):
            await lockout.register_failure(
                "user@example.com", threshold=5, window_seconds=60, lockout_duration_seconds=60
            )
            self.assertIsNone(await lockout.is_locked("user@example.com", lockout_duration_seconds=60))
        await lockout.register_failure(
            "user@example.com", threshold=5, window_seconds=60, lockout_duration_seconds=60
        )
        retry_after = await lockout.is_locked("user@example.com", lockout_duration_seconds=60)
        self.assertIsNotNone(retry_after)

    async def test_lockout_is_temporary_and_expires(self) -> None:
        lockout = FailureLockout()
        for _ in range(3):
            await lockout.register_failure(
                "user@example.com", threshold=3, window_seconds=60, lockout_duration_seconds=0.2
            )
        self.assertIsNotNone(await lockout.is_locked("user@example.com", lockout_duration_seconds=0.2))
        await asyncio.sleep(0.3)
        # Fully cleared, not merely decremented: a fresh failure count starts here.
        self.assertIsNone(await lockout.is_locked("user@example.com", lockout_duration_seconds=0.2))

    async def test_success_clears_the_failure_count(self) -> None:
        lockout = FailureLockout()
        for _ in range(4):
            await lockout.register_failure(
                "user@example.com", threshold=5, window_seconds=60, lockout_duration_seconds=60
            )
        await lockout.clear("user@example.com")
        for _ in range(4):
            result = await lockout.register_failure(
                "user@example.com", threshold=5, window_seconds=60, lockout_duration_seconds=60
            )
            self.assertIsNone(result)
        self.assertIsNone(await lockout.is_locked("user@example.com", lockout_duration_seconds=60))


class UserEnumerationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        await reset_rate_limits()
        self.temp_directory = tempfile.TemporaryDirectory()
        database_path = Path(self.temp_directory.name) / "enumeration-test.db"
        self.engine = create_async_engine(f"sqlite+aiosqlite:///{database_path.as_posix()}")
        self.session_factory = async_sessionmaker(bind=self.engine, class_=AsyncSession, expire_on_commit=False)
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with self.session_factory() as session:
            session.add(
                User(
                    email="operator@example.com",
                    full_name="Operator One",
                    hashed_password=hash_password("StrongPassword123!"),
                    is_active=True,
                )
            )
            await session.commit()

    async def asyncTearDown(self) -> None:
        await self.engine.dispose()
        self.temp_directory.cleanup()
        await reset_rate_limits()

    async def test_authenticate_verifies_a_password_even_for_missing_users(self) -> None:
        async with self.session_factory() as session:
            with patch(
                "backend.services.user_service.verify_password", wraps=real_verify_password
            ) as spy:
                result = await UserService(session).authenticate(
                    "nonexistent@example.com", "whatever-password"
                )
        self.assertIsNone(result)
        spy.assert_called_once()

    async def test_login_response_is_identical_for_missing_and_wrong_password_accounts(self) -> None:
        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as missing_caught:
                await login(
                    _fake_request("198.51.100.40"),
                    LoginRequest(email="nonexistent@example.com", password="WrongPassword123!"),
                    session,
                )
        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as wrong_caught:
                await login(
                    _fake_request("198.51.100.41"),
                    LoginRequest(email="operator@example.com", password="WrongPassword123!"),
                    session,
                )
        self.assertEqual(missing_caught.exception.status_code, wrong_caught.exception.status_code)
        self.assertEqual(missing_caught.exception.detail, wrong_caught.exception.detail)

    async def test_lockout_triggers_identically_for_missing_and_real_accounts(self) -> None:
        for email, ip in (
            ("nonexistent@example.com", "198.51.100.50"),
            ("operator@example.com", "198.51.100.51"),
        ):
            for _ in range(settings.rate_limit_login_lockout_threshold):
                async with self.session_factory() as session:
                    with self.assertRaises(HTTPException) as caught:
                        await login(
                            _fake_request(ip),
                            LoginRequest(email=email, password="WrongPassword123!"),
                            session,
                        )
                    self.assertEqual(caught.exception.status_code, 401)
            async with self.session_factory() as session:
                with self.assertRaises(HTTPException) as locked_caught:
                    await login(
                        _fake_request(ip),
                        LoginRequest(email=email, password="WrongPassword123!"),
                        session,
                    )
            self.assertEqual(locked_caught.exception.status_code, 429)
            self.assertIn("Retry-After", locked_caught.exception.headers)


class AuthEndpointRateLimitTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        await reset_rate_limits()
        self.temp_directory = tempfile.TemporaryDirectory()
        database_path = Path(self.temp_directory.name) / "rate-limit-test.db"
        self.engine = create_async_engine(f"sqlite+aiosqlite:///{database_path.as_posix()}")
        self.session_factory = async_sessionmaker(bind=self.engine, class_=AsyncSession, expire_on_commit=False)
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with self.session_factory() as session:
            session.add(
                User(
                    email="operator@example.com",
                    full_name="Operator One",
                    hashed_password=hash_password("StrongPassword123!"),
                    is_active=True,
                )
            )
            await session.commit()

    async def asyncTearDown(self) -> None:
        await self.engine.dispose()
        self.temp_directory.cleanup()
        await reset_rate_limits()

    async def test_login_below_the_limit_succeeds(self) -> None:
        async with self.session_factory() as session:
            tokens = await login(
                _fake_request(),
                LoginRequest(email="operator@example.com", password="StrongPassword123!"),
                session,
            )
        self.assertTrue(tokens.access_token)

    async def test_login_ip_flood_returns_429_with_retry_after(self) -> None:
        for i in range(settings.rate_limit_login_ip_max):
            async with self.session_factory() as session:
                with self.assertRaises(HTTPException) as caught:
                    await login(
                        _fake_request("198.51.100.9"),
                        LoginRequest(email=f"nobody{i}@example.com", password="WrongPassword123!"),
                        session,
                    )
                self.assertEqual(caught.exception.status_code, 401)
        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as caught:
                await login(
                    _fake_request("198.51.100.9"),
                    LoginRequest(email="one-more@example.com", password="WrongPassword123!"),
                    session,
                )
        self.assertEqual(caught.exception.status_code, 429)
        self.assertIn("Retry-After", caught.exception.headers)
        self.assertGreater(int(caught.exception.headers["Retry-After"]), 0)

    async def test_repeated_failed_logins_trigger_a_temporary_lockout(self) -> None:
        for _ in range(settings.rate_limit_login_lockout_threshold):
            async with self.session_factory() as session:
                with self.assertRaises(HTTPException) as caught:
                    await login(
                        _fake_request("198.51.100.10"),
                        LoginRequest(email="operator@example.com", password="WrongPassword123!"),
                        session,
                    )
                self.assertEqual(caught.exception.status_code, 401)

        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as caught:
                await login(
                    _fake_request("198.51.100.10"),
                    LoginRequest(email="operator@example.com", password="StrongPassword123!"),
                    session,
                )
        self.assertEqual(caught.exception.status_code, 429)
        self.assertIn("Retry-After", caught.exception.headers)

    async def test_successful_login_resets_the_failure_count(self) -> None:
        for _ in range(settings.rate_limit_login_lockout_threshold - 1):
            async with self.session_factory() as session:
                with self.assertRaises(HTTPException) as caught:
                    await login(
                        _fake_request("198.51.100.11"),
                        LoginRequest(email="operator@example.com", password="WrongPassword123!"),
                        session,
                    )
                self.assertEqual(caught.exception.status_code, 401)

        async with self.session_factory() as session:
            tokens = await login(
                _fake_request("198.51.100.11"),
                LoginRequest(email="operator@example.com", password="StrongPassword123!"),
                session,
            )
        self.assertTrue(tokens.access_token)

        # If the earlier failures had survived the success, this next batch
        # would push the total past the threshold and lock the account.
        for _ in range(settings.rate_limit_login_lockout_threshold - 1):
            async with self.session_factory() as session:
                with self.assertRaises(HTTPException) as caught:
                    await login(
                        _fake_request("198.51.100.11"),
                        LoginRequest(email="operator@example.com", password="WrongPassword123!"),
                        session,
                    )
                self.assertEqual(caught.exception.status_code, 401)

    async def test_registration_is_throttled_per_ip(self) -> None:
        for i in range(settings.rate_limit_register_ip_max):
            async with self.session_factory() as session:
                await register(
                    _fake_request("198.51.100.20"),
                    RegisterRequest(
                        email=f"new{i}@example.com", full_name="New User", password="StrongPassword123!"
                    ),
                    session,
                )
        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as caught:
                await register(
                    _fake_request("198.51.100.20"),
                    RegisterRequest(
                        email="onemore@example.com", full_name="New User", password="StrongPassword123!"
                    ),
                    session,
                )
        self.assertEqual(caught.exception.status_code, 429)
        self.assertIn("Retry-After", caught.exception.headers)

    async def test_refresh_is_throttled_per_ip(self) -> None:
        for _ in range(settings.rate_limit_refresh_ip_max):
            async with self.session_factory() as session:
                with self.assertRaises(HTTPException) as caught:
                    await refresh(
                        _fake_request("198.51.100.30"), RefreshRequest(refresh_token="x" * 20), session
                    )
                self.assertEqual(caught.exception.status_code, 401)
        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as caught:
                await refresh(
                    _fake_request("198.51.100.30"), RefreshRequest(refresh_token="x" * 20), session
                )
        self.assertEqual(caught.exception.status_code, 429)
        self.assertIn("Retry-After", caught.exception.headers)

    async def test_different_ips_do_not_share_a_budget(self) -> None:
        for i in range(settings.rate_limit_login_ip_max):
            async with self.session_factory() as session:
                with self.assertRaises(HTTPException) as caught:
                    await login(
                        _fake_request("198.51.100.60"),
                        LoginRequest(email=f"flooder{i}@example.com", password="WrongPassword123!"),
                        session,
                    )
                self.assertEqual(caught.exception.status_code, 401)
        # A different source IP must still be allowed through.
        async with self.session_factory() as session:
            tokens = await login(
                _fake_request("198.51.100.61"),
                LoginRequest(email="operator@example.com", password="StrongPassword123!"),
                session,
            )
        self.assertTrue(tokens.access_token)


if __name__ == "__main__":
    unittest.main()
