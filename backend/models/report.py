import uuid
from datetime import date

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Date,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy.orm import Mapped, mapped_column

from backend.database.base import Base


class ReportLocation(Base):
    """A reporting dimension used to group stored sales aggregates."""

    __tablename__ = "report_locations"
    __table_args__ = (
        CheckConstraint(
            "length(currency_code) = 3",
            name="ck_report_locations_currency_code_length",
        ),
        UniqueConstraint("name", name="uq_report_locations_name"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    currency_code: Mapped[str] = mapped_column(String(3), nullable=False)


class ReportDailySales(Base):
    """One persisted daily sales aggregate per location and channel."""

    __tablename__ = "report_daily_sales"
    __table_args__ = (
        CheckConstraint(
            "channel IN ('dine_in', 'delivery', 'pickup')",
            name="ck_report_daily_sales_channel",
        ),
        CheckConstraint(
            "net_sales_minor >= 0",
            name="ck_report_daily_sales_revenue_nonnegative",
        ),
        CheckConstraint(
            "order_count >= 0",
            name="ck_report_daily_sales_orders_nonnegative",
        ),
        UniqueConstraint(
            "service_date",
            "location_id",
            "channel",
            name="uq_report_daily_sales_date_location_channel",
        ),
        Index(
            "ix_report_daily_sales_location_date",
            "location_id",
            "service_date",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    service_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    location_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("report_locations.id", ondelete="RESTRICT"),
        nullable=False,
    )
    channel: Mapped[str] = mapped_column(String(24), nullable=False)
    net_sales_minor: Mapped[int] = mapped_column(BigInteger, nullable=False)
    order_count: Mapped[int] = mapped_column(Integer, nullable=False)
