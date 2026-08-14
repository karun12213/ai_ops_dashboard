"""backfill audio processing state from persisted reports

Revision ID: 20260811_08
Revises: 20260811_07
Create Date: 2026-08-11
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260811_08"
down_revision: Union[str, None] = "20260811_07"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    audio = sa.table(
        "audio_uploads",
        sa.column("id", sa.Uuid(as_uuid=True)),
        sa.column("status", sa.String()),
        sa.column("processing_stage", sa.String()),
        sa.column("failure_stage", sa.String()),
        sa.column("failure_code", sa.String()),
        sa.column("english_transcript", sa.Text()),
        sa.column("processed_at", sa.DateTime(timezone=True)),
    )
    reports = sa.table(
        "audio_operations_reports",
        sa.column("upload_id", sa.Uuid(as_uuid=True)),
        sa.column("transcript", sa.Text()),
        sa.column("processed_at", sa.DateTime(timezone=True)),
    )
    report_exists = sa.exists(
        sa.select(reports.c.upload_id).where(reports.c.upload_id == audio.c.id)
    )
    op.execute(
        audio.update()
        .where(report_exists)
        .values(
            status="ready",
            processing_stage="completed",
            failure_stage=None,
            failure_code=None,
            english_transcript=sa.select(reports.c.transcript)
            .where(reports.c.upload_id == audio.c.id)
            .scalar_subquery(),
            processed_at=sa.select(reports.c.processed_at)
            .where(reports.c.upload_id == audio.c.id)
            .scalar_subquery(),
        )
    )
    op.execute(
        audio.update()
        .where(audio.c.status == "ready", ~report_exists)
        .values(
            status="failed",
            processing_stage="failed",
            failure_stage="legacy_upload",
            failure_code="legacy_incomplete",
        )
    )


def downgrade() -> None:
    # The recovered transcript and timestamps are real persisted data and are
    # intentionally retained when only the data-backfill revision is rolled back.
    pass
