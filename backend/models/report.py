import uuid
from datetime import date, datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    Uuid,
    func,
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
        UniqueConstraint(
            "workspace_id",
            "name",
            name="uq_report_locations_workspace_name",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=True,
        index=True,
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


class AudioOperationsReport(Base):
    """A tenant-scoped operational report generated from one audio upload."""

    __tablename__ = "audio_operations_reports"
    __table_args__ = (
        CheckConstraint(
            "category IN ('operations', 'staff', 'inventory', 'customer', 'safety', 'other')",
            name="ck_audio_operations_reports_category",
        ),
        CheckConstraint(
            "severity IN ('low', 'medium', 'high', 'critical')",
            name="ck_audio_operations_reports_severity",
        ),
        Index(
            "ix_audio_operations_reports_workspace_processed",
            "workspace_id",
            "processed_at",
        ),
        Index(
            "ix_audio_operations_reports_location_processed",
            "location_id",
            "processed_at",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    upload_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("audio_uploads.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    owner_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    location_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("report_locations.id", ondelete="CASCADE"),
        nullable=False,
    )
    transcript: Mapped[str] = mapped_column(Text, nullable=False)
    summary: Mapped[str] = mapped_column(Text, nullable=False)
    category: Mapped[str] = mapped_column(String(40), nullable=False)
    severity: Mapped[str] = mapped_column(String(16), nullable=False)
    requires_attention: Mapped[bool] = mapped_column(Boolean, nullable=False)
    recommended_action: Mapped[str] = mapped_column(Text, nullable=False)
    source: Mapped[str] = mapped_column(
        String(64), nullable=False, default="AI Audio Monitor"
    )
    processed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
