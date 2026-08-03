import secrets
import uuid
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.auth.security import hash_password, verify_password
from backend.models.user import User

# Verified against a real password on every login attempt, including ones for
# an email that doesn't exist, so that account existence cannot be inferred
# from response timing (a nonexistent email would otherwise skip the
# comparatively expensive Argon2 check entirely).
_DUMMY_PASSWORD_HASH = hash_password(secrets.token_urlsafe(32))


class UserService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get_by_id(self, user_id: uuid.UUID) -> Optional[User]:
        return await self.session.get(User, user_id)

    async def get_by_email(self, email: str) -> Optional[User]:
        result = await self.session.execute(
            select(User).where(User.email == email.strip().lower())
        )
        return result.scalar_one_or_none()

    async def create(self, email: str, full_name: str, password: str) -> User:
        user = User(
            email=email.strip().lower(),
            full_name=full_name.strip(),
            hashed_password=hash_password(password),
        )
        self.session.add(user)
        await self.session.commit()
        await self.session.refresh(user)
        return user

    async def authenticate(self, email: str, password: str) -> Optional[User]:
        user = await self.get_by_email(email)
        hashed_password = user.hashed_password if user is not None else _DUMMY_PASSWORD_HASH
        password_is_valid = verify_password(password, hashed_password)
        if user is None or not password_is_valid:
            return None
        return user
