import uuid
from datetime import datetime
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class AudioUploadResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    location_id: uuid.UUID | None
    language_code: str | None
    detected_language_code: str | None = None
    processing_stage: str = "uploaded"
    failure_stage: str | None = None
    failure_code: str | None = None
    failure_message: str | None = None
    retryable: bool = True
    audio_container: str | None = None
    audio_codec: str | None = None
    audio_duration_seconds: float | None = None
    audio_sample_rate: int | None = None
    audio_channels: int | None = None
    transcription_strategy: str | None = None
    sarvam_model: str | None = None
    sarvam_estimated_cost_inr: Decimal | None = Field(default=None, ge=0)
    openai_model: str | None = None
    openai_input_tokens: int | None = Field(default=None, ge=0)
    openai_cached_input_tokens: int | None = Field(default=None, ge=0)
    openai_output_tokens: int | None = Field(default=None, ge=0)
    openai_total_tokens: int | None = Field(default=None, ge=0)
    openai_estimated_cost_usd: Decimal | None = Field(default=None, ge=0)
    total_estimated_cost: dict[str, str] | None = None
    original_filename: str
    media_type: str
    extension: str
    size_bytes: int = Field(gt=0, le=104857600)
    status: str
    scan_status: str
    created_at: datetime
    updated_at: datetime


class AudioUploadHistoryResponse(AudioUploadResponse):
    transcript_available: bool = False
    report_id: uuid.UUID | None = None
    severity: Literal["low", "medium", "high", "critical"] | None = None
    processed_at: datetime | None = None
    location_name: str | None = None
    source: Literal["AI Audio Monitor"] | None = None


class AudioUploadListResponse(BaseModel):
    items: list[AudioUploadHistoryResponse]


class AudioAnalysisResponse(BaseModel):
    summary: str = Field(min_length=1)
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
    recommended_action: str = Field(min_length=1)


class AudioUploadProcessingResponse(AudioUploadResponse):
    """Stored upload metadata plus the completed operational AI result."""

    transcript: str = Field(min_length=1)
    analysis: AudioAnalysisResponse
    activity_id: uuid.UUID
    report_id: uuid.UUID
    workspace_id: uuid.UUID
    location_id: uuid.UUID
    location_name: str = Field(min_length=1)
    processed_at: datetime
    source: Literal["AI Audio Monitor"] = "AI Audio Monitor"
