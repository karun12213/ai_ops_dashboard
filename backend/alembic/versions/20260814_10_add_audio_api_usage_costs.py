"""add per-upload provider usage and estimated costs

Revision ID: 20260814_10
Revises: 20260811_09
Create Date: 2026-08-14
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260814_10"
down_revision: Union[str, None] = "20260811_09"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


_COLUMNS = {
    "sarvam_model",
    "sarvam_request_id",
    "sarvam_job_id",
    "sarvam_estimated_cost_inr",
    "openai_input_tokens",
    "openai_cached_input_tokens",
    "openai_output_tokens",
    "openai_total_tokens",
    "openai_model",
    "openai_request_id",
    "openai_request_ids",
    "openai_estimated_cost_usd",
    "total_estimated_cost",
}


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    columns = {column["name"] for column in inspector.get_columns("audio_uploads")}
    present = columns & _COLUMNS
    if present and present != _COLUMNS:
        raise RuntimeError(
            "audio_uploads has a partial API usage migration; review it before retrying"
        )
    if present == _COLUMNS:
        return

    with op.batch_alter_table("audio_uploads") as batch:
        batch.add_column(sa.Column("sarvam_model", sa.String(64), nullable=True))
        batch.add_column(sa.Column("sarvam_request_id", sa.String(128), nullable=True))
        batch.add_column(sa.Column("sarvam_job_id", sa.String(128), nullable=True))
        batch.add_column(
            sa.Column("sarvam_estimated_cost_inr", sa.Numeric(18, 8), nullable=True)
        )
        batch.add_column(sa.Column("openai_input_tokens", sa.BigInteger(), nullable=True))
        batch.add_column(
            sa.Column("openai_cached_input_tokens", sa.BigInteger(), nullable=True)
        )
        batch.add_column(sa.Column("openai_output_tokens", sa.BigInteger(), nullable=True))
        batch.add_column(sa.Column("openai_total_tokens", sa.BigInteger(), nullable=True))
        batch.add_column(sa.Column("openai_model", sa.String(128), nullable=True))
        batch.add_column(sa.Column("openai_request_id", sa.String(128), nullable=True))
        batch.add_column(sa.Column("openai_request_ids", sa.JSON(), nullable=True))
        batch.add_column(
            sa.Column("openai_estimated_cost_usd", sa.Numeric(18, 8), nullable=True)
        )
        batch.add_column(sa.Column("total_estimated_cost", sa.JSON(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("audio_uploads") as batch:
        for column in (
            "total_estimated_cost",
            "openai_estimated_cost_usd",
            "openai_request_ids",
            "openai_request_id",
            "openai_model",
            "openai_total_tokens",
            "openai_output_tokens",
            "openai_cached_input_tokens",
            "openai_input_tokens",
            "sarvam_estimated_cost_inr",
            "sarvam_job_id",
            "sarvam_request_id",
            "sarvam_model",
        ):
            batch.drop_column(column)
