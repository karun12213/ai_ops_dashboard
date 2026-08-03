import uuid
from functools import lru_cache
from typing import Annotated

from fastapi import APIRouter, Depends, File, HTTPException, Query, Response, UploadFile, status
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.audio_upload import AudioUploadListResponse, AudioUploadResponse
from backend.auth.dependencies import CurrentUser
from backend.database.session import get_db
from backend.models.audio_upload import AudioUpload
from backend.services.audio_upload_service import (
    AudioUploadService,
    AudioUploadTooLargeError,
    AudioUploadUnavailableError,
    DuplicateAudioUploadError,
    EmptyAudioUploadError,
    InfectedAudioUploadError,
)
from backend.services.audio_validation import UnsupportedAudioError
from backend.services.virus_scanner import AudioVirusScanner, NoOpAudioVirusScanner
from backend.storage.audio_storage import AudioObjectStorage, LocalAudioStorage
from backend.utils.config import get_settings

router = APIRouter(prefix="/audio-uploads", tags=["audio uploads"])


@lru_cache
def get_audio_storage() -> AudioObjectStorage:
    return LocalAudioStorage(get_settings().audio_local_storage_path)


@lru_cache
def get_audio_scanner() -> AudioVirusScanner:
    return NoOpAudioVirusScanner()


def get_audio_max_upload_bytes() -> int:
    return get_settings().audio_max_upload_bytes


def get_audio_upload_service(
    session: Annotated[AsyncSession, Depends(get_db)],
    storage: Annotated[AudioObjectStorage, Depends(get_audio_storage)],
    scanner: Annotated[AudioVirusScanner, Depends(get_audio_scanner)],
    max_upload_bytes: Annotated[int, Depends(get_audio_max_upload_bytes)],
) -> AudioUploadService:
    return AudioUploadService(
        session=session,
        storage=storage,
        scanner=scanner,
        max_upload_bytes=max_upload_bytes,
    )


@router.post(
    "",
    response_model=AudioUploadResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Upload an audio file",
)
async def create_audio_upload(
    current_user: CurrentUser,
    file: Annotated[UploadFile, File(description="MP3, WAV, M4A, AAC, or OGG audio")],
    service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
) -> AudioUpload:
    try:
        return await service.upload(owner=current_user, file=file)
    except UnsupportedAudioError as exc:
        raise HTTPException(status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail=str(exc))
    except EmptyAudioUploadError as exc:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc))
    except AudioUploadTooLargeError as exc:
        raise HTTPException(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail=str(exc))
    except DuplicateAudioUploadError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))
    except InfectedAudioUploadError as exc:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc))
    except AudioUploadUnavailableError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc))


@router.get("", response_model=AudioUploadListResponse, summary="List uploaded audio")
async def list_audio_uploads(
    current_user: CurrentUser,
    service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
    limit: Annotated[int, Query(ge=1, le=50)] = 50,
) -> AudioUploadListResponse:
    items = await service.list_for_owner(owner_id=current_user.id, limit=limit)
    return AudioUploadListResponse(items=items)


@router.get("/{upload_id}/download", summary="Download an uploaded audio file")
async def download_audio_upload(
    upload_id: uuid.UUID,
    current_user: CurrentUser,
    service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
) -> StreamingResponse:
    record = await service.get_ready_for_owner(owner_id=current_user.id, upload_id=upload_id)
    if record is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Audio upload not found")
    download_name = f"audio-{record.id}.{record.extension}"
    return StreamingResponse(
        service.storage.iter_bytes(record.storage_key),
        media_type=record.media_type,
        headers={
            "Content-Disposition": f'attachment; filename="{download_name}"',
            "Content-Length": str(record.size_bytes),
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.delete(
    "/{upload_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete an uploaded audio file",
)
async def delete_audio_upload(
    upload_id: uuid.UUID,
    current_user: CurrentUser,
    service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
) -> Response:
    try:
        deleted = await service.delete_for_owner(
            owner_id=current_user.id,
            upload_id=upload_id,
        )
    except AudioUploadUnavailableError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc))
    if not deleted:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Audio upload not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)
