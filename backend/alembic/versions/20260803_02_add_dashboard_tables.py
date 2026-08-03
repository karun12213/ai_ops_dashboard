"""add dashboard operational tables

Revision ID: 20260803_02
Revises: 20260802_01
Create Date: 2026-08-03

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260803_02"
down_revision: Union[str, None] = "20260802_01"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_REQUIRED_COLUMNS = {
    "dashboard_daily_snapshots": {
        "id",
        "service_date",
        "currency_code",
        "net_sales_minor",
        "net_sales_change_percent",
        "orders_served",
        "orders_change_percent",
        "average_ticket_change_percent",
        "average_table_turn_minutes",
        "table_turn_change_percent",
        "service_open",
        "occupied_tables",
        "total_tables",
        "active_kitchen_tickets",
        "kitchen_capacity",
        "pickup_orders",
        "pickup_capacity",
        "staff_on_shift",
        "staff_scheduled",
        "updated_at",
    },
    "dashboard_hourly_sales": {"id", "snapshot_id", "hour", "net_sales_minor"},
    "dashboard_activities": {
        "id",
        "service_date",
        "occurred_at",
        "title",
        "actor",
        "category",
    },
}


def _validate_existing_table(inspector: sa.Inspector, table_name: str) -> None:
    columns = {column["name"] for column in inspector.get_columns(table_name)}
    missing_columns = sorted(_REQUIRED_COLUMNS[table_name] - columns)
    if missing_columns:
        raise RuntimeError(
            f"Existing {table_name} table is incompatible with the Dashboard migration; "
            f"missing columns: {', '.join(missing_columns)}"
        )


def _has_index(inspector: sa.Inspector, table_name: str, columns: list[str]) -> bool:
    return any(
        index.get("column_names") == columns for index in inspector.get_indexes(table_name)
    )


def _has_unique_key(inspector: sa.Inspector, table_name: str, columns: list[str]) -> bool:
    return any(
        constraint.get("column_names") == columns
        for constraint in inspector.get_unique_constraints(table_name)
    ) or any(
        index.get("unique") and index.get("column_names") == columns
        for index in inspector.get_indexes(table_name)
    )


def _create_daily_snapshots() -> None:
    op.create_table(
        "dashboard_daily_snapshots",
        sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
        sa.Column("service_date", sa.Date(), nullable=False),
        sa.Column("currency_code", sa.String(length=3), nullable=False),
        sa.Column("net_sales_minor", sa.Integer(), nullable=False),
        sa.Column("net_sales_change_percent", sa.Float(), nullable=True),
        sa.Column("orders_served", sa.Integer(), nullable=False),
        sa.Column("orders_change_percent", sa.Float(), nullable=True),
        sa.Column("average_ticket_change_percent", sa.Float(), nullable=True),
        sa.Column("average_table_turn_minutes", sa.Integer(), nullable=True),
        sa.Column("table_turn_change_percent", sa.Float(), nullable=True),
        sa.Column("service_open", sa.Boolean(), nullable=False),
        sa.Column("occupied_tables", sa.Integer(), nullable=False),
        sa.Column("total_tables", sa.Integer(), nullable=False),
        sa.Column("active_kitchen_tickets", sa.Integer(), nullable=False),
        sa.Column("kitchen_capacity", sa.Integer(), nullable=False),
        sa.Column("pickup_orders", sa.Integer(), nullable=False),
        sa.Column("pickup_capacity", sa.Integer(), nullable=False),
        sa.Column("staff_on_shift", sa.Integer(), nullable=False),
        sa.Column("staff_scheduled", sa.Integer(), nullable=False),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.CheckConstraint(
            "net_sales_minor >= 0",
            name="ck_dashboard_net_sales_nonnegative",
        ),
        sa.CheckConstraint("orders_served >= 0", name="ck_dashboard_orders_nonnegative"),
        sa.CheckConstraint(
            "average_table_turn_minutes IS NULL OR average_table_turn_minutes >= 0",
            name="ck_dashboard_turn_time_nonnegative",
        ),
        sa.CheckConstraint(
            "occupied_tables >= 0",
            name="ck_dashboard_occupied_tables_nonnegative",
        ),
        sa.CheckConstraint("total_tables >= 0", name="ck_dashboard_total_tables_nonnegative"),
        sa.CheckConstraint(
            "active_kitchen_tickets >= 0",
            name="ck_dashboard_kitchen_tickets_nonnegative",
        ),
        sa.CheckConstraint(
            "kitchen_capacity >= 0",
            name="ck_dashboard_kitchen_capacity_nonnegative",
        ),
        sa.CheckConstraint(
            "pickup_orders >= 0",
            name="ck_dashboard_pickup_orders_nonnegative",
        ),
        sa.CheckConstraint(
            "pickup_capacity >= 0",
            name="ck_dashboard_pickup_capacity_nonnegative",
        ),
        sa.CheckConstraint(
            "staff_on_shift >= 0",
            name="ck_dashboard_staff_on_shift_nonnegative",
        ),
        sa.CheckConstraint(
            "staff_scheduled >= 0",
            name="ck_dashboard_staff_scheduled_nonnegative",
        ),
        sa.UniqueConstraint(
            "service_date",
            name="uq_dashboard_daily_snapshots_service_date",
        ),
    )


def _create_hourly_sales() -> None:
    op.create_table(
        "dashboard_hourly_sales",
        sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
        sa.Column(
            "snapshot_id",
            sa.Uuid(as_uuid=True),
            sa.ForeignKey("dashboard_daily_snapshots.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("hour", sa.Integer(), nullable=False),
        sa.Column("net_sales_minor", sa.Integer(), nullable=False),
        sa.CheckConstraint("hour >= 0 AND hour <= 23", name="ck_dashboard_hour_range"),
        sa.CheckConstraint(
            "net_sales_minor >= 0",
            name="ck_dashboard_hourly_sales_nonnegative",
        ),
        sa.UniqueConstraint(
            "snapshot_id",
            "hour",
            name="uq_dashboard_hourly_sales_snapshot_hour",
        ),
    )
    op.create_index(
        "ix_dashboard_hourly_sales_snapshot_id",
        "dashboard_hourly_sales",
        ["snapshot_id"],
    )


def _create_activities() -> None:
    op.create_table(
        "dashboard_activities",
        sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
        sa.Column("service_date", sa.Date(), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("title", sa.String(length=160), nullable=False),
        sa.Column("actor", sa.String(length=120), nullable=False),
        sa.Column("category", sa.String(length=40), nullable=False),
    )
    op.create_index(
        "ix_dashboard_activities_service_date",
        "dashboard_activities",
        ["service_date"],
    )


def upgrade() -> None:
    """Create Dashboard tables or adopt compatible development tables."""
    inspector = sa.inspect(op.get_bind())
    existing_tables = set(inspector.get_table_names())

    for table_name in _REQUIRED_COLUMNS:
        if table_name in existing_tables:
            _validate_existing_table(inspector, table_name)

    if "dashboard_daily_snapshots" not in existing_tables:
        _create_daily_snapshots()
    elif not _has_unique_key(
        inspector,
        "dashboard_daily_snapshots",
        ["service_date"],
    ):
        raise RuntimeError(
            "Existing dashboard_daily_snapshots table is incompatible with the "
            "Dashboard migration; service_date must be unique"
        )

    if "dashboard_hourly_sales" not in existing_tables:
        _create_hourly_sales()
    else:
        if not _has_unique_key(
            inspector,
            "dashboard_hourly_sales",
            ["snapshot_id", "hour"],
        ):
            raise RuntimeError(
                "Existing dashboard_hourly_sales table is incompatible with the "
                "Dashboard migration; snapshot_id and hour must be unique together"
            )
        if not _has_index(inspector, "dashboard_hourly_sales", ["snapshot_id"]):
            op.create_index(
                "ix_dashboard_hourly_sales_snapshot_id",
                "dashboard_hourly_sales",
                ["snapshot_id"],
            )

    if "dashboard_activities" not in existing_tables:
        _create_activities()
    elif not _has_index(inspector, "dashboard_activities", ["service_date"]):
        op.create_index(
            "ix_dashboard_activities_service_date",
            "dashboard_activities",
            ["service_date"],
        )


def downgrade() -> None:
    """Remove only the Dashboard-owned operational tables."""
    op.drop_index(
        "ix_dashboard_activities_service_date",
        table_name="dashboard_activities",
    )
    op.drop_table("dashboard_activities")
    op.drop_index(
        "ix_dashboard_hourly_sales_snapshot_id",
        table_name="dashboard_hourly_sales",
    )
    op.drop_table("dashboard_hourly_sales")
    op.drop_table("dashboard_daily_snapshots")
