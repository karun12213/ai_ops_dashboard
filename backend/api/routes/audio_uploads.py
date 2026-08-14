import uuid
import logging
from functools import lru_cache
from typing import Annotated

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Query,
    Response,
    UploadFile,
    status,
)
from fastapi.responses import JSONResponse, StreamingResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.audio_upload import (
    AudioUploadListResponse,
    AudioUploadHistoryResponse,
    AudioUploadProcessingResponse,
)
from backend.auth.dependencies import CurrentUser
from backend.database.session import get_db
from backend.models.audio_upload import AudioUpload
from backend.services.audio_ai_pipeline import (
    AudioAIPersistenceError,
    AudioAIPipeline,
)
from backend.services.audio_processing import (
    AudioDurationLimitError,
    AudioNormalizationError,
    AudioToolUnavailableError,
    InvalidAudioContentError,
)
from backend.services.audio_upload_service import (
    AudioUploadService,
    AudioUploadTooLargeError,
    AudioUploadUnavailableError,
    DuplicateAudioUploadError,
    EmptyAudioUploadError,
    InfectedAudioUploadError,
)
from backend.services.audio_validation import UnsupportedAudioError
from backend.models.dashboard import DashboardActivity
from backend.models.report import AudioOperationsReport, ReportLocation
from backend.services.openai_service import (
    OpenAIRateLimitError,
    OpenAIUnavailableError,
)
from backend.services.sarvam_service import (
    SUPPORTED_SARVAM_LANGUAGE_CODES,
    SarvamAuthenticationError,
    SarvamInvalidRequestError,
    SarvamRateLimitError,
    SarvamTimeoutError,
    SarvamUnavailableError,
)
from backend.services.virus_scanner import AudioVirusScanner, NoOpAudioVirusScanner
from backend.services.workspace_service import (
    WorkspaceAccessDeniedError,
    WorkspaceNotFoundError,
    WorkspaceService,
)
from backend.storage.audio_storage import (
    AudioObjectNotFoundError,
    AudioObjectStorage,
    InvalidStorageKeyError,
    LocalAudioStorage,
)
from backend.utils.config import get_settings

router = APIRouter(prefix="/audio-uploads", tags=["audio uploads"])
logger = logging.getLogger(__name__)


@lru_cache
def get_audio_storage() -> AudioObjectStorage:
    return LocalAudioStorage(get_settings().audio_local_storage_path)


@lru_cache
def get_audio_scanner() -> AudioVirusScanner:
    return NoOpAudioVirusScanner()


def get_audio_max_upload_bytes() -> int:
    return get_settings().audio_max_upload_bytes


