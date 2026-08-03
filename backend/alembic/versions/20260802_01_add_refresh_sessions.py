"""add refresh_sessions table

Revision ID: 20260802_01
Revises: 20260801_00
Create Date: 2026-08-02

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260802_01"
down_revision: Union[str, None] = "20260801_00"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_REQUIRED_REFRESH_SESSION_COLUMNS = {
    "id",
    "user_id",
    "token_hash",
    "issued_at",
    "expires_at",
    "revoked_at",
    "replaced_by_id",
}


def _adopt_existing_refresh_sessions_table(inspector: sa.Inspector) -> None:
    columns = {column["name"] for column in inspector.get_columns("refresh_sessions")}
    missing_columns = sorted(_REQUIRED_REFRESH_SESSION_COLUMNS - columns)
    if missing_columns:
        raise RuntimeError(
            "Existing refresh_sessions table is incompatible with the authentication "
            f"migration; missing columns: {', '.join(missing_columns)}"
        )

    unique_token_hash = any(
        constraint.get("column_names") == ["token_hash"]
        for constraint in inspector.get_unique_constraints("refresh_sessions")
    ) or any(
        index.get("unique") and index.get("column_names") == ["token_hash"]
        for index in inspector.get_indexes("refresh_sessions")
    )
    if not unique_token_hash:
        raise RuntimeError(
            "Existing refresh_sessions table is incompatible with the authentication "
            "migration; token_hash must have a single-column unique constraint or index"
        )


def upgrade() -> None:
    """Create refresh-session tracking or adopt a compatible table."""
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if inspector.has_table("refresh_sessions"):
        _adopt_existing_refresh_sessions_table(inspector)
        if not any(
            index.get("column_names") == ["user_id"]
            for index in inspector.get_indexes("refresh_sessions")
        ):
            op.create_index("ix_refresh_sessions_user_id", "refresh_sessions", ["user_id"])
        return

    op.create_table(
        "refresh_sessions",
        sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
        sa.Column(
            "user_id",
            sa.Uuid(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("token_hash", sa.String(length=64), nullable=False, unique=True),
        sa.Column("issued_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "replaced_by_id",
            sa.Uuid(as_uuid=True),
            sa.ForeignKey("refresh_sessions.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    op.create_index("ix_refresh_sessions_user_id", "refresh_sessions", ["user_id"])


def downgrade() -> None:
    """Remove refresh-session tracking while leaving users intact."""
    op.drop_index("ix_refresh_sessions_user_id", table_name="refresh_sessions")
    op.drop_table("refresh_sessions")
