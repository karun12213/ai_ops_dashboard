import uuid
from datetime import date

from pydantic import BaseModel, Field


class ReportLocationResponse(BaseModel):
    id: uuid.UUID
    name: str


class ReportTotalsResponse(BaseModel):
    currency_code: str | None
    revenue_total_minor: int = Field(ge=0)
    order_total: int = Field(ge=0)
    average_ticket_minor: int = Field(ge=0)


class ReportChannelResponse(BaseModel):
    channel: str
    label: str
    revenue_minor: int = Field(ge=0)
    order_total: int = Field(ge=0)
    revenue_percent: float = Field(ge=0, le=100)


class ReportTrendPointResponse(BaseModel):
    date: date
    revenue_minor: int = Field(ge=0)
    order_total: int = Field(ge=0)


class ReportLocationPerformanceResponse(BaseModel):
    location_id: uuid.UUID
    location_name: str
    currency_code: str
    revenue_minor: int = Field(ge=0)
    order_total: int = Field(ge=0)
    average_ticket_minor: int = Field(ge=0)
    revenue_growth_percent: float | None


class ReportResponse(BaseModel):
    start_date: date
    end_date: date
    location_id: uuid.UUID | None
    locations: list[ReportLocationResponse]
    totals: ReportTotalsResponse
    channel_split: list[ReportChannelResponse]
    revenue_trend: list[ReportTrendPointResponse]
    location_performance: list[ReportLocationPerformanceResponse]

