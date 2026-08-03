import asyncio
import hashlib
import uuid
from pathlib import Path

from fastapi import UploadFile
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from backend.models.audio_upload import AudioUpload
from backend.models.user import User
from backend.services.audio_validation import (
    UnsupportedAudioError,
    sanitize_filename,
    validate_audio,
)
from backend.services.virus_scanner import (
    AudioScanError,
    AudioVirusScanner,
    ScanVerdict,
)
from backend.storage.audio_storage import AudioObjectStorage

UPLOAD_CHUNK_SIZE = 1024 * 1024


class EmptyAudioUploadError(ValueError):
    pass


class AudioUploadTooLargeError(ValueError):
    pass


class DuplicateAudioUploadError(ValueError):
    pass


class InfectedAudioUploadError(ValueError):
    pass


class AudioUploadUnavailableError(RuntimeError):
    pass


class AudioUploadService:
    def __init__(
        self,
        *,
        session: AsyncSession,
        storage: AudioObjectStorage,
        scanner: AudioVirusScanner,
        max_upload_bytes: int,
    ) -> None:
        self.session = session
        self.storage = storage
        self.scanner = scanner
        self.max_upload_bytes = max_upload_bytes

    async def upload(self, *, owner: User, file: UploadFile) -> AudioUpload:
        temporary_path: Path | None = None
        stored_key_to_cleanup: str | None = None
        record: AudioUpload | None = None
        try:
            temporary_path = self.storage.create_temporary_path()
            try:
                size_bytes, sha256, prefix = await self._stream_to_temporary(file, temporary_path)
            except OSError as exc:
                raise AudioUploadUnavailableError("Audio storage is unavailable") from exc
            detected = validate_audio(
                prefix=prefix,
                filename=file.filename,
                client_media_type=file.content_type,
            )
            safe_filename = sanitize_filename(file.filename)

            existing = await self._find_duplicate(owner.id, sha256)
            if existing is not None and existing.status != "failed":
                raise DuplicateAudioUploadError("This audio file has already been uploaded")

            if existing is None:
                record = AudioUpload(
                    owner_id=owner.id,
                    original_filename=safe_filename,
                    storage_key=f"{owner.id.hex}/{uuid.uuid4().hex}.{detected.extension}",
                    media_type=detected.media_type,
                    extension=detected.extension,
                    size_bytes=size_bytes,
                    sha256=sha256,
                    status="processing",
                    scan_status="not_configured",
                )
                self.session.add(record)
            else:
                record = existing
                record.original_filename = safe_filename
                record.media_type = detected.media_type
                record.extension = detected.extension
                record.size_bytes = size_bytes
                record.status = "processing"
                record.scan_status = "not_configured"

            try:
                await self.session.commit()
                await self.session.refresh(record)
            except IntegrityError as exc:
                await self.session.rollback()
                raise DuplicateAudioUploadError(
                    "This audio file has already been uploaded"
                ) from exc

            try:
                verdict = await self.scanner.scan(temporary_path)
            except AudioScanError as exc:
                record.status = "failed"
                record.scan_status = "error"
                await self.session.commit()
                raise AudioUploadUnavailableError("Audio scanning is unavailable") from exc

            record.scan_status = verdict.value
            if verdict is ScanVerdict.INFECTED:
                record.status = "quarantined"
                await self.session.commit()
                raise InfectedAudioUploadError("The audio upload did not pass its security scan")

            stored_key_to_cleanup = record.storage_key
            try:
                await self.storage.save(temporary_path, record.storage_key)
                temporary_path = None
            except Exception as exc:
                record.status = "failed"
                await self.session.commit()
                raise AudioUploadUnavailableError("Audio storage is unavailable") from exc

            record.status = "ready"
            await self.session.commit()
            await self.session.refresh(record)
            stored_key_to_cleanup = None
            return record
        finally:
            await file.close()
            await self.storage.discard_temporary(temporary_path)
            if stored_key_to_cleanup is not None:
                await self.storage.delete(stored_key_to_cleanup)

    async def list_for_owner(self, *, owner_id: uuid.UUID, limit: int) -> list[AudioUpload]:
        result = await self.session.execute(
            select(AudioUpload)
            .where(AudioUpload.owner_id == owner_id)
            .order_by(AudioUpload.created_at.desc(), AudioUpload.id.desc())
            .limit(limit)
        )
        return list(result.scalars())

    async def get_ready_for_owner(
        self,
        *,
        owner_id: uuid.UUID,
        upload_id: uuid.UUID,
    ) -> AudioUpload | None:
        result = await self.session.execute(
            select(AudioUpload).where(
                AudioUpload.id == upload_id,
                AudioUpload.owner_id == owner_id,
                AudioUpload.status == "ready",
            )
        )
        record = result.scalar_one_or_none()
        if record is None or not await self.storage.exists(record.storage_key):
            return None
        return record

    async def get_for_owner(
        self,
        *,
        owner_id: uuid.UUID,
        upload_id: uuid.UUID,
    ) -> AudioUpload | None:
        result = await self.session.execute(
            select(AudioUpload).where(
                AudioUpload.id == upload_id,
                AudioUpload.owner_id == owner_id,
            )
        )
        return result.scalar_one_or_none()

    async def delete_for_owner(
        self,
        *,
        owner_id: uuid.UUID,
        upload_id: uuid.UUID,
    ) -> bool:
        record = await self.get_for_owner(owner_id=owner_id, upload_id=upload_id)
        if record is None:
            return False
        try:
            await self.storage.delete(record.storage_key)
        except Exception as exc:
            raise AudioUploadUnavailableError("Audio storage is unavailable") from exc
        await self.session.delete(record)
        await self.session.commit()
        return True

    async def _find_duplicate(
        self,
        owner_id: uuid.UUID,
        sha256: str,
    ) -> AudioUpload | None:
        result = await self.session.execute(
            select(AudioUpload).where(
                AudioUpload.owner_id == owner_id,
                AudioUpload.sha256 == sha256,
            )
        )
        return result.scalar_one_or_none()

    async def _stream_to_temporary(
        self,
        file: UploadFile,
        temporary_path: Path,
    ) -> tuple[int, str, bytes]:
        digest = hashlib.sha256()
        prefix = bytearray()
        size_bytes = 0
        handle = temporary_path.open("wb")
        try:
            while chunk := await file.read(UPLOAD_CHUNK_SIZE):
                size_bytes += len(chunk)
                if size_bytes > self.max_upload_bytes:
                    raise AudioUploadTooLargeError(
                        f"Audio uploads cannot exceed {self.max_upload_bytes} bytes"
                    )
                digest.update(chunk)
                if len(prefix) < 64:
                    prefix.extend(chunk[: 64 - len(prefix)])
                await asyncio.to_thread(handle.write, chunk)
        finally:
            await asyncio.to_thread(handle.close)

        if size_bytes == 0:
            raise EmptyAudioUploadError("Audio upload cannot be empty")
        return size_bytes, digest.hexdigest(), bytes(prefix)
