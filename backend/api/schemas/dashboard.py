import uuid
from datetime import date, datetime
from typing import Optional

from pydantic import BaseModel, Field


class DashboardMetricsResponse(BaseModel):
    """Headline metrics and prior-period comparisons for one service date."""

    currency_code: str = Field(min_length=3, max_length=3)
    net_sales_minor: int = Field(ge=0)
    net_sales_change_percent: Optional[float] = None
    orders_served: int = Field(ge=0)
    orders_change_percent: Optional[float] = None
    average_ticket_minor: int = Field(ge=0)
    average_ticket_change_percent: Optional[float] = None
    average_table_turn_minutes: Optional[int] = Field(default=None, ge=0)
    table_turn_change_percent: Optional[float] = None


class DashboardHourlySalesResponse(BaseModel):
    """Net sales recorded for a single hour of the service day."""

    hour: int = Field(ge=0, le=23)
    net_sales_minor: int = Field(ge=0)


class DashboardServicePulseResponse(BaseModel):
    """Current restaurant-capacity counts used by the service-pulse panel."""

    occupied_tables: int = Field(ge=0)
    total_tables: int = Field(ge=0)
    active_kitchen_tickets: int = Field(ge=0)
    kitchen_capacity: int = Field(ge=0)
    pickup_orders: int = Field(ge=0)
    pickup_capacity: int = Field(ge=0)
    staff_on_shift: int = Field(ge=0)
    staff_scheduled: int = Field(ge=0)


class DashboardSnapshotResponse(BaseModel):
    """Complete stored operational snapshot for one service date."""

    updated_at: datetime
    service_open: bool
    metrics: DashboardMetricsResponse
    hourly_sales: list[DashboardHourlySalesResponse]
    service_pulse: DashboardServicePulseResponse


class DashboardActivityResponse(BaseModel):
    """A single date-scoped activity feed entry."""

    id: uuid.UUID
    occurred_at: datetime
    title: str
    actor: str
    category: str


class DashboardResponse(BaseModel):
    """Dashboard payload for a requested restaurant service date."""

    service_date: date
    snapshot: Optional[DashboardSnapshotResponse] = None
    recent_activity: list[DashboardActivityResponse]
