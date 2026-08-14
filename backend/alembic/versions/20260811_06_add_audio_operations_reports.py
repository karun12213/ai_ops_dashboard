"""persist tenant-scoped AI audio reports

Revision ID: 20260811_06
Revises: 20260803_05
Create Date: 2026-08-11

Existing audio rows remain explicitly unassigned because a migration cannot
safely guess their workspace or location. New uploads always populate both.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260811_06"
down_revision: Union[str, None] = "20260803_05"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    audio_columns = {column["name"] for column in inspector.get_columns("audio_uploads")}
    new_audio_columns = {"workspace_id", "location_id", "language_code"}
    present_audio_columns = audio_columns & new_audio_columns
    if present_audio_columns and present_audio_columns != new_audio_columns:
        raise RuntimeError(
            "audio_uploads has a partial AI report migration; review it before retrying"
        )
    if not present_audio_columns:
        with op.batch_alter_table("audio_uploads") as batch:
            batch.add_column(sa.Column("workspace_id", sa.Uuid(as_uuid=True), nullable=True))
            batch.add_column(sa.Column("location_id", sa.Uuid(as_uuid=True), nullable=True))
            batch.add_column(sa.Column("language_code", sa.String(length=12), nullable=True))
            batch.create_foreign_key(
                "fk_audio_uploads_workspace_id_workspaces",
                "workspaces",
                ["workspace_id"],
                ["id"],
                ondelete="CASCADE",
            )
            batch.create_foreign_key(
                "fk_audio_uploads_location_id_report_locations",
                "report_locations",
                ["location_id"],
                ["id"],
                ondelete="CASCADE",
            )
            batch.create_index("ix_audio_uploads_workspace_id", ["workspace_id"])
            batch.create_index("ix_audio_uploads_location_id", ["location_id"])
            batch.create_index(
                "ix_audio_uploads_location_created_at", ["location_id", "created_at"]
            )

    inspector = sa.inspect(op.get_bind())
    activity_columns = {
        column["name"] for column in inspector.get_columns("dashboard_activities")
    }
    if "audio_upload_id" not in activity_columns:
        with op.batch_alter_table("dashboard_activities") as batch:
            batch.add_column(sa.Column("audio_upload_id", sa.Uuid(as_uuid=True), nullable=True))
            batch.create_foreign_key(
                "fk_dashboard_activities_audio_upload_id_audio_uploads",
                "audio_uploads",
                ["audio_upload_id"],
                ["id"],
                ondelete="CASCADE",
            )
            batch.create_unique_constraint(
                "uq_dashboard_activities_audio_upload_id", ["audio_upload_id"]
            )

    inspector = sa.inspect(op.get_bind())
    if "audio_operations_reports" in set(inspector.get_table_names()):
        required_report_columns = {
            "id",
            "upload_id",
            "owner_id",
            "workspace_id",
            "location_id",
            "transcript",
            "summary",
            "category",
            "severity",
            "requires_attention",
            "recommended_action",
            "source",
            "processed_at",
        }
        report_columns = {
            column["name"]
            for column in inspector.get_columns("audio_operations_reports")
        }
        missing = required_report_columns - report_columns
        if missing:
            raise RuntimeError(
                "Existing audio_operations_reports table is incompatible; missing: "
                + ", ".join(sorted(missing))
            )
        return

    op.create_table(
        "audio_operations_reports",
        sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
        sa.Column(
            "upload_id",
            sa.Uuid(as_uuid=True),
            sa.ForeignKey("audio_uploads.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "owner_id",
            sa.Uuid(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "workspace_id",
            sa.Uuid(as_uuid=True),
            sa.ForeignKey("workspaces.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "location_id",
            sa.Uuid(as_uuid=True),
            sa.ForeignKey("report_locations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("transcript", sa.Text(), nullable=False),
        sa.Column("summary", sa.Text(), nullable=False),
        sa.Column("category", sa.String(length=40), nullable=False),
        sa.Column("severity", sa.String(length=16), nullable=False),
        sa.Column("requires_attention", sa.Boolean(), nullable=False),
        sa.Column("recommended_action", sa.Text(), nullable=False),
        sa.Column(
            "source",
            sa.String(length=64),
            server_default="AI Audio Monitor",
            nullable=False,
        ),
        sa.Column(
            "processed_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.CheckConstraint(
            "category IN ('operations', 'staff', 'inventory', 'customer', 'safety', 'other')",
            name="ck_audio_operations_reports_category",
        ),
        sa.CheckConstraint(
            "severity IN ('low', 'medium', 'high', 'critical')",
            name="ck_audio_operations_reports_severity",
        ),
        sa.UniqueConstraint("upload_id", name="uq_audio_operations_reports_upload_id"),
    )
    op.create_index(
        "ix_audio_operations_reports_owner_id",
        "audio_operations_reports",
        ["owner_id"],
    )
    op.create_index(
        "ix_audio_operations_reports_workspace_processed",
        "audio_operations_reports",
        ["workspace_id", "processed_at"],
    )
    op.create_index(
        "ix_audio_operations_reports_location_processed",
        "audio_operations_reports",
        ["location_id", "processed_at"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_audio_operations_reports_location_processed",
        table_name="audio_operations_reports",
    )
    op.drop_index(
        "ix_audio_operations_reports_workspace_processed",
        table_name="audio_operations_reports",
    )
    op.drop_index(
        "ix_audio_operations_reports_owner_id",
        table_name="audio_operations_reports",
    )
    op.drop_table("audio_operations_reports")

    with op.batch_alter_table("dashboard_activities") as batch:
        batch.drop_constraint(
            "uq_dashboard_activities_audio_upload_id", type_="unique"
        )
        batch.drop_constraint(
            "fk_dashboard_activities_audio_upload_id_audio_uploads",
            type_="foreignkey",
        )
        batch.drop_column("audio_upload_id")

    with op.batch_alter_table("audio_uploads") as batch:
        batch.drop_index("ix_audio_uploads_location_created_at")
        batch.drop_index("ix_audio_uploads_location_id")
        batch.drop_index("ix_audio_uploads_workspace_id")
        batch.drop_constraint(
            "fk_audio_uploads_location_id_report_locations", type_="foreignkey"
        )
        batch.drop_constraint(
            "fk_audio_uploads_workspace_id_workspaces", type_="foreignkey"
        )
        batch.drop_column("language_code")
        batch.drop_column("location_id")
        batch.drop_column("workspace_id")
