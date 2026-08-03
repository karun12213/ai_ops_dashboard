import hashlib
import uuid
from datetime import datetime, timedelta, timezone
from typing import Annotated, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.auth import LoginRequest, RefreshRequest, RegisterRequest, TokenResponse
from backend.api.schemas.user import UserResponse
from backend.auth.dependencies import CurrentUser
from backend.auth.rate_limit import default_lockout, enforce_ip_rate_limit, enforce_login_lockout
from backend.auth.security import (
    TokenValidationError,
    create_access_token,
    create_refresh_token,
    decode_token,
)
from backend.database.session import get_db
from backend.models.refresh_session import RefreshSession
from backend.models.user import User
from backend.services.user_service import UserService
from backend.utils.config import get_settings

router = APIRouter(prefix="/auth", tags=["authentication"])
settings = get_settings()


class _RefreshTokenReuseError(RuntimeError):
    """Raised when a refresh token loses or repeats a one-time exchange."""


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _refresh_token_response(user: User, refresh_token: str) -> TokenResponse:
    return TokenResponse(
        access_token=create_access_token(str(user.id)),
        refresh_token=refresh_token,
        expires_in=settings.access_token_expire_minutes * 60,
    )


def _new_refresh_session(user: User, now: datetime) -> tuple[str, RefreshSession]:
    session_id = uuid.uuid4()
    refresh_token = create_refresh_token(str(user.id), session_id)
    return refresh_token, RefreshSession(
        id=session_id,
        user_id=user.id,
        token_hash=_hash_token(refresh_token),
        issued_at=now,
        expires_at=now + timedelta(days=settings.refresh_token_expire_days),
    )


async def _revoke_active_sessions(
    session: AsyncSession, user_id: uuid.UUID, *, now: Optional[datetime] = None
) -> None:
    await session.execute(
        update(RefreshSession)
        .where(RefreshSession.user_id == user_id, RefreshSession.revoked_at.is_(None))
        .values(revoked_at=now or datetime.now(timezone.utc))
        .execution_options(synchronize_session=False)
    )


async def _issue_tokens(
    session: AsyncSession,
    user: User,
    *,
    supersedes: Optional[RefreshSession] = None,
) -> TokenResponse:
    now = datetime.now(timezone.utc)
    refresh_token, new_refresh_session = _new_refresh_session(user, now)
    session.add(new_refresh_session)
    if supersedes is not None:
        # Insert the successor first so the self-referential foreign key can be
        # set by the atomic claim below. Only one transaction can change an
        # active predecessor to revoked; a stale concurrent exchange receives
        # rowcount=0 and its uncommitted successor is rolled back.
        await session.flush()
        result = await session.execute(
            update(RefreshSession)
            .where(
                RefreshSession.id == supersedes.id,
                RefreshSession.user_id == user.id,
                RefreshSession.token_hash == supersedes.token_hash,
                RefreshSession.revoked_at.is_(None),
            )
            .values(
                revoked_at=now,
                replaced_by_id=new_refresh_session.id,
            )
            .execution_options(synchronize_session=False)
        )
        if result.rowcount != 1:
            await session.rollback()
            # Treat a simultaneous second claim as token reuse. This preserves
            # the existing theft response: invalidate all active sessions in
            # the token family rather than leaving a possibly stolen winner.
            await _revoke_active_sessions(session, user.id, now=now)
            await session.commit()
            raise _RefreshTokenReuseError
    await session.commit()
    return _refresh_token_response(user, refresh_token)


async def _issue_tokens_from_legacy_token(
    session: AsyncSession,
    user: User,
    legacy_token: str,
    token_payload: dict,
) -> TokenResponse:
    """Atomically consume an older refresh JWT that has no jti claim.

    Its hash receives a deterministic database identity and a revoked session
    row linked to the new successor. The unique token hash/primary key makes
    the claim one-time even when two backend requests race.
    """
    token_hash = _hash_token(legacy_token)
    existing = await session.scalar(
        select(RefreshSession).where(RefreshSession.token_hash == token_hash)
    )
    if existing is not None:
        if existing.replaced_by_id is not None:
            await _revoke_active_sessions(session, user.id)
            await session.commit()
        raise _RefreshTokenReuseError

    now = datetime.now(timezone.utc)
    refresh_token, new_refresh_session = _new_refresh_session(user, now)
    legacy_session_id = uuid.uuid5(uuid.NAMESPACE_URL, f"legacy-refresh:{token_hash}")
    try:
        session.add(new_refresh_session)
        await session.flush()
        session.add(
            RefreshSession(
                id=legacy_session_id,
                user_id=user.id,
                token_hash=token_hash,
                issued_at=now,
                expires_at=datetime.fromtimestamp(float(token_payload["exp"]), tz=timezone.utc),
                revoked_at=now,
                replaced_by_id=new_refresh_session.id,
            )
        )
        await session.commit()
    except (IntegrityError, KeyError, TypeError, ValueError) as error:
        await session.rollback()
        if isinstance(error, IntegrityError):
            # A competing request may have committed the deterministic claim
            # while this transaction was in progress.
            claimed = await session.scalar(
                select(RefreshSession).where(RefreshSession.token_hash == token_hash)
            )
            if claimed is not None and claimed.replaced_by_id is not None:
                await _revoke_active_sessions(session, user.id)
                await session.commit()
        raise _RefreshTokenReuseError from error
    return _refresh_token_response(user, refresh_token)


