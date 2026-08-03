import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class AudioUploadResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    original_filename: str
    media_type: str
    extension: str
    size_bytes: int = Field(gt=0, le=104857600)
    status: str
    scan_status: str
    created_at: datetime
    updated_at: datetime


class AudioUploadListResponse(BaseModel):
    items: list[AudioUploadResponse]
