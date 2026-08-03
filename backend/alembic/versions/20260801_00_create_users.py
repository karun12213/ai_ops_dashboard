"""create or adopt the users table

Revision ID: 20260801_00
Revises:
Create Date: 2026-08-01

This baseline supports both production databases created entirely through
Alembic and development databases that predate migration tracking and were
created with ``Base.metadata.create_all()``. Existing compatible user tables
are adopted in place so account rows and password hashes are never rewritten.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260801_00"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_REQUIRED_USER_COLUMNS = {
    "id",
    "email",
    "full_name",
    "hashed_password",
    "is_active",
    "is_superuser",
    "created_at",
    "updated_at",
}


def _adopt_existing_users_table(inspector: sa.Inspector) -> None:
    columns = {column["name"] for column in inspector.get_columns("users")}
    missing_columns = sorted(_REQUIRED_USER_COLUMNS - columns)
    if missing_columns:
        raise RuntimeError(
            "Existing users table is incompatible with the authentication "
            f"baseline; missing columns: {', '.join(missing_columns)}"
        )

    unique_email = any(
        constraint.get("column_names") == ["email"]
        for constraint in inspector.get_unique_constraints("users")
    ) or any(
        index.get("unique") and index.get("column_names") == ["email"]
        for index in inspector.get_indexes("users")
    )
    if not unique_email:
        raise RuntimeError(
            "Existing users table is incompatible with the authentication "
            "baseline; email must have a single-column unique constraint or index"
        )


def upgrade() -> None:
    """Create the users table or adopt a compatible existing table."""
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if inspector.has_table("users"):
        _adopt_existing_users_table(inspector)
        return

    op.create_table(
        "users",
        sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
        sa.Column("email", sa.String(length=320), nullable=False),
        sa.Column("full_name", sa.String(length=120), nullable=False),
        sa.Column("hashed_password", sa.String(length=255), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("is_superuser", sa.Boolean(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
    )
    op.create_index("ix_users_email", "users", ["email"], unique=True)


def downgrade() -> None:
    """Preserve user identities when removing baseline version tracking."""
    # Deliberately non-destructive. This revision may have adopted a users
    # table containing accounts created before Alembic tracking existed. A
    # downgrade must never guess that those identities are safe to delete.
    pass
