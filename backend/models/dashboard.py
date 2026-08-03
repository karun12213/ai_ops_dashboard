import uuid
from datetime import date, datetime
from typing import Optional

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
    Uuid,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from backend.database.base import Base


class DashboardDailySnapshot(Base):
    """Date-scoped restaurant metrics displayed by the Dashboard."""

    __tablename__ = "dashboard_daily_snapshots"
    __table_args__ = (
        CheckConstraint("net_sales_minor >= 0", name="ck_dashboard_net_sales_nonnegative"),
        CheckConstraint("orders_served >= 0", name="ck_dashboard_orders_nonnegative"),
        CheckConstraint(
            "average_table_turn_minutes IS NULL OR average_table_turn_minutes >= 0",
            name="ck_dashboard_turn_time_nonnegative",
        ),
        CheckConstraint("occupied_tables >= 0", name="ck_dashboard_occupied_tables_nonnegative"),
        CheckConstraint("total_tables >= 0", name="ck_dashboard_total_tables_nonnegative"),
        CheckConstraint(
            "active_kitchen_tickets >= 0",
            name="ck_dashboard_kitchen_tickets_nonnegative",
        ),
        CheckConstraint("kitchen_capacity >= 0", name="ck_dashboard_kitchen_capacity_nonnegative"),
        CheckConstraint("pickup_orders >= 0", name="ck_dashboard_pickup_orders_nonnegative"),
        CheckConstraint("pickup_capacity >= 0", name="ck_dashboard_pickup_capacity_nonnegative"),
        CheckConstraint("staff_on_shift >= 0", name="ck_dashboard_staff_on_shift_nonnegative"),
        CheckConstraint("staff_scheduled >= 0", name="ck_dashboard_staff_scheduled_nonnegative"),
        UniqueConstraint("service_date", name="uq_dashboard_daily_snapshots_service_date"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid.uuid4)
    service_date: Mapped[date] = mapped_column(Date, nullable=False)
    currency_code: Mapped[str] = mapped_column(String(3), nullable=False, default="INR")
    net_sales_minor: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    net_sales_change_percent: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    orders_served: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    orders_change_percent: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    average_ticket_change_percent: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    average_table_turn_minutes: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    table_turn_change_percent: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    service_open: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    occupied_tables: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    total_tables: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    active_kitchen_tickets: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    kitchen_capacity: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    pickup_orders: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    pickup_capacity: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    staff_on_shift: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    staff_scheduled: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


class DashboardHourlySales(Base):
    """One hourly net-sales aggregate belonging to a daily snapshot."""

    __tablename__ = "dashboard_hourly_sales"
    __table_args__ = (
        CheckConstraint("hour >= 0 AND hour <= 23", name="ck_dashboard_hour_range"),
        CheckConstraint(
            "net_sales_minor >= 0",
            name="ck_dashboard_hourly_sales_nonnegative",
        ),
        UniqueConstraint("snapshot_id", "hour", name="uq_dashboard_hourly_sales_snapshot_hour"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid.uuid4)
    snapshot_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("dashboard_daily_snapshots.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    hour: Mapped[int] = mapped_column(Integer, nullable=False)
    net_sales_minor: Mapped[int] = mapped_column(Integer, nullable=False)


class DashboardActivity(Base):
    """Operator-facing event shown in the Dashboard activity feed."""

    __tablename__ = "dashboard_activities"

    id: Mapped[uuid.UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid.uuid4)
    service_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    title: Mapped[str] = mapped_column(String(160), nullable=False)
    actor: Mapped[str] = mapped_column(String(120), nullable=False)
    category: Mapped[str] = mapped_column(String(40), nullable=False, default="operations")
