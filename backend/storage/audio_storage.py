import asyncio
import os
import re
import uuid
from abc import ABC, abstractmethod
from collections.abc import AsyncIterator
from pathlib import Path


class InvalidStorageKeyError(ValueError):
    pass


class AudioObjectNotFoundError(FileNotFoundError):
    pass


class AudioObjectStorage(ABC):
    @abstractmethod
    def create_temporary_path(self) -> Path:
        raise NotImplementedError

    @abstractmethod
    async def save(self, temporary_path: Path, storage_key: str) -> None:
        raise NotImplementedError

    @abstractmethod
    async def iter_bytes(
        self, storage_key: str, chunk_size: int = 1024 * 1024
    ) -> AsyncIterator[bytes]:
        raise NotImplementedError

    @abstractmethod
    async def exists(self, storage_key: str) -> bool:
        raise NotImplementedError

    @abstractmethod
    async def delete(self, storage_key: str) -> None:
        raise NotImplementedError

    @abstractmethod
    async def discard_temporary(self, temporary_path: Path | None) -> None:
        raise NotImplementedError

    @abstractmethod
    def get_path(self, storage_key: str) -> Path:
        """Return a validated local path or reject unsupported storage adapters."""
        raise NotImplementedError


class LocalAudioStorage(AudioObjectStorage):
    _KEY_PATTERN = re.compile(
        r"^[0-9a-f]{32}/[0-9a-f]{32}\.(?:mp3|wav|m4a|aac|ogg|opus|mp4)$"
    )

    def __init__(self, root: str | Path) -> None:
        self.root = Path(root).resolve()
        self.temporary_root = (self.root / ".tmp").resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.temporary_root.mkdir(parents=True, exist_ok=True, mode=0o700)

    def create_temporary_path(self) -> Path:
        path = (self.temporary_root / f"{uuid.uuid4().hex}.part").resolve()
        self._require_contained(path)
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(descriptor)
        return path

    async def save(self, temporary_path: Path, storage_key: str) -> None:
        source = temporary_path.resolve()
        self._require_temporary(source)
        destination = self._resolve_key(storage_key)
        await asyncio.to_thread(
            destination.parent.mkdir,
            parents=True,
            exist_ok=True,
            mode=0o700,
        )
        await asyncio.to_thread(os.replace, source, destination)

    async def iter_bytes(
        self,
        storage_key: str,
        chunk_size: int = 1024 * 1024,
    ) -> AsyncIterator[bytes]:
        if chunk_size <= 0:
            raise ValueError("chunk_size must be positive")
        path = self._resolve_key(storage_key)
        try:
            handle = await asyncio.to_thread(path.open, "rb")
        except FileNotFoundError as exc:
            raise AudioObjectNotFoundError(storage_key) from exc
        try:
            while chunk := await asyncio.to_thread(handle.read, chunk_size):
                yield chunk
        finally:
            await asyncio.to_thread(handle.close)

    async def exists(self, storage_key: str) -> bool:
        return await asyncio.to_thread(self._resolve_key(storage_key).is_file)

    async def delete(self, storage_key: str) -> None:
        path = self._resolve_key(storage_key)
        try:
            await asyncio.to_thread(path.unlink)
        except FileNotFoundError:
            return

    async def discard_temporary(self, temporary_path: Path | None) -> None:
        if temporary_path is None:
            return
        path = temporary_path.resolve()
        self._require_temporary(path)
        try:
            await asyncio.to_thread(path.unlink)
        except FileNotFoundError:
            return

    def get_path(self, storage_key: str) -> Path:
        path = self._resolve_key(storage_key)
        if not path.is_file():
            raise AudioObjectNotFoundError(storage_key)
        return path

    def _resolve_key(self, storage_key: str) -> Path:
        if not self._KEY_PATTERN.fullmatch(storage_key):
            raise InvalidStorageKeyError("Invalid audio storage key")
        path = (self.root / storage_key).resolve()
        self._require_contained(path)
        return path

    def _require_contained(self, path: Path) -> None:
        try:
            path.relative_to(self.root)
        except ValueError as exc:
            raise InvalidStorageKeyError("Audio storage path escaped its root") from exc

    def _require_temporary(self, path: Path) -> None:
        try:
            path.relative_to(self.temporary_root)
        except ValueError as exc:
            raise InvalidStorageKeyError("Temporary audio path escaped its root") from exc
