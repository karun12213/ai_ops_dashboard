import time
from asyncio import Lock
from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Deque, Dict, Optional

from fastapi import HTTPException, Request, status


def _raise_throttled(retry_after: float) -> None:
    raise HTTPException(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        detail="Too many attempts. Please try again later.",
        headers={"Retry-After": str(max(1, int(retry_after) + 1))},
    )


class InMemoryRateLimiter:
    """Process-local sliding-window request counter.

    Suitable for a single-instance deployment. If the backend is ever scaled
    to multiple replicas or worker processes, counts are not shared across
    them and the effective limit becomes `limit * instance_count` — swap this
    for a shared-store implementation (e.g. Redis) behind the same `hit()`
    signature if that becomes necessary.
    """

    def __init__(self) -> None:
        self._hits: Dict[str, Deque[float]] = defaultdict(deque)
        self._lock = Lock()

    async def hit(self, key: str, *, limit: int, window_seconds: float) -> Optional[float]:
        now = time.monotonic()
        async with self._lock:
            timestamps = self._hits[key]
            cutoff = now - window_seconds
            while timestamps and timestamps[0] < cutoff:
                timestamps.popleft()
            if len(timestamps) >= limit:
                return timestamps[0] + window_seconds - now
            timestamps.append(now)
            return None

    async def reset(self) -> None:
        async with self._lock:
            self._hits.clear()


@dataclass
class _LockoutState:
    failure_count: int
    first_failure_at: float
    locked_until: Optional[float]


class FailureLockout:
    """Process-local, self-expiring lockout after repeated failures for a key.

    Never a permanent ban: once `lockout_duration_seconds` elapses after a
    lockout was triggered, the key is fully cleared and starts a fresh
    failure count on its next attempt.
    """

    def __init__(self) -> None:
        self._state: Dict[str, _LockoutState] = {}
        self._lock = Lock()

    async def is_locked(self, key: str, *, lockout_duration_seconds: float) -> Optional[float]:
        now = time.monotonic()
        async with self._lock:
            state = self._state.get(key)
            if state is None or state.locked_until is None:
                return None
            if state.locked_until <= now:
                del self._state[key]
                return None
            return state.locked_until - now

    async def register_failure(
        self,
        key: str,
        *,
        threshold: int,
        window_seconds: float,
        lockout_duration_seconds: float,
    ) -> Optional[float]:
        now = time.monotonic()
        async with self._lock:
            state = self._state.get(key)
            if state is None or now - state.first_failure_at > window_seconds:
                state = _LockoutState(failure_count=0, first_failure_at=now, locked_until=None)
                self._state[key] = state
            state.failure_count += 1
            if state.failure_count >= threshold:
                state.locked_until = now + lockout_duration_seconds
                return lockout_duration_seconds
            return None

    async def clear(self, key: str) -> None:
        async with self._lock:
            self._state.pop(key, None)

    async def reset(self) -> None:
        async with self._lock:
            self._state.clear()


default_limiter = InMemoryRateLimiter()
default_lockout = FailureLockout()


async def reset_rate_limits() -> None:
    """Clear all counters and lockouts. Used between test cases."""
    await default_limiter.reset()
    await default_lockout.reset()


async def enforce_ip_rate_limit(
    request: Request, *, scope: str, limit: int, window_seconds: float
) -> None:
    """Consume one request from an endpoint's per-source-IP budget."""
    client_ip = request.client.host if request.client else "unknown"
    retry_after = await default_limiter.hit(
        f"{scope}:ip:{client_ip}", limit=limit, window_seconds=window_seconds
    )
    if retry_after is not None:
        _raise_throttled(retry_after)


async def enforce_login_lockout(email: str, *, lockout_duration_seconds: float) -> None:
    """Raise 429 if this email is currently under a temporary lockout.

    Keyed by the submitted email itself regardless of whether that account
    exists, so the check cannot be used to enumerate accounts: a real email
    and a made-up one are indistinguishable here.
    """
    retry_after = await default_lockout.is_locked(
        email.strip().lower(), lockout_duration_seconds=lockout_duration_seconds
    )
    if retry_after is not None:
        _raise_throttled(retry_after)