@router.post("/register", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
async def register(
    request: Request,
    payload: RegisterRequest,
    session: Annotated[AsyncSession, Depends(get_db)],
) -> UserResponse:
    await enforce_ip_rate_limit(
        request,
        scope="register",
        limit=settings.rate_limit_register_ip_max,
        window_seconds=settings.rate_limit_register_ip_window_seconds,
    )
    service = UserService(session)
    if await service.get_by_email(payload.email) is not None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email is already registered")
    try:
        user = await service.create(payload.email, payload.full_name, payload.password)
    except IntegrityError:
        await session.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email is already registered")
    return UserResponse.model_validate(user)


@router.post("/login", response_model=TokenResponse)
async def login(
    request: Request,
    payload: LoginRequest,
    session: Annotated[AsyncSession, Depends(get_db)],
) -> TokenResponse:
    await enforce_ip_rate_limit(
        request,
        scope="login",
        limit=settings.rate_limit_login_ip_max,
        window_seconds=settings.rate_limit_login_ip_window_seconds,
    )
    lockout_key = payload.email.strip().lower()
    await enforce_login_lockout(
        lockout_key, lockout_duration_seconds=settings.rate_limit_login_lockout_duration_seconds
    )

    user = await UserService(session).authenticate(payload.email, payload.password)
    if user is None:
        await default_lockout.register_failure(
            lockout_key,
            threshold=settings.rate_limit_login_lockout_threshold,
            window_seconds=settings.rate_limit_login_lockout_window_seconds,
            lockout_duration_seconds=settings.rate_limit_login_lockout_duration_seconds,
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if not user.is_active:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Account is disabled")
    await default_lockout.clear(lockout_key)
    return await _issue_tokens(session, user)


@router.post("/refresh", response_model=TokenResponse)
async def refresh(
    request: Request,
    payload: RefreshRequest,
    session: Annotated[AsyncSession, Depends(get_db)],
) -> TokenResponse:
    await enforce_ip_rate_limit(
        request,
        scope="refresh",
        limit=settings.rate_limit_refresh_ip_max,
        window_seconds=settings.rate_limit_refresh_ip_window_seconds,
    )
    invalid = HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")
    try:
        token_payload = decode_token(payload.refresh_token, "refresh")
        user_id = uuid.UUID(str(token_payload["sub"]))
    except (TokenValidationError, ValueError, KeyError):
        raise invalid

    user = await UserService(session).get_by_id(user_id)
    if user is None or not user.is_active:
        raise invalid

    jti = token_payload.get("jti")
    if jti is None:
        # Legacy refresh token issued before session tracking existed. Persist
        # its hash as a revoked predecessor so it can be exchanged exactly once.
        try:
            return await _issue_tokens_from_legacy_token(
                session, user, payload.refresh_token, token_payload
            )
        except _RefreshTokenReuseError:
            raise invalid

    try:
        session_id = uuid.UUID(str(jti))
    except ValueError:
        raise invalid

    refresh_session = await session.get(RefreshSession, session_id)
    if (
        refresh_session is None
        or refresh_session.user_id != user.id
        or refresh_session.token_hash != _hash_token(payload.refresh_token)
    ):
        raise invalid

    if refresh_session.revoked_at is not None:
        if refresh_session.replaced_by_id is not None:
            # Reuse of a token that was already exchanged for a newer one via
            # rotation is a theft signal: revoke every other active session for
            # this user. A token revoked by an ordinary logout (no successor)
            # is not suspicious and must not cascade to other sessions.
            await _revoke_active_sessions(session, user.id)
            await session.commit()
        raise invalid

    try:
        return await _issue_tokens(session, user, supersedes=refresh_session)
    except _RefreshTokenReuseError:
        raise invalid


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(
    payload: RefreshRequest,
    current_user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    """Revoke the caller's presented refresh session when it is valid."""
    try:
        token_payload = decode_token(payload.refresh_token, "refresh")
        session_id = uuid.UUID(str(token_payload.get("jti")))
    except (TokenValidationError, ValueError, TypeError):
        return
    refresh_session = await session.get(RefreshSession, session_id)
    if refresh_session is not None and refresh_session.user_id == current_user.id:
        refresh_session.revoked_at = datetime.now(timezone.utc)
        await session.commit()


@router.get("/me", response_model=UserResponse)
async def me(current_user: CurrentUser) -> UserResponse:
    return UserResponse.model_validate(current_user)