def get_audio_ai_pipeline() -> AudioAIPipeline:
    return AudioAIPipeline()


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
    response_model=AudioUploadProcessingResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Upload and analyze an audio file",
)
async def create_audio_upload(
    current_user: CurrentUser,
    file: Annotated[
        UploadFile,
        File(description="MP3, WAV, M4A, AAC, OGG/Opus, or MP4 audio"),
    ],
    location_id: Annotated[
        uuid.UUID,
        Form(description="Authorized restaurant location UUID"),
    ],
    service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
    pipeline: Annotated[AudioAIPipeline, Depends(get_audio_ai_pipeline)],
    language_code: Annotated[
        str,
        Form(
            min_length=2,
            max_length=12,
            description="Sarvam source language code or unknown for auto detection",
        ),
    ] = "unknown",
) -> AudioUploadProcessingResponse:
    if language_code not in SUPPORTED_SARVAM_LANGUAGE_CODES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "code": "invalid_language_code",
                "message": "The selected source language is not supported.",
            },
        )
    try:
        location = await WorkspaceService(service.session).require_accessible_location(
            user_id=current_user.id,
            location_id=location_id,
        )
    except WorkspaceNotFoundError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="The selected restaurant location could not be found.",
        )
    except WorkspaceAccessDeniedError:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You do not have access to this location.",
        )

    try:
        record = await service.upload(
            owner=current_user,
            location=location,
            language_code=language_code,
            file=file,
        )
    except UnsupportedAudioError as exc:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail=str(exc),
        )
    except EmptyAudioUploadError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=str(exc),
        )
    except AudioUploadTooLargeError as exc:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=str(exc),
        )
    except DuplicateAudioUploadError as exc:
        report_id = await service.session.scalar(
            select(AudioOperationsReport.id).where(
                AudioOperationsReport.upload_id == exc.upload.id
            )
        )
        is_completed = exc.upload.status == "ready" and report_id is not None
        return JSONResponse(
            status_code=status.HTTP_409_CONFLICT,
            content={
                "detail": {
                    "code": (
                        "duplicate_completed"
                        if is_completed
                        else "duplicate_processing"
                    ),
                    "message": (
                        "This recording has already been processed. Open the existing report."
                        if is_completed
                        else "This recording is already being processed."
                    ),
                    "existing_upload_id": str(exc.upload.id),
                    "existing_report_id": str(report_id) if report_id else None,
                }
            },
        )
    except InfectedAudioUploadError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=str(exc),
        )
    except AudioUploadUnavailableError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(exc),
        )

    result = await _execute_pipeline(
        service=service,
        pipeline=pipeline,
        record=record,
        location=location,
        language_code=language_code,
    )

    return _processing_response(record, location, result)


async def _execute_pipeline(
    *,
    service: AudioUploadService,
    pipeline: AudioAIPipeline,
    record: AudioUpload,
    location: ReportLocation,
    language_code: str,
):
    try:
        audio_path = service.storage.get_path(record.storage_key)
        return await pipeline.process_audio(
            audio_path=audio_path,
            session=service.session,
            upload=record,
            location=location,
            language_code=language_code,
        )
    except (AudioObjectNotFoundError, InvalidStorageKeyError, NotImplementedError) as exc:
        message = "Stored audio is temporarily unavailable for processing."
        await _mark_processing_failed(
            service.session,
            record.id,
            code="storage_unavailable",
            message=message,
            retryable=True,
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"code": "storage_unavailable", "message": message},
        ) from exc
    except AudioToolUnavailableError as exc:
        message = "Audio processing is temporarily unavailable. Please try again."
        logger.error(
            "Audio tool unavailable upload_id=%s stage=%s exception_type=%s",
            record.id,
            record.processing_stage,
            type(exc).__name__,
        )
        await _mark_processing_failed(
            service.session,
            record.id,
            code=exc.code,
            message=message,
            retryable=True,
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"code": exc.code, "message": message},
        ) from exc
    except (InvalidAudioContentError, AudioNormalizationError, AudioDurationLimitError) as exc:
        message = "The recording could not be processed."
        logger.warning(
            "Audio media processing rejected upload_id=%s stage=%s exception_type=%s code=%s",
            record.id,
            record.processing_stage,
            type(exc).__name__,
            exc.code,
        )
        await _mark_processing_failed(
            service.session,
            record.id,
            code=exc.code,
            message=message,
            retryable=False,
        )
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"code": exc.code, "message": message},
        ) from exc
    except (SarvamRateLimitError, OpenAIRateLimitError) as exc:
        message = "The AI service is busy. Please try again shortly."
        await _mark_processing_failed(
            service.session,
            record.id,
            code="ai_busy",
            message=message,
            retryable=True,
        )
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail={"code": "ai_busy", "message": message},
        ) from exc
    except SarvamInvalidRequestError as exc:
        message = "The recording could not be processed."
        _log_sarvam_failure(record, exc)
        await _mark_processing_failed(
            service.session,
            record.id,
            code=exc.code,
            message=message,
            retryable=False,
        )
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"code": exc.code, "message": message},
        ) from exc
    except (SarvamAuthenticationError, SarvamTimeoutError, SarvamUnavailableError) as exc:
        message = "Speech translation is temporarily unavailable. Please try again."
        _log_sarvam_failure(record, exc)
        await _mark_processing_failed(
            service.session,
            record.id,
            code=exc.code,
            message=message,
            retryable=True,
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"code": exc.code, "message": message},
        ) from exc
    except OpenAIUnavailableError as exc:
        message = "AI report generation is temporarily unavailable. Please try again."
        logger.error(
            "OpenAI failed upload_id=%s stage=%s exception_type=%s",
            record.id,
            record.processing_stage,
            type(exc).__name__,
        )
        await _mark_processing_failed(
            service.session,
            record.id,
            code="openai_unavailable",
            message=message,
            retryable=True,
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"code": "openai_unavailable", "message": message},
        ) from exc
    except AudioAIPersistenceError as exc:
        message = "The recording could not be processed. Please try again."
        logger.exception("Audio AI persistence failed upload_id=%s", record.id)
        await _mark_processing_failed(
            service.session,
            record.id,
            code="persistence_failed",
            message=message,
            retryable=True,
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"code": "persistence_failed", "message": message},
        ) from exc
    except Exception as exc:
        message = "The recording could not be processed."
        logger.exception(
            "Unexpected audio processing failure upload_id=%s stage=%s exception_type=%s",
            record.id,
            record.processing_stage,
            type(exc).__name__,
        )
        await _mark_processing_failed(
            service.session,
            record.id,
            code="processing_failed",
            message=message,
            retryable=True,
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"code": "processing_failed", "message": message},
        ) from exc


