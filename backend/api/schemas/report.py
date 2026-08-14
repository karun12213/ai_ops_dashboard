import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Literal

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


class AudioOperationsReportResponse(BaseModel):
    id: uuid.UUID
    upload_id: uuid.UUID
    workspace_id: uuid.UUID
    location_id: uuid.UUID
    location_name: str
    original_filename: str | None = None
    media_type: str | None = None
    source_language: str | None = None
    detected_language: str | None = None
    audio_duration_seconds: float | None = Field(default=None, ge=0)
    sarvam_model: str | None = None
    sarvam_estimated_cost_inr: Decimal | None = Field(default=None, ge=0)
    openai_model: str | None = None
    openai_input_tokens: int | None = Field(default=None, ge=0)
    openai_cached_input_tokens: int | None = Field(default=None, ge=0)
    openai_output_tokens: int | None = Field(default=None, ge=0)
    openai_total_tokens: int | None = Field(default=None, ge=0)
    openai_estimated_cost_usd: Decimal | None = Field(default=None, ge=0)
    total_estimated_cost: dict[str, str] | None = None
    transcript: str
    summary: str
    category: Literal[
        "operations",
        "staff",
        "inventory",
        "customer",
        "safety",
        "other",
    ]
    severity: Literal["low", "medium", "high", "critical"]
    requires_attention: bool
    recommended_action: str
    source: Literal["AI Audio Monitor"] = "AI Audio Monitor"
    processed_at: datetime


class ReportResponse(BaseModel):
    start_date: date
    end_date: date
    location_id: uuid.UUID | None
    locations: list[ReportLocationResponse]
    totals: ReportTotalsResponse
    channel_split: list[ReportChannelResponse]
    revenue_trend: list[ReportTrendPointResponse]
    location_performance: list[ReportLocationPerformanceResponse]
    audio_reports: list[AudioOperationsReportResponse]
