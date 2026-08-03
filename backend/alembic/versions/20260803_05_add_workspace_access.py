"""add workspace and location access boundaries

Revision ID: 20260803_05
Revises: 20260803_04
Create Date: 2026-08-03

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260803_05"
down_revision: Union[str, None] = "20260803_04"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _columns(inspector: sa.Inspector, table_name: str) -> set[str]:
    return {column["name"] for column in inspector.get_columns(table_name)}


def _has_index(inspector: sa.Inspector, table_name: str, columns: list[str]) -> bool:
    return any(
        index.get("column_names") == columns
        for index in inspector.get_indexes(table_name)
    )


def _has_unique_key(inspector: sa.Inspector, table_name: str, columns: list[str]) -> bool:
    return any(
        constraint.get("column_names") == columns
        for constraint in inspector.get_unique_constraints(table_name)
    ) or any(
        index.get("unique") and index.get("column_names") == columns
        for index in inspector.get_indexes(table_name)
    )


def _unique_constraint_name(
    inspector: sa.Inspector,
    table_name: str,
    columns: list[str],
) -> str | None:
    for constraint in inspector.get_unique_constraints(table_name):
        if constraint.get("column_names") == columns:
            return constraint.get("name")
    return None


def _create_workspace_tables(existing_tables: set[str]) -> None:
    if "workspaces" not in existing_tables:
        op.create_table(
            "workspaces",
            sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
            sa.Column("name", sa.String(length=120), nullable=False),
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

    if "workspace_memberships" not in existing_tables:
        op.create_table(
            "workspace_memberships",
            sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
            sa.Column(
                "workspace_id",
                sa.Uuid(as_uuid=True),
                sa.ForeignKey("workspaces.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "user_id",
                sa.Uuid(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column("role", sa.String(length=16), nullable=False),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                server_default=sa.func.now(),
                nullable=False,
            ),
            sa.CheckConstraint(
                "role IN ('owner', 'member')",
                name="ck_workspace_memberships_role",
            ),
            sa.UniqueConstraint(
                "workspace_id",
                "user_id",
                name="uq_workspace_memberships_workspace_user",
            ),
        )
        op.create_index(
            "ix_workspace_memberships_user_workspace",
            "workspace_memberships",
            ["user_id", "workspace_id"],
        )


def _upgrade_report_locations(inspector: sa.Inspector) -> None:
    columns = _columns(inspector, "report_locations")
    has_new_unique = _has_unique_key(
        inspector,
        "report_locations",
        ["workspace_id", "name"],
    )
    if "workspace_id" in columns and has_new_unique:
        if not _has_index(inspector, "report_locations", ["workspace_id"]):
            op.create_index(
                "ix_report_locations_workspace_id",
                "report_locations",
                ["workspace_id"],
            )
        return

    old_unique_name = _unique_constraint_name(inspector, "report_locations", ["name"])
    with op.batch_alter_table("report_locations", recreate="always") as batch:
        if "workspace_id" not in columns:
            batch.add_column(sa.Column("workspace_id", sa.Uuid(as_uuid=True), nullable=True))
            batch.create_foreign_key(
                "fk_report_locations_workspace_id_workspaces",
                "workspaces",
                ["workspace_id"],
                ["id"],
                ondelete="CASCADE",
            )
        if old_unique_name is not None:
            batch.drop_constraint(old_unique_name, type_="unique")
        batch.create_unique_constraint(
            "uq_report_locations_workspace_name",
            ["workspace_id", "name"],
        )
        batch.create_index("ix_report_locations_workspace_id", ["workspace_id"])


def _upgrade_dashboard_snapshots(inspector: sa.Inspector) -> None:
    table_name = "dashboard_daily_snapshots"
    columns = _columns(inspector, table_name)
    has_new_unique = _has_unique_key(
        inspector,
        table_name,
        ["location_id", "service_date"],
    )
    if "location_id" in columns and has_new_unique:
        if not _has_index(inspector, table_name, ["location_id"]):
            op.create_index(
                "ix_dashboard_daily_snapshots_location_id",
                table_name,
                ["location_id"],
            )
        return

    old_unique_name = _unique_constraint_name(inspector, table_name, ["service_date"])
    with op.batch_alter_table(table_name, recreate="always") as batch:
        if "location_id" not in columns:
            batch.add_column(sa.Column("location_id", sa.Uuid(as_uuid=True), nullable=True))
            batch.create_foreign_key(
                "fk_dashboard_daily_snapshots_location_id_report_locations",
                "report_locations",
                ["location_id"],
                ["id"],
                ondelete="CASCADE",
            )
        if old_unique_name is not None:
            batch.drop_constraint(old_unique_name, type_="unique")
        batch.create_unique_constraint(
            "uq_dashboard_daily_snapshots_location_date",
            ["location_id", "service_date"],
        )
        batch.create_index("ix_dashboard_daily_snapshots_location_id", ["location_id"])


def _upgrade_dashboard_activities(inspector: sa.Inspector) -> None:
    table_name = "dashboard_activities"
    columns = _columns(inspector, table_name)
    if "location_id" in columns:
        if not _has_index(inspector, table_name, ["location_id", "service_date"]):
            op.create_index(
                "ix_dashboard_activities_location_date",
                table_name,
                ["location_id", "service_date"],
            )
        return
    with op.batch_alter_table(table_name, recreate="always") as batch:
        batch.add_column(sa.Column("location_id", sa.Uuid(as_uuid=True), nullable=True))
        batch.create_foreign_key(
            "fk_dashboard_activities_location_id_report_locations",
            "report_locations",
            ["location_id"],
            ["id"],
            ondelete="CASCADE",
        )
        batch.create_index(
            "ix_dashboard_activities_location_date",
            ["location_id", "service_date"],
        )


def upgrade() -> None:
    """Add tenant boundaries while leaving all existing operational rows unowned."""
    inspector = sa.inspect(op.get_bind())
    existing_tables = set(inspector.get_table_names())
    _create_workspace_tables(existing_tables)

    inspector = sa.inspect(op.get_bind())
    _upgrade_report_locations(inspector)
    inspector = sa.inspect(op.get_bind())
    _upgrade_dashboard_snapshots(inspector)
    inspector = sa.inspect(op.get_bind())
    _upgrade_dashboard_activities(inspector)


def downgrade() -> None:
    """Restore the pre-workspace schema without assigning ownership."""
    with op.batch_alter_table("dashboard_activities", recreate="always") as batch:
        batch.drop_index("ix_dashboard_activities_location_date")
        batch.drop_constraint(
            "fk_dashboard_activities_location_id_report_locations",
            type_="foreignkey",
        )
        batch.drop_column("location_id")

    with op.batch_alter_table("dashboard_daily_snapshots", recreate="always") as batch:
        batch.drop_index("ix_dashboard_daily_snapshots_location_id")
        batch.drop_constraint(
            "uq_dashboard_daily_snapshots_location_date",
            type_="unique",
        )
        batch.drop_constraint(
            "fk_dashboard_daily_snapshots_location_id_report_locations",
            type_="foreignkey",
        )
        batch.drop_column("location_id")
        batch.create_unique_constraint(
            "uq_dashboard_daily_snapshots_service_date",
            ["service_date"],
        )

    with op.batch_alter_table("report_locations", recreate="always") as batch:
        batch.drop_index("ix_report_locations_workspace_id")
        batch.drop_constraint("uq_report_locations_workspace_name", type_="unique")
        batch.drop_constraint(
            "fk_report_locations_workspace_id_workspaces",
            type_="foreignkey",
        )
        batch.drop_column("workspace_id")
        batch.create_unique_constraint("uq_report_locations_name", ["name"])

    op.drop_index(
        "ix_workspace_memberships_user_workspace",
        table_name="workspace_memberships",
    )
    op.drop_table("workspace_memberships")
    op.drop_table("workspaces")