def _log_sarvam_failure(record: AudioUpload, exc) -> None:
    logger.error(
        "Sarvam failed upload_id=%s stage=%s exception_type=%s status=%s "
        "request_id=%s provider_code=%s provider_message=%s container=%s "
        "codec=%s duration_seconds=%s file_size=%s selected_language=%s "
        "strategy=%s retryable=%s job_id=%s",
        record.id,
        record.processing_stage,
        type(exc).__name__,
        exc.status_code,
        exc.request_id,
        exc.provider_code,
        exc.provider_message,
        record.audio_container,
        record.audio_codec,
        record.audio_duration_seconds,
        record.size_bytes,
        record.language_code,
        exc.strategy or record.transcription_strategy,
        exc.retryable,
        exc.job_id or record.provider_job_id,
    )


async def _mark_processing_failed(
    session: AsyncSession,
    upload_id: uuid.UUID,
    *,
    code: str,
    message: str,
    retryable: bool,
) -> None:
    """Leave retryable metadata after an AI/storage failure without masking it."""
    try:
        await session.rollback()
        record = await session.get(AudioUpload, upload_id)
        if record is not None and record.status in {"processing", "ready"}:
            record.failure_stage = record.processing_stage
            record.failure_code = code
            record.failure_message = message[:255]
            record.retryable = retryable
            record.processing_stage = "failed"
            record.status = "failed"
            await session.commit()
    except Exception:
        await session.rollback()


@router.post(
    "/{upload_id}/retry",
    response_model=AudioUploadProcessingResponse,
    summary="Retry failed AI processing without uploading audio again",
)
async def retry_audio_processing(
    upload_id: uuid.UUID,
    current_user: CurrentUser,
    service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
    pipeline: Annotated[AudioAIPipeline, Depends(get_audio_ai_pipeline)],
    workspace_id: Annotated[uuid.UUID, Query()],
    location_id: Annotated[uuid.UUID, Query()],
) -> AudioUploadProcessingResponse:
    try:
        location = await WorkspaceService(service.session).require_location(
            user_id=current_user.id,
            workspace_id=workspace_id,
            location_id=location_id,
        )
    except WorkspaceNotFoundError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Audio upload not found",
        )
    record = await service.get_for_location(
        upload_id=upload_id,
        workspace_id=workspace_id,
        location_id=location_id,
    )
    if record is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Audio upload not found",
        )
    if record.status == "quarantined":
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="The recording cannot be processed.",
        )
    if record.status == "failed" and not record.retryable:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "code": record.failure_code or "not_retryable",
                "message": record.failure_message
                or "The recording could not be processed.",
            },
        )
    result = await _execute_pipeline(
        service=service,
        pipeline=pipeline,
        record=record,
        location=location,
        language_code=record.language_code or "unknown",
    )

    return _processing_response(record, location, result)


@router.get("", response_model=AudioUploadListResponse, summary="List uploaded audio")
async def list_audio_uploads(
    current_user: CurrentUser,
    service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
    workspace_id: Annotated[uuid.UUID, Query()],
    location_id: Annotated[uuid.UUID, Query()],
    limit: Annotated[int, Query(ge=1, le=50)] = 50,
) -> AudioUploadListResponse:
    try:
        await WorkspaceService(service.session).require_location(
            user_id=current_user.id,
            workspace_id=workspace_id,
            location_id=location_id,
        )
    except WorkspaceNotFoundError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="The selected restaurant location could not be found.",
        )
    rows = await service.list_for_location(
        workspace_id=workspace_id,
        location_id=location_id,
        limit=limit,
    )
    return AudioUploadListResponse(
        items=[
            AudioUploadHistoryResponse(
                id=upload.id,
                location_id=upload.location_id,
                language_code=upload.language_code,
                detected_language_code=upload.detected_language_code,
                processing_stage=upload.processing_stage,
                failure_stage=upload.failure_stage,
                failure_code=upload.failure_code,
                failure_message=upload.failure_message,
                retryable=upload.retryable,
                audio_container=upload.audio_container,
                audio_codec=upload.audio_codec,
                audio_duration_seconds=upload.audio_duration_seconds,
                audio_sample_rate=upload.audio_sample_rate,
                audio_channels=upload.audio_channels,
                transcription_strategy=upload.transcription_strategy,
                sarvam_model=upload.sarvam_model,
                sarvam_estimated_cost_inr=upload.sarvam_estimated_cost_inr,
                openai_model=upload.openai_model,
                openai_input_tokens=upload.openai_input_tokens,
                openai_cached_input_tokens=upload.openai_cached_input_tokens,
                openai_output_tokens=upload.openai_output_tokens,
                openai_total_tokens=upload.openai_total_tokens,
                openai_estimated_cost_usd=upload.openai_estimated_cost_usd,
                total_estimated_cost=upload.total_estimated_cost,
                original_filename=upload.original_filename,
                media_type=upload.media_type,
                extension=upload.extension,
                size_bytes=upload.size_bytes,
                status=upload.status,
                scan_status=upload.scan_status,
                created_at=upload.created_at,
                updated_at=upload.updated_at,
                transcript_available=bool(
                    upload.english_transcript or report is not None
                ),
                report_id=report.id if report else None,
                severity=report.severity if report else None,
                processed_at=(
                    report.processed_at if report else upload.processed_at
                ),
                location_name=location_name,
                source=report.source if report else None,
            )
            for upload, report, location_name in rows
        ]
    )


def _processing_response(
    record: AudioUpload,
    location: ReportLocation,
    result,
) -> AudioUploadProcessingResponse:
    return AudioUploadProcessingResponse(
        id=record.id,
        location_id=record.location_id,
        language_code=record.language_code,
        detected_language_code=record.detected_language_code,
        processing_stage=record.processing_stage,
        failure_stage=record.failure_stage,
        failure_code=record.failure_code,
        failure_message=record.failure_message,
        retryable=record.retryable,
        audio_container=record.audio_container,
        audio_codec=record.audio_codec,
        audio_duration_seconds=record.audio_duration_seconds,
        audio_sample_rate=record.audio_sample_rate,
        audio_channels=record.audio_channels,
        transcription_strategy=record.transcription_strategy,
        sarvam_model=record.sarvam_model,
        sarvam_estimated_cost_inr=record.sarvam_estimated_cost_inr,
        openai_model=record.openai_model,
        openai_input_tokens=record.openai_input_tokens,
        openai_cached_input_tokens=record.openai_cached_input_tokens,
        openai_output_tokens=record.openai_output_tokens,
        openai_total_tokens=record.openai_total_tokens,
        openai_estimated_cost_usd=record.openai_estimated_cost_usd,
        total_estimated_cost=record.total_estimated_cost,
        original_filename=record.original_filename,
        media_type=record.media_type,
        extension=record.extension,
        size_bytes=record.size_bytes,
        status=record.status,
        scan_status=record.scan_status,
        created_at=record.created_at,
        updated_at=record.updated_at,
        transcript=result.transcript,
        analysis=result.analysis,
        activity_id=result.activity_id,
        report_id=result.report_id,
        workspace_id=location.workspace_id,
        location_name=location.name,
        processed_at=result.processed_at,
        source=result.source,
    )


@router.get("/{upload_id}/audio", summary="Stream a stored audio recording")
async def stream_audio_upload(
    upload_id: uuid.UUID,
    current_user: CurrentUser,
    service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
    workspace_id: Annotated[uuid.UUID, Query()],
    location_id: Annotated[uuid.UUID, Query()],
) -> StreamingResponse:
    try:
        await WorkspaceService(service.session).require_location(
            user_id=current_user.id,
            workspace_id=workspace_id,
            location_id=location_id,
        )
    except WorkspaceNotFoundError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Audio upload not found",
        )
    record = await service.get_playable_for_location(
        upload_id=upload_id,
        workspace_id=workspace_id,
        location_id=location_id,
    )
    if record is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Audio upload not found",
        )
    return _audio_response(service, record, disposition="inline")


@router.get("/{upload_id}/download", summary="Download an uploaded audio file")
async def download_audio_upload(
    upload_id: uuid.UUID,
    current_user: CurrentUser,
    service: Annotated[AudioUploadService, Depends(get_audio_upload_service)],
    workspace_id: Annotated[uuid.UUID, Query()],
    location_id: Annotated[uuid.UUID, Query()],
) -> StreamingResponse:
    try:
        await WorkspaceService(service.session).require_location(
            user_id=current_user.id,
            workspace_id=workspace_id,
            location_id=location_id,
        )
    except WorkspaceNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Location not found")
    record = await service.get_ready_for_location(
        upload_id=upload_id,
        workspace_id=workspace_id,
        location_id=location_id,
    )
    if record is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Audio upload not found",
        )
    return _audio_response(service, record, disposition="attachment")


def _audio_response(
    service: AudioUploadService,
    record: AudioUpload,
    *,
    disposition: str,
) -> StreamingResponse:
    download_name = f"audio-{record.id}.{record.extension}"
    return StreamingResponse(
        service.storage.iter_bytes(record.storage_key),
        media_type=record.media_type,
        headers={
            "Content-Disposition": f'{disposition}; filename="{download_name}"',
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
    workspace_id: Annotated[uuid.UUID, Query()],
    location_id: Annotated[uuid.UUID, Query()],
) -> Response:
    try:
        await WorkspaceService(service.session).require_location(
            user_id=current_user.id,
            workspace_id=workspace_id,
            location_id=location_id,
        )
    except WorkspaceNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Location not found")
    try:
        deleted = await service.delete_for_owner(
            owner_id=current_user.id,
            upload_id=upload_id,
            workspace_id=workspace_id,
            location_id=location_id,
        )
    except AudioUploadUnavailableError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(exc),
        )
    if not deleted:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Audio upload not found",
        )
    return Response(status_code=status.HTTP_204_NO_CONTENT)
