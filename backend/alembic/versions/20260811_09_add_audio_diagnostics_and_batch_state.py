"""add audio diagnostics and restart-safe batch state

Revision ID: 20260811_09
Revises: 20260811_08
Create Date: 2026-08-11
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260811_09"
down_revision: Union[str, None] = "20260811_08"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


_COLUMNS = {
    "detected_language_code",
    "audio_container",
    "audio_codec",
    "audio_duration_seconds",
    "audio_sample_rate",
    "audio_channels",
    "transcription_strategy",
    "provider_job_id",
    "provider_job_state",
    "failure_message",
    "retryable",
}


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    columns = {column["name"] for column in inspector.get_columns("audio_uploads")}
    present = columns & _COLUMNS
    if present and present != _COLUMNS:
        raise RuntimeError(
            "audio_uploads has a partial diagnostics migration; review it before retrying"
        )
    if present != _COLUMNS:
        with op.batch_alter_table("audio_uploads") as batch:
            batch.add_column(sa.Column("detected_language_code", sa.String(12), nullable=True))
            batch.add_column(sa.Column("audio_container", sa.String(64), nullable=True))
            batch.add_column(sa.Column("audio_codec", sa.String(64), nullable=True))
            batch.add_column(sa.Column("audio_duration_seconds", sa.Float(), nullable=True))
            batch.add_column(sa.Column("audio_sample_rate", sa.Integer(), nullable=True))
            batch.add_column(sa.Column("audio_channels", sa.Integer(), nullable=True))
            batch.add_column(sa.Column("transcription_strategy", sa.String(32), nullable=True))
            batch.add_column(sa.Column("provider_job_id", sa.String(128), nullable=True))
            batch.add_column(sa.Column("provider_job_state", sa.String(32), nullable=True))
            batch.add_column(sa.Column("failure_message", sa.String(255), nullable=True))
            batch.add_column(
                sa.Column(
                    "retryable",
                    sa.Boolean(),
                    server_default=sa.true(),
                    nullable=False,
                )
            )

    inspector = sa.inspect(op.get_bind())
    checks = {item["name"] for item in inspector.get_check_constraints("audio_uploads")}
    with op.batch_alter_table("audio_uploads") as batch:
        if "ck_audio_uploads_extension" in checks:
            batch.drop_constraint("ck_audio_uploads_extension", type_="check")
        batch.create_check_constraint(
            "ck_audio_uploads_extension",
            "extension IN ('mp3', 'wav', 'm4a', 'aac', 'ogg', 'opus', 'mp4')",
        )

    bind = op.get_bind()
    bind.execute(
        sa.text(
            "UPDATE audio_uploads "
            "SET detected_language_code = language_code, retryable = false "
            "WHERE status = 'ready'"
        )
    )

    activity_columns = {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("dashboard_activities")
    }
    if "severity" not in activity_columns:
        with op.batch_alter_table("dashboard_activities") as batch:
            batch.add_column(sa.Column("severity", sa.String(16), nullable=True))


def downgrade() -> None:
    activity_columns = {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("dashboard_activities")
    }
    if "severity" in activity_columns:
        with op.batch_alter_table("dashboard_activities") as batch:
            batch.drop_column("severity")
    with op.batch_alter_table("audio_uploads") as batch:
        batch.drop_constraint("ck_audio_uploads_extension", type_="check")
        batch.create_check_constraint(
            "ck_audio_uploads_extension",
            "extension IN ('mp3', 'wav', 'm4a', 'aac', 'ogg')",
        )
        for column in (
            "retryable",
            "failure_message",
            "provider_job_state",
            "provider_job_id",
            "transcription_strategy",
            "audio_channels",
            "audio_sample_rate",
            "audio_duration_seconds",
            "audio_codec",
            "audio_container",
            "detected_language_code",
        ):
            batch.drop_column(column)
