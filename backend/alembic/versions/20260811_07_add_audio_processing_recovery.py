"""add recoverable audio processing state

Revision ID: 20260811_07
Revises: 20260811_06
Create Date: 2026-08-11
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260811_07"
down_revision: Union[str, None] = "20260811_06"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    columns = {column["name"] for column in inspector.get_columns("audio_uploads")}
    additions = {
        "english_transcript",
        "processing_stage",
        "failure_stage",
        "failure_code",
        "processed_at",
    }
    present = columns & additions
    if present and present != additions:
        raise RuntimeError(
            "audio_uploads has a partial processing recovery migration; "
            "review it before retrying"
        )
    if present == additions:
        return

    with op.batch_alter_table("audio_uploads") as batch:
        batch.add_column(sa.Column("english_transcript", sa.Text(), nullable=True))
        batch.add_column(
            sa.Column(
                "processing_stage",
                sa.String(length=32),
                server_default="uploaded",
                nullable=False,
            )
        )
        batch.add_column(sa.Column("failure_stage", sa.String(length=32), nullable=True))
        batch.add_column(sa.Column("failure_code", sa.String(length=64), nullable=True))
        batch.add_column(sa.Column("processed_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("audio_uploads") as batch:
        batch.drop_column("processed_at")
        batch.drop_column("failure_code")
        batch.drop_column("failure_stage")
        batch.drop_column("processing_stage")
        batch.drop_column("english_transcript")
