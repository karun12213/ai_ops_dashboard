import uuid
from datetime import datetime

from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, Index, String, UniqueConstraint, Uuid, func
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
            "extension IN ('mp3', 'wav', 'm4a', 'aac', 'ogg')",
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
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
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
