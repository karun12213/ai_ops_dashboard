import uuid
from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    JSON,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    Uuid,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from backend.database.base import Base


class AudioUpload(Base):
    __tablename__ = "audio_uploads"
    __table_args__ = (
        CheckConstraint(
            "size_bytes > 0 AND size_bytes <= 104857600",
            name="ck_audio_uploads_size_bytes",
        ),
        CheckConstraint(
            "extension IN ('mp3', 'wav', 'm4a', 'aac', 'ogg', 'opus', 'mp4')",
            name="ck_audio_uploads_extension",
        ),
        CheckConstraint(
            "status IN ('processing', 'ready', 'failed', 'quarantined')",
            name="ck_audio_uploads_status",
        ),
        CheckConstraint(
            "scan_status IN ('not_configured', 'clean', 'infected', 'error')",
            name="ck_audio_uploads_scan_status",
        ),
        CheckConstraint(
            "length(sha256) = 64",
            name="ck_audio_uploads_sha256_length",
        ),
        UniqueConstraint("owner_id", "sha256", name="uq_audio_uploads_owner_sha256"),
        Index("ix_audio_uploads_owner_created_at", "owner_id", "created_at"),
        Index("ix_audio_uploads_location_created_at", "location_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    workspace_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=True,
        index=True,
    )
    location_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("report_locations.id", ondelete="CASCADE"),
        nullable=True,
        index=True,
    )
    language_code: Mapped[str | None] = mapped_column(String(12), nullable=True)
    detected_language_code: Mapped[str | None] = mapped_column(
        String(12), nullable=True
    )
    english_transcript: Mapped[str | None] = mapped_column(Text, nullable=True)
    audio_container: Mapped[str | None] = mapped_column(String(64), nullable=True)
    audio_codec: Mapped[str | None] = mapped_column(String(64), nullable=True)
    audio_duration_seconds: Mapped[float | None] = mapped_column(
        Float, nullable=True
    )
    audio_sample_rate: Mapped[int | None] = mapped_column(Integer, nullable=True)
    audio_channels: Mapped[int | None] = mapped_column(Integer, nullable=True)
    transcription_strategy: Mapped[str | None] = mapped_column(
        String(32), nullable=True
    )
    provider_job_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    provider_job_state: Mapped[str | None] = mapped_column(String(32), nullable=True)
    sarvam_model: Mapped[str | None] = mapped_column(String(64), nullable=True)
    sarvam_request_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    sarvam_job_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    sarvam_estimated_cost_inr: Mapped[Decimal | None] = mapped_column(
        Numeric(18, 8), nullable=True
    )
    openai_input_tokens: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    openai_cached_input_tokens: Mapped[int | None] = mapped_column(
        BigInteger, nullable=True
    )
    openai_output_tokens: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    openai_total_tokens: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    openai_model: Mapped[str | None] = mapped_column(String(128), nullable=True)
    openai_request_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    openai_request_ids: Mapped[list[str] | None] = mapped_column(JSON, nullable=True)
    openai_estimated_cost_usd: Mapped[Decimal | None] = mapped_column(
        Numeric(18, 8), nullable=True
    )
    total_estimated_cost: Mapped[dict[str, str] | None] = mapped_column(
        JSON, nullable=True
    )
    processing_stage: Mapped[str] = mapped_column(
        String(32), nullable=False, default="uploaded"
    )
    failure_stage: Mapped[str | None] = mapped_column(String(32), nullable=True)
    failure_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    failure_message: Mapped[str | None] = mapped_column(String(255), nullable=True)
    retryable: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    processed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    original_filename: Mapped[str] = mapped_column(String(255), nullable=False)
    storage_key: Mapped[str] = mapped_column(String(512), unique=True, nullable=False)
    media_type: Mapped[str] = mapped_column(String(64), nullable=False)
    extension: Mapped[str] = mapped_column(String(8), nullable=False)
    size_bytes: Mapped[int] = mapped_column(BigInteger(), nullable=False)
    sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(24), nullable=False, default="processing")
    scan_status: Mapped[str] = mapped_column(
        String(24), nullable=False, default="not_configured"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )
