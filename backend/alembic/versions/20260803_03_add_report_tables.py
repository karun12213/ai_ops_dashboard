"""add reports aggregate tables

Revision ID: 20260803_03
Revises: 20260803_02
Create Date: 2026-08-03

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "20260803_03"
down_revision: Union[str, None] = "20260803_02"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_REQUIRED_COLUMNS = {
    "report_locations": {"id", "name", "currency_code"},
    "report_daily_sales": {
        "id",
        "service_date",
        "location_id",
        "channel",
        "net_sales_minor",
        "order_count",
    },
}


def _validate_existing_table(inspector: sa.Inspector, table_name: str) -> None:
    columns = {column["name"] for column in inspector.get_columns(table_name)}
    missing_columns = sorted(_REQUIRED_COLUMNS[table_name] - columns)
    if missing_columns:
        raise RuntimeError(
            f"Existing {table_name} table is incompatible with the Reports migration; "
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


def _create_locations() -> None:
    op.create_table(
        "report_locations",
        sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("currency_code", sa.String(length=3), nullable=False),
        sa.CheckConstraint(
            "length(currency_code) = 3",
            name="ck_report_locations_currency_code_length",
        ),
        sa.UniqueConstraint("name", name="uq_report_locations_name"),
    )


def _create_daily_sales() -> None:
    op.create_table(
        "report_daily_sales",
        sa.Column("id", sa.Uuid(as_uuid=True), primary_key=True),
        sa.Column("service_date", sa.Date(), nullable=False),
        sa.Column(
            "location_id",
            sa.Uuid(as_uuid=True),
            sa.ForeignKey("report_locations.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("channel", sa.String(length=24), nullable=False),
        sa.Column("net_sales_minor", sa.BigInteger(), nullable=False),
        sa.Column("order_count", sa.Integer(), nullable=False),
        sa.CheckConstraint(
            "channel IN ('dine_in', 'delivery', 'pickup')",
            name="ck_report_daily_sales_channel",
        ),
        sa.CheckConstraint(
            "net_sales_minor >= 0",
            name="ck_report_daily_sales_revenue_nonnegative",
        ),
        sa.CheckConstraint(
            "order_count >= 0",
            name="ck_report_daily_sales_orders_nonnegative",
        ),
        sa.UniqueConstraint(
            "service_date",
            "location_id",
            "channel",
            name="uq_report_daily_sales_date_location_channel",
        ),
    )
    op.create_index(
        "ix_report_daily_sales_service_date",
        "report_daily_sales",
        ["service_date"],
    )
    op.create_index(
        "ix_report_daily_sales_location_date",
        "report_daily_sales",
        ["location_id", "service_date"],
    )


def upgrade() -> None:
    """Create Reports tables or adopt compatible development tables."""
    inspector = sa.inspect(op.get_bind())
    existing_tables = set(inspector.get_table_names())

    for table_name in _REQUIRED_COLUMNS:
        if table_name in existing_tables:
            _validate_existing_table(inspector, table_name)

    if "report_locations" not in existing_tables:
        _create_locations()
    elif not (
        _has_unique_key(inspector, "report_locations", ["name"])
        or (
            "workspace_id"
            in {column["name"] for column in inspector.get_columns("report_locations")}
            and _has_unique_key(
                inspector,
                "report_locations",
                ["workspace_id", "name"],
            )
        )
    ):
        raise RuntimeError(
            "Existing report_locations table is incompatible with the Reports "
            "migration; name must be unique"
        )

    if "report_daily_sales" not in existing_tables:
        _create_daily_sales()
        return

    if not _has_unique_key(
        inspector,
        "report_daily_sales",
        ["service_date", "location_id", "channel"],
    ):
        raise RuntimeError(
            "Existing report_daily_sales table is incompatible with the Reports "
            "migration; service_date, location_id, and channel must be unique together"
        )
    if not _has_index(inspector, "report_daily_sales", ["service_date"]):
        op.create_index(
            "ix_report_daily_sales_service_date",
            "report_daily_sales",
            ["service_date"],
        )
    if not _has_index(
        inspector,
        "report_daily_sales",
        ["location_id", "service_date"],
    ):
        op.create_index(
            "ix_report_daily_sales_location_date",
            "report_daily_sales",
            ["location_id", "service_date"],
        )


def downgrade() -> None:
    """Remove only the Reports-owned aggregate tables."""
    op.drop_index(
        "ix_report_daily_sales_location_date",
        table_name="report_daily_sales",
    )
    op.drop_index(
        "ix_report_daily_sales_service_date",
        table_name="report_daily_sales",
    )
    op.drop_table("report_daily_sales")
    op.drop_table("report_locations")
