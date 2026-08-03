"""add authenticated audio upload metadata

Revision ID: 20260803_04
Revises: 20260803_03
Create Date: 2026-08-03

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260803_04"
down_revision: Union[str, None] = "20260803_03"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_REQUIRED_COLUMNS = {
    "id",
    "owner_id",
    "original_filename",
    "storage_key",
    "media_type",
    "extension",
    "size_bytes",
    "sha256",
    "status",
    "scan_status",
    "created_at",
    "updated_at",
}


def _has_index(inspector: sa.Inspector, columns: list[str]) -> bool:
    return any(
        index.get("column_names") == columns
        for index in inspector.get_indexes("audio_uploads")
    )


def _has_unique_key(inspector: sa.Inspector, columns: list[str]) -> bool:
    return any(
        constraint.get("column_names") == columns
        for constraint in inspector.get_unique_constraints("audio_uploads")
    ) or any(
        index.get("unique") and index.get("column_names") == columns
        for index in inspector.get_indexes("audio_uploads")
    )


def _create_audio_uploads() -> None:
    op.create_table(
        "audio_uploads",
        sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
        sa.Column(
            "owner_id",
            sa.Uuid(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("original_filename", sa.String(length=255), nullable=False),
        sa.Column("storage_key", sa.String(length=512), nullable=False),
        sa.Column("media_type", sa.String(length=64), nullable=False),
        sa.Column("extension", sa.String(length=8), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False),
        sa.Column("sha256", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=24), nullable=False),
        sa.Column("scan_status", sa.String(length=24), nullable=False),
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
        sa.CheckConstraint(
            "size_bytes > 0 AND size_bytes <= 104857600",
            name="ck_audio_uploads_size_bytes",
        ),
        sa.CheckConstraint(
            "extension IN ('mp3', 'wav', 'm4a', 'aac', 'ogg')",
            name="ck_audio_uploads_extension",
        ),
        sa.CheckConstraint(
            "status IN ('processing', 'ready', 'failed', 'quarantined')",
            name="ck_audio_uploads_status",
        ),
        sa.CheckConstraint(
            "scan_status IN ('not_configured', 'clean', 'infected', 'error')",
            name="ck_audio_uploads_scan_status",
        ),
        sa.CheckConstraint(
            "length(sha256) = 64",
            name="ck_audio_uploads_sha256_length",
        ),
        sa.UniqueConstraint("storage_key", name="uq_audio_uploads_storage_key"),
        sa.UniqueConstraint(
            "owner_id",
            "sha256",
            name="uq_audio_uploads_owner_sha256",
        ),
    )
    op.create_index(
        "ix_audio_uploads_owner_created_at",
        "audio_uploads",
        ["owner_id", "created_at"],
    )


def upgrade() -> None:
    """Create the audio metadata table or adopt a compatible development table."""
    inspector = sa.inspect(op.get_bind())
    if "audio_uploads" not in set(inspector.get_table_names()):
        _create_audio_uploads()
        return

    columns = {column["name"] for column in inspector.get_columns("audio_uploads")}
    missing_columns = sorted(_REQUIRED_COLUMNS - columns)
    if missing_columns:
        raise RuntimeError(
            "Existing audio_uploads table is incompatible with the Audio Upload migration; "
            f"missing columns: {', '.join(missing_columns)}"
        )
    if not _has_unique_key(inspector, ["storage_key"]):
        raise RuntimeError(
            "Existing audio_uploads table is incompatible with the Audio Upload migration; "
            "storage_key must be unique"
        )
    if not _has_unique_key(inspector, ["owner_id", "sha256"]):
        raise RuntimeError(
            "Existing audio_uploads table is incompatible with the Audio Upload migration; "
            "owner_id and sha256 must be unique together"
        )
    if not _has_index(inspector, ["owner_id", "created_at"]):
        op.create_index(
            "ix_audio_uploads_owner_created_at",
            "audio_uploads",
            ["owner_id", "created_at"],
        )


def downgrade() -> None:
    op.drop_index("ix_audio_uploads_owner_created_at", table_name="audio_uploads")
    op.drop_table("audio_uploads")
