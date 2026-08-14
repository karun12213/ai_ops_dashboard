import uuid
from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, Field


class CostAnalyticsMetricsResponse(BaseModel):
    """Headline usage and cost metrics for a filtered upload cohort."""

    total_audio_uploads: int = Field(ge=0)
    costed_audio_uploads: int = Field(ge=0)
    missing_cost_data_uploads: int = Field(ge=0)
    total_recorded_audio_duration_seconds: float = Field(ge=0)
    costed_audio_duration_seconds: float = Field(ge=0)
    total_sarvam_cost_inr: Decimal | None = Field(default=None, ge=0)
    total_openai_cost_usd: Decimal | None = Field(default=None, ge=0)
    average_sarvam_cost_per_upload_inr: Decimal | None = Field(default=None, ge=0)
    average_openai_cost_per_upload_usd: Decimal | None = Field(default=None, ge=0)
    average_sarvam_cost_per_recorded_minute_inr: Decimal | None = Field(
        default=None, ge=0
    )
    average_openai_cost_per_recorded_minute_usd: Decimal | None = Field(
        default=None, ge=0
    )
    estimated_sarvam_cost_per_recorded_hour_inr: Decimal | None = Field(
        default=None, ge=0
    )
    estimated_openai_cost_per_recorded_hour_usd: Decimal | None = Field(
        default=None, ge=0
    )


class CostAnalyticsBreakdownResponse(BaseModel):
    """One location, severity, or normalized category cost bucket."""

    key: str
    label: str
    total_audio_uploads: int = Field(ge=0)
    costed_audio_uploads: int = Field(ge=0)
    missing_cost_data_uploads: int = Field(ge=0)
    recorded_audio_duration_seconds: float = Field(ge=0)
    sarvam_cost_inr: Decimal | None = Field(default=None, ge=0)
    openai_cost_usd: Decimal | None = Field(default=None, ge=0)


class CostAnalyticsRecentUsageResponse(BaseModel):
    """Per-upload usage displayed in the recent-usage table."""

    upload_id: uuid.UUID
    processed_at: datetime
    original_filename: str
    audio_duration_seconds: float | None = Field(default=None, ge=0)
    category: str
    severity: str
    sarvam_estimated_cost_inr: Decimal | None = Field(default=None, ge=0)
    openai_estimated_cost_usd: Decimal | None = Field(default=None, ge=0)
    openai_total_tokens: int | None = Field(default=None, ge=0)


class CostAnalyticsResponse(BaseModel):
    """Tenant-scoped cost analytics for successfully processed audio."""

    start_date: date
    end_date: date
    location_id: uuid.UUID | None = None
    metrics: CostAnalyticsMetricsResponse
    by_location: list[CostAnalyticsBreakdownResponse]
    by_severity: list[CostAnalyticsBreakdownResponse]
    by_category: list[CostAnalyticsBreakdownResponse]
    recent_usage: list[CostAnalyticsRecentUsageResponse]
