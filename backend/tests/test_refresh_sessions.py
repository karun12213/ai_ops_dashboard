import tempfile
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import jwt
from fastapi import HTTPException, Request
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.api.routes.auth import login, logout, refresh
from backend.api.schemas.auth import LoginRequest, RefreshRequest
from backend.auth.rate_limit import reset_rate_limits
from backend.auth.security import hash_password
from backend.database.base import Base
from backend.models.refresh_session import RefreshSession
from backend.models.user import User
from backend.utils.config import get_settings

settings = get_settings()


def _fake_request(ip: str = "203.0.113.5") -> Request:
    return Request(scope={"type": "http", "client": (ip, 12345), "headers": []})


class RefreshSessionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        await reset_rate_limits()
        self.temp_directory = tempfile.TemporaryDirectory()
        database_path = Path(self.temp_directory.name) / "refresh-sessions-test.db"
        self.engine = create_async_engine(f"sqlite+aiosqlite:///{database_path.as_posix()}")
        self.session_factory = async_sessionmaker(
            bind=self.engine, class_=AsyncSession, expire_on_commit=False
        )
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

        async with self.session_factory() as session:
            user = User(
                email="operator@example.com",
                full_name="Operator One",
                hashed_password=hash_password("StrongPassword123!"),
                is_active=True,
            )
            session.add(user)
            await session.commit()
            await session.refresh(user)
            self.user_id = user.id

    async def asyncTearDown(self) -> None:
        await self.engine.dispose()
        self.temp_directory.cleanup()

    async def _login(self, session: AsyncSession):
        return await login(
            _fake_request(),
            LoginRequest(email="operator@example.com", password="StrongPassword123!"),
            session,
        )

    async def _user(self, session: AsyncSession) -> User:
        return await session.get(User, self.user_id)

    def _jti(self, refresh_token: str) -> uuid.UUID:
        payload = jwt.decode(refresh_token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
        return uuid.UUID(payload["jti"])

    async def test_login_creates_a_tracked_refresh_session(self) -> None:
        async with self.session_factory() as session:
            await self._login(session)
            count = await session.scalar(select(func.count()).select_from(RefreshSession))
        self.assertEqual(count, 1)

    async def test_refresh_rotates_session_and_revokes_predecessor(self) -> None:
        async with self.session_factory() as session:
            first_tokens = await self._login(session)

        async with self.session_factory() as session:
            rotated_tokens = await refresh(
                _fake_request(), RefreshRequest(refresh_token=first_tokens.refresh_token), session
            )
        self.assertNotEqual(rotated_tokens.refresh_token, first_tokens.refresh_token)

        original_jti = self._jti(first_tokens.refresh_token)
        new_jti = self._jti(rotated_tokens.refresh_token)

        async with self.session_factory() as session:
            original_row = await session.get(RefreshSession, original_jti)
            self.assertIsNotNone(original_row.revoked_at)
            self.assertEqual(original_row.replaced_by_id, new_jti)

    async def test_reused_rotated_refresh_token_is_rejected(self) -> None:
        async with self.session_factory() as session:
            first_tokens = await self._login(session)
        async with self.session_factory() as session:
            await refresh(_fake_request(), RefreshRequest(refresh_token=first_tokens.refresh_token), session)

        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as caught:
                await refresh(_fake_request(), RefreshRequest(refresh_token=first_tokens.refresh_token), session)
        self.assertEqual(caught.exception.status_code, 401)

    async def test_reuse_revokes_all_active_sessions_for_user(self) -> None:
        async with self.session_factory() as session:
            session_a_tokens = await self._login(session)
        async with self.session_factory() as session:
            session_b_tokens = await self._login(session)

        # Rotate session A once, then replay the original (now-superseded) token.
        async with self.session_factory() as session:
            await refresh(_fake_request(), RefreshRequest(refresh_token=session_a_tokens.refresh_token), session)
        async with self.session_factory() as session:
            with self.assertRaises(HTTPException):
                await refresh(_fake_request(), RefreshRequest(refresh_token=session_a_tokens.refresh_token), session)

        # Session B, never reused, must also be revoked as a precaution.
        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as caught:
                await refresh(_fake_request(), RefreshRequest(refresh_token=session_b_tokens.refresh_token), session)
        self.assertEqual(caught.exception.status_code, 401)

    async def test_logout_revokes_only_the_presented_session(self) -> None:
        async with self.session_factory() as session:
            session_a_tokens = await self._login(session)
        async with self.session_factory() as session:
            session_b_tokens = await self._login(session)

        async with self.session_factory() as session:
            user = await self._user(session)
            await logout(RefreshRequest(refresh_token=session_a_tokens.refresh_token), user, session)

        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as caught:
                await refresh(_fake_request(), RefreshRequest(refresh_token=session_a_tokens.refresh_token), session)
        self.assertEqual(caught.exception.status_code, 401)

        async with self.session_factory() as session:
            # Session B must be unaffected by logging out session A.
            rotated = await refresh(_fake_request(), RefreshRequest(refresh_token=session_b_tokens.refresh_token), session)
        self.assertTrue(rotated.refresh_token)

    async def test_expired_refresh_jwt_rejected_before_db_lookup(self) -> None:
        now = datetime.now(timezone.utc)
        expired_token = jwt.encode(
            {
                "sub": str(self.user_id),
                "type": "refresh",
                "jti": str(uuid.uuid4()),
                "iat": now - timedelta(days=settings.refresh_token_expire_days, minutes=5),
                "exp": now - timedelta(minutes=1),
            },
            settings.jwt_secret_key,
            algorithm=settings.jwt_algorithm,
        )
        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as caught:
                await refresh(_fake_request(), RefreshRequest(refresh_token=expired_token), session)
        self.assertEqual(caught.exception.status_code, 401)

    async def test_revoked_session_rejected_even_with_valid_signature_and_exp(self) -> None:
        async with self.session_factory() as session:
            tokens = await self._login(session)

        jti = self._jti(tokens.refresh_token)
        async with self.session_factory() as session:
            row = await session.get(RefreshSession, jti)
            row.revoked_at = datetime.now(timezone.utc)
            await session.commit()

        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as caught:
                await refresh(_fake_request(), RefreshRequest(refresh_token=tokens.refresh_token), session)
        self.assertEqual(caught.exception.status_code, 401)

    async def test_legacy_refresh_token_without_jti_is_accepted_once_and_enrolled(self) -> None:
        now = datetime.now(timezone.utc)
        legacy_token = jwt.encode(
            {
                "sub": str(self.user_id),
                "type": "refresh",
                "iat": now,
                "exp": now + timedelta(days=settings.refresh_token_expire_days),
            },
            settings.jwt_secret_key,
            algorithm=settings.jwt_algorithm,
        )
        async with self.session_factory() as session:
            tokens = await refresh(_fake_request(), RefreshRequest(refresh_token=legacy_token), session)

        new_jti = self._jti(tokens.refresh_token)
        async with self.session_factory() as session:
            row = await session.get(RefreshSession, new_jti)
        self.assertIsNotNone(row)
        self.assertIsNone(row.revoked_at)

        async with self.session_factory() as session:
            with self.assertRaises(HTTPException) as caught:
                await refresh(_fake_request(), RefreshRequest(refresh_token=legacy_token), session)
        self.assertEqual(caught.exception.status_code, 401)

        async with self.session_factory() as session:
            rows = (
                await session.execute(
                    select(RefreshSession).where(RefreshSession.user_id == self.user_id)
                )
            ).scalars().all()
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(row.revoked_at is not None for row in rows))

    async def test_stale_concurrent_refresh_cannot_create_two_successors(self) -> None:
        async with self.session_factory() as session:
            tokens = await self._login(session)
        original_jti = self._jti(tokens.refresh_token)

        # Load the same active predecessor into two independent identity maps
        # before either exchange claims it. This deterministically recreates
        # the stale-read interleaving behind simultaneous HTTP requests.
        async with self.session_factory() as first_session, self.session_factory() as second_session:
            self.assertIsNotNone(await first_session.get(RefreshSession, original_jti))
            self.assertIsNotNone(await second_session.get(RefreshSession, original_jti))

            winner = await refresh(
                _fake_request("198.51.100.70"),
                RefreshRequest(refresh_token=tokens.refresh_token),
                first_session,
            )
            with self.assertRaises(HTTPException) as caught:
                await refresh(
                    _fake_request("198.51.100.71"),
                    RefreshRequest(refresh_token=tokens.refresh_token),
                    second_session,
                )
        self.assertEqual(caught.exception.status_code, 401)

        winner_jti = self._jti(winner.refresh_token)
        async with self.session_factory() as session:
            rows = (
                await session.execute(
                    select(RefreshSession).where(RefreshSession.user_id == self.user_id)
                )
            ).scalars().all()
            original = await session.get(RefreshSession, original_jti)
        self.assertEqual(len(rows), 2)
        self.assertEqual(original.replaced_by_id, winner_jti)
        # Existing theft protection remains intact: once the losing exchange
        # proves reuse, the single winner is revoked rather than leaving a
        # potentially stolen successor valid.
        self.assertTrue(all(row.revoked_at is not None for row in rows))


if __name__ == "__main__":
    unittest.main()
