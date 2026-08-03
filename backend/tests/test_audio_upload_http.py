import tempfile
import unittest
from pathlib import Path
from typing import AsyncIterator

from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.api.routes.audio_uploads import (
    get_audio_max_upload_bytes,
    get_audio_scanner,
    get_audio_storage,
)
from backend.auth.security import create_access_token, hash_password
from backend.database.base import Base
from backend.database.session import get_db
from backend.main import app
from backend.models.user import User
from backend.services.virus_scanner import (
    AudioScanError,
    AudioVirusScanner,
    ScanVerdict,
)
from backend.storage.audio_storage import LocalAudioStorage

_DEFAULT_HEADERS = object()


class _VerdictScanner(AudioVirusScanner):
    def __init__(self, verdict: ScanVerdict) -> None:
        self.verdict = verdict

    async def scan(self, path: Path) -> ScanVerdict:
        self.last_scanned_path = path
        return self.verdict


class _ErrorScanner(AudioVirusScanner):
    async def scan(self, path: Path) -> ScanVerdict:
        raise AudioScanError("scanner offline")


class _FailingStorage(LocalAudioStorage):
    async def save(self, temporary_path: Path, storage_key: str) -> None:
        raise OSError("storage offline")


class AudioUploadHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        root = Path(self.temp_directory.name)
        database_path = root / "audio-http.db"
        self.storage_root = root / "audio-objects"
        self.storage = LocalAudioStorage(self.storage_root)
        self.engine = create_async_engine(f"sqlite+aiosqlite:///{database_path.as_posix()}")
        self.session_factory = async_sessionmaker(
            bind=self.engine,
            class_=AsyncSession,
            expire_on_commit=False,
        )
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

        async with self.session_factory() as session:
            self.user = User(
                email="audio-owner@example.com",
                full_name="Audio Owner",
                hashed_password=hash_password("AudioTestPassword123!"),
                is_active=True,
            )
            self.other_user = User(
                email="other-audio-owner@example.com",
                full_name="Other Audio Owner",
                hashed_password=hash_password("AudioTestPassword123!"),
                is_active=True,
            )
            session.add_all([self.user, self.other_user])
            await session.commit()
            await session.refresh(self.user)
            await session.refresh(self.other_user)

        async def override_database() -> AsyncIterator[AsyncSession]:
            async with self.session_factory() as session:
                yield session

        app.dependency_overrides[get_db] = override_database
        app.dependency_overrides[get_audio_storage] = lambda: self.storage
        app.dependency_overrides[get_audio_scanner] = lambda: _VerdictScanner(ScanVerdict.CLEAN)
        self.client = AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://testserver",
        )
        self.headers = {"Authorization": f"Bearer {create_access_token(str(self.user.id))}"}
        self.other_headers = {
            "Authorization": f"Bearer {create_access_token(str(self.other_user.id))}"
        }

    async def asyncTearDown(self) -> None:
        await self.client.aclose()
        app.dependency_overrides.clear()
        await self.engine.dispose()
        self.temp_directory.cleanup()

    async def test_all_audio_routes_require_authentication(self) -> None:
        upload_response = await self._upload(headers=None)
        list_response = await self.client.get("/api/v1/audio-uploads")
        download_response = await self.client.get(
            "/api/v1/audio-uploads/00000000-0000-0000-0000-000000000001/download"
        )
        delete_response = await self.client.delete(
            "/api/v1/audio-uploads/00000000-0000-0000-0000-000000000001"
        )

        self.assertEqual(upload_response.status_code, 401)
        self.assertEqual(list_response.status_code, 401)
        self.assertEqual(download_response.status_code, 401)
        self.assertEqual(delete_response.status_code, 401)

    async def test_upload_list_download_and_delete_lifecycle(self) -> None:
        upload_response = await self._upload(
            filename="..\\private\\shift-note.mp3",
            content=b"ID3\x04\x00\x00restaurant audio",
        )

        self.assertEqual(upload_response.status_code, 201, upload_response.text)
        payload = upload_response.json()
        self.assertEqual(payload["original_filename"], "shift-note.mp3")
        self.assertEqual(payload["media_type"], "audio/mpeg")
        self.assertEqual(payload["extension"], "mp3")
        self.assertEqual(payload["status"], "ready")
        self.assertEqual(payload["scan_status"], "clean")
        self.assertNotIn("owner_id", payload)
        self.assertNotIn("storage_key", payload)
        self.assertNotIn("sha256", payload)

        list_response = await self.client.get("/api/v1/audio-uploads", headers=self.headers)
        self.assertEqual(list_response.status_code, 200)
        self.assertEqual(list_response.json()["items"], [payload])

        upload_id = payload["id"]
        download_response = await self.client.get(
            f"/api/v1/audio-uploads/{upload_id}/download",
            headers=self.headers,
        )
        self.assertEqual(download_response.status_code, 200)
        self.assertEqual(download_response.content, b"ID3\x04\x00\x00restaurant audio")
        self.assertEqual(download_response.headers["content-type"], "audio/mpeg")
        self.assertEqual(
            download_response.headers["content-disposition"],
            f'attachment; filename="audio-{upload_id}.mp3"',
        )
        self.assertEqual(download_response.headers["cache-control"], "private, no-store")
        self.assertEqual(download_response.headers["x-content-type-options"], "nosniff")

        delete_response = await self.client.delete(
            f"/api/v1/audio-uploads/{upload_id}",
            headers=self.headers,
        )
        self.assertEqual(delete_response.status_code, 204)
        self.assertEqual(list(self.storage_root.rglob("*.mp3")), [])
        self.assertEqual(
            (await self.client.get("/api/v1/audio-uploads", headers=self.headers)).json()["items"],
            [],
        )

    async def test_other_owner_records_are_indistinguishable_from_missing(self) -> None:
        payload = (await self._upload()).json()
        upload_id = payload["id"]

        other_list = await self.client.get("/api/v1/audio-uploads", headers=self.other_headers)
        other_download = await self.client.get(
            f"/api/v1/audio-uploads/{upload_id}/download",
            headers=self.other_headers,
        )
        other_delete = await self.client.delete(
            f"/api/v1/audio-uploads/{upload_id}",
            headers=self.other_headers,
        )

        self.assertEqual(other_list.json(), {"items": []})
        self.assertEqual(other_download.status_code, 404)
        self.assertEqual(other_delete.status_code, 404)
        self.assertEqual(
            (await self.client.get("/api/v1/audio-uploads", headers=self.headers)).json()["items"][0]["id"],
            upload_id,
        )

    async def test_duplicate_prevention_is_scoped_to_owner(self) -> None:
        content = b"ID3\x04\x00\x00same audio"
        first = await self._upload(content=content)
        duplicate = await self._upload(filename="renamed.mp3", content=content)
        other_owner = await self._upload(content=content, headers=self.other_headers)

        self.assertEqual(first.status_code, 201)
        self.assertEqual(duplicate.status_code, 409)
        self.assertEqual(other_owner.status_code, 201)

    async def test_rejects_empty_oversized_unsupported_and_mismatched_files(self) -> None:
        app.dependency_overrides[get_audio_max_upload_bytes] = lambda: 12
        cases = (
            ("empty.mp3", b"", "audio/mpeg", 422),
            ("large.mp3", b"ID3\x04\x00\x00too-large", "audio/mpeg", 413),
            ("script.exe", b"ID3\x04\x00\x00", "audio/mpeg", 415),
            ("fake.mp3", b"notaudio", "audio/mpeg", 415),
            ("fake.wav", b"ID3\x04\x00\x00", "audio/wav", 415),
            ("recording.mp3", b"ID3\x04\x00\x00", "audio/wav", 415),
        )

        for filename, content, media_type, expected_status in cases:
            with self.subTest(filename=filename):
                response = await self._upload(
                    filename=filename,
                    content=content,
                    media_type=media_type,
                )
                self.assertEqual(response.status_code, expected_status, response.text)
                self.assertEqual(list((self.storage_root / ".tmp").glob("*.part")), [])

    async def test_infected_scan_quarantines_metadata_and_leaves_no_file(self) -> None:
        app.dependency_overrides[get_audio_scanner] = lambda: _VerdictScanner(ScanVerdict.INFECTED)

        response = await self._upload()

        self.assertEqual(response.status_code, 422)
        history = (await self.client.get("/api/v1/audio-uploads", headers=self.headers)).json()
        self.assertEqual(history["items"][0]["status"], "quarantined")
        self.assertEqual(history["items"][0]["scan_status"], "infected")
        self.assertEqual(list(self.storage_root.rglob("*.mp3")), [])
        self.assertEqual(list((self.storage_root / ".tmp").glob("*.part")), [])

    async def test_scanner_and_storage_failures_are_retryable_and_clean_partials(self) -> None:
        app.dependency_overrides[get_audio_scanner] = lambda: _ErrorScanner()
        scan_content = b"ID3\x04\x00\x00scan-failure"
        scan_response = await self._upload(content=scan_content)
        self.assertEqual(scan_response.status_code, 503)
        self.assertEqual(list((self.storage_root / ".tmp").glob("*.part")), [])

        app.dependency_overrides[get_audio_scanner] = lambda: _VerdictScanner(ScanVerdict.CLEAN)
        retry_response = await self._upload(content=scan_content)
        self.assertEqual(retry_response.status_code, 201, retry_response.text)

        failing_root = Path(self.temp_directory.name) / "failing-objects"
        failing_storage = _FailingStorage(failing_root)
        app.dependency_overrides[get_audio_storage] = lambda: failing_storage
        app.dependency_overrides[get_audio_scanner] = lambda: _VerdictScanner(ScanVerdict.CLEAN)
        storage_response = await self._upload(content=b"ID3\x04\x00\x00storage-failure")
        self.assertEqual(storage_response.status_code, 503)
        self.assertEqual(list((failing_root / ".tmp").glob("*.part")), [])
        self.assertEqual(list(failing_root.rglob("*.mp3")), [])

    async def test_history_limit_is_bounded(self) -> None:
        response = await self.client.get(
            "/api/v1/audio-uploads",
            params={"limit": 51},
            headers=self.headers,
        )
        self.assertEqual(response.status_code, 422)

    async def _upload(
        self,
        *,
        filename: str = "recording.mp3",
        content: bytes = b"ID3\x04\x00\x00audio data",
        media_type: str = "audio/mpeg",
        headers: dict[str, str] | None | object = _DEFAULT_HEADERS,
    ):
        request_headers = self.headers if headers is _DEFAULT_HEADERS else headers
        return await self.client.post(
            "/api/v1/audio-uploads",
            headers=request_headers,
            files={"file": (filename, content, media_type)},
        )


if __name__ == "__main__":
    unittest.main()
