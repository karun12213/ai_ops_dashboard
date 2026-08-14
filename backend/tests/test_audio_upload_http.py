import tempfile
import unittest
import uuid
from contextlib import asynccontextmanager
from datetime import timezone
from decimal import Decimal
from pathlib import Path
from typing import AsyncIterator

from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.api.routes.audio_uploads import (
    get_audio_ai_pipeline,
    get_audio_max_upload_bytes,
    get_audio_scanner,
    get_audio_storage,
)
from backend.auth.security import create_access_token, hash_password
from backend.database.base import Base
from backend.database.session import get_db
from backend.main import app
from backend.models.audio_upload import AudioUpload
from backend.models.dashboard import DashboardActivity
from backend.models.report import AudioOperationsReport, ReportLocation
from backend.models.user import User
from backend.models.workspace import Workspace, WorkspaceMembership
from backend.services.audio_ai_pipeline import AudioAIPipeline
from backend.services.audio_processing import AudioProbe, PreparedAudio
from backend.services.openai_service import (
    OpenAIAnalysisResult,
    OpenAIResponseUsage,
    OpenAIUnavailableError,
)
from backend.services.sarvam_service import SarvamTranscript, SarvamUnavailableError
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


class _Transcriber:
    async def transcribe_to_english(self, *, audio_path: Path, language_code: str) -> str:
        if not audio_path.is_file():
            raise AssertionError("The pipeline did not receive a stored audio path")
        self.language_code = language_code
        return "The dinner station is running low on clean plates."


class _UnavailableTranscriber:
    async def transcribe_to_english(self, *, audio_path: Path, language_code: str) -> str:
        raise SarvamUnavailableError("provider detail that must remain private")


class _Analyzer:
    async def analyze_transcript(self, transcript: str) -> dict:
        return {
            "summary": "Restock clean plates at the dinner station",
            "category": "inventory",
            "severity": "high",
            "requires_attention": True,
            "recommended_action": "Move clean plates to the station now.",
        }


class _MeteredTranscriber:
    model = "saaras:v3"
    cost_per_audio_hour_inr = Decimal("30.00")

    async def transcribe_to_english(self, **_: object) -> SarvamTranscript:
        return SarvamTranscript(
            english_text="The dinner station is running low on clean plates.",
            detected_language_code="ne-IN",
            request_id="sarvam-request-1",
            strategy="short_rest",
            provider_job_id="sarvam-job-1",
            model=self.model,
        )


class _MeteredAnalyzer:
    async def analyze_transcript_with_usage(self, transcript: str, *, on_usage):
        calls = [
            OpenAIResponseUsage(
                input_tokens=100,
                cached_input_tokens=20,
                output_tokens=10,
                total_tokens=110,
                model="gpt-4o-2024-11-20",
                request_id="openai-request-1",
                estimated_cost_usd=Decimal("0.00032500"),
                request_ids=("openai-request-1",),
            ),
            OpenAIResponseUsage(
                input_tokens=50,
                cached_input_tokens=0,
                output_tokens=5,
                total_tokens=55,
                model="gpt-4o-2024-11-20",
                request_id="openai-request-final",
                estimated_cost_usd=Decimal("0.00017500"),
                request_ids=("openai-request-final",),
            ),
        ]
        for usage in calls:
            await on_usage(usage)
        return OpenAIAnalysisResult(
            analysis=await _Analyzer().analyze_transcript(transcript),
            usage=OpenAIResponseUsage.aggregate(calls),
        )


class _UnavailableAnalyzer:
    async def analyze_transcript(self, transcript: str) -> dict:
        raise OpenAIUnavailableError("private OpenAI failure detail")


class _MustNotTranscribe:
    async def transcribe_to_english(self, **_: object) -> str:
        raise AssertionError("A persisted English transcript should have been reused")


class _UnexpectedPipeline:
    async def process_audio(self, **_: object) -> None:
        raise RuntimeError("sensitive internal processing detail")


class _PassThroughNormalizer:
    async def probe(self, audio_path: Path) -> AudioProbe:
        return AudioProbe(
            container="mp3",
            codec="mp3",
            duration_seconds=2.0,
            sample_rate=16000,
            channels=1,
            size_bytes=audio_path.stat().st_size,
        )

    @asynccontextmanager
    async def prepare(self, audio_path: Path, *, probe, on_stage=None):
        if on_stage is not None:
            await on_stage("normalizing")
        yield PreparedAudio(path=audio_path, probe=probe)


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
            await session.flush()
            self.workspace = Workspace(name="Audio Workspace")
            self.other_workspace = Workspace(name="Other Audio Workspace")
            session.add_all([self.workspace, self.other_workspace])
            await session.flush()
            self.location = ReportLocation(
                workspace_id=self.workspace.id,
                name="Main Floor",
                currency_code="INR",
            )
            self.other_location = ReportLocation(
                workspace_id=self.other_workspace.id,
                name="Other Floor",
                currency_code="INR",
            )
            session.add_all([self.location, self.other_location])
            session.add_all(
                [
                    WorkspaceMembership(
                        workspace_id=self.workspace.id,
                        user_id=self.user.id,
                        role="owner",
                    ),
                    WorkspaceMembership(
                        workspace_id=self.other_workspace.id,
                        user_id=self.other_user.id,
                        role="owner",
                    ),
                ]
            )
            await session.commit()
            for item in (
                self.user,
                self.other_user,
                self.workspace,
                self.other_workspace,
                self.location,
                self.other_location,
            ):
                await session.refresh(item)

        async def override_database() -> AsyncIterator[AsyncSession]:
            async with self.session_factory() as session:
                try:
                    yield session
                except Exception:
                    await session.rollback()
                    raise

        app.dependency_overrides[get_db] = override_database
        app.dependency_overrides[get_audio_storage] = lambda: self.storage
        app.dependency_overrides[get_audio_scanner] = lambda: _VerdictScanner(
            ScanVerdict.CLEAN
        )
        app.dependency_overrides[get_audio_ai_pipeline] = lambda: AudioAIPipeline(
            sarvam=_Transcriber(),
            openai_service=_Analyzer(),
            normalizer=_PassThroughNormalizer(),
        )
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
        audio_response = await self.client.get(
            "/api/v1/audio-uploads/00000000-0000-0000-0000-000000000001/audio"
        )
        self.assertEqual(audio_response.status_code, 401)

    async def test_upload_ai_dashboard_download_and_delete_lifecycle(self) -> None:
        upload_response = await self._upload(
            filename="..\\private\\shift-note.mp3",
            content=b"ID3\x04\x00\x00restaurant audio",
            language_code="ne-IN",
        )

        self.assertEqual(upload_response.status_code, 201, upload_response.text)
        payload = upload_response.json()
        self.assertEqual(payload["original_filename"], "shift-note.mp3")
        self.assertEqual(payload["media_type"], "audio/mpeg")
        self.assertEqual(payload["extension"], "mp3")
        self.assertEqual(payload["status"], "ready")
        self.assertEqual(payload["scan_status"], "clean")
        self.assertEqual(payload["analysis"]["category"], "inventory")
        self.assertTrue(payload["transcript"])
        self.assertTrue(payload["activity_id"])
        self.assertTrue(payload["report_id"])
        self.assertEqual(payload["workspace_id"], str(self.workspace.id))
        self.assertEqual(payload["location_id"], str(self.location.id))
        self.assertEqual(payload["location_name"], self.location.name)
        self.assertEqual(payload["source"], "AI Audio Monitor")
        self.assertNotIn("owner_id", payload)
        self.assertNotIn("storage_key", payload)
        self.assertNotIn("sha256", payload)

        list_response = await self.client.get(
            "/api/v1/audio-uploads",
            params=self._context_params(),
            headers=self.headers,
        )
        self.assertEqual(list_response.status_code, 200)
        history_item = list_response.json()["items"][0]
        self.assertEqual(history_item["id"], payload["id"])
        self.assertNotIn("transcript", history_item)
        self.assertTrue(history_item["transcript_available"])
        self.assertEqual(history_item["report_id"], payload["report_id"])
        self.assertEqual(history_item["severity"], "high")
        self.assertEqual(history_item["processing_stage"], "completed")

        async with self.session_factory() as session:
            activity = await session.get(
                DashboardActivity,
                uuid.UUID(payload["activity_id"]),
            )
            self.assertIsNotNone(activity)
            assert activity is not None
            self.assertEqual(activity.location_id, self.location.id)
            self.assertEqual(activity.audio_upload_id, uuid.UUID(payload["id"]))
            self.assertEqual(activity.actor, "AI Audio Monitor")
            dashboard_date = activity.service_date.isoformat()
            report = await session.get(
                AudioOperationsReport,
                uuid.UUID(payload["report_id"]),
            )
            self.assertIsNotNone(report)
            assert report is not None
            self.assertEqual(report.upload_id, uuid.UUID(payload["id"]))
            self.assertEqual(report.workspace_id, self.workspace.id)
            self.assertEqual(report.location_id, self.location.id)
            self.assertEqual(report.transcript, payload["transcript"])

        dashboard_response = await self.client.get(
            "/api/v1/dashboard",
            params={
                "workspace_id": str(self.workspace.id),
                "location_id": str(self.location.id),
                "service_date": dashboard_date,
                "activity_limit": 10,
            },
            headers=self.headers,
        )
        self.assertEqual(dashboard_response.status_code, 200)
        self.assertEqual(
            dashboard_response.json()["recent_activity"][0]["actor"],
            "AI Audio Monitor",
        )
        idempotent_retry = await self.client.post(
            f"/api/v1/audio-uploads/{payload['id']}/retry",
            params=self._context_params(),
            headers=self.headers,
        )
        self.assertEqual(idempotent_retry.status_code, 200)
        self.assertEqual(idempotent_retry.json()["report_id"], payload["report_id"])
        async with self.session_factory() as session:
            self.assertEqual(
                await session.scalar(select(func.count()).select_from(DashboardActivity)),
                1,
            )

        reports_response = await self.client.get(
            "/api/v1/reports",
            params={
                "workspace_id": str(self.workspace.id),
                "location_id": str(self.location.id),
                "start_date": dashboard_date,
                "end_date": dashboard_date,
            },
            headers=self.headers,
        )
        self.assertEqual(reports_response.status_code, 200)
        generated_report = reports_response.json()["audio_reports"][0]
        self.assertEqual(generated_report["id"], payload["report_id"])
        self.assertEqual(generated_report["source"], "AI Audio Monitor")
        self.assertEqual(generated_report["transcript"], payload["transcript"])

        other_tenant_reports = await self.client.get(
            "/api/v1/reports",
            params={
                "workspace_id": str(self.other_workspace.id),
                "location_id": str(self.other_location.id),
                "start_date": dashboard_date,
                "end_date": dashboard_date,
            },
            headers=self.other_headers,
        )
        self.assertEqual(other_tenant_reports.status_code, 200)
        self.assertEqual(other_tenant_reports.json()["audio_reports"], [])

        upload_id = payload["id"]
        download_response = await self.client.get(
            f"/api/v1/audio-uploads/{upload_id}/download",
            params=self._context_params(),
            headers=self.headers,
        )
        self.assertEqual(download_response.status_code, 200)
        self.assertEqual(download_response.content, b"ID3\x04\x00\x00restaurant audio")
        self.assertEqual(download_response.headers["content-type"], "audio/mpeg")
        stream_response = await self.client.get(
            f"/api/v1/audio-uploads/{upload_id}/audio",
            params=self._context_params(),
            headers=self.headers,
        )
        self.assertEqual(stream_response.status_code, 200)
        self.assertEqual(stream_response.content, download_response.content)
        self.assertTrue(
            stream_response.headers["content-disposition"].startswith("inline;")
        )

        delete_response = await self.client.delete(
            f"/api/v1/audio-uploads/{upload_id}",
            params=self._context_params(),
            headers=self.headers,
        )
        self.assertEqual(delete_response.status_code, 204)
        self.assertEqual(list(self.storage_root.rglob("*.mp3")), [])
        async with self.session_factory() as session:
            self.assertIsNone(
                await session.get(AudioOperationsReport, uuid.UUID(payload["report_id"]))
            )
            self.assertIsNone(
                await session.get(DashboardActivity, uuid.UUID(payload["activity_id"]))
            )

    async def test_location_access_is_checked_before_audio_is_stored(self) -> None:
        cross_workspace = await self._upload(location_id=self.other_location.id)
        missing = await self._upload(location_id=uuid.uuid4())

        self.assertEqual(cross_workspace.status_code, 403)
        self.assertEqual(missing.status_code, 404)
        self.assertEqual(list(self.storage_root.rglob("*.mp3")), [])
        history = await self.client.get(
            "/api/v1/audio-uploads",
            params=self._context_params(),
            headers=self.headers,
        )
        self.assertEqual(history.json(), {"items": []})

    async def test_provider_usage_costs_and_final_log_are_persisted_per_upload(self) -> None:
        app.dependency_overrides[get_audio_ai_pipeline] = lambda: AudioAIPipeline(
            sarvam=_MeteredTranscriber(),
            openai_service=_MeteredAnalyzer(),
            normalizer=_PassThroughNormalizer(),
        )

        with self.assertLogs(
            "backend.services.audio_ai_pipeline",
            level="INFO",
        ) as captured:
            response = await self._upload(content=b"ID3\x04\x00\x00metered-audio")

        self.assertEqual(response.status_code, 201, response.text)
        payload = response.json()
        self.assertEqual(payload["audio_duration_seconds"], 2.0)
        self.assertEqual(payload["sarvam_model"], "saaras:v3")
        self.assertEqual(payload["sarvam_estimated_cost_inr"], "0.01666667")
        self.assertEqual(payload["openai_model"], "gpt-4o-2024-11-20")
        self.assertEqual(payload["openai_input_tokens"], 150)
        self.assertEqual(payload["openai_cached_input_tokens"], 20)
        self.assertEqual(payload["openai_output_tokens"], 15)
        self.assertEqual(payload["openai_total_tokens"], 165)
        self.assertEqual(payload["openai_estimated_cost_usd"], "0.00050000")
        self.assertEqual(
            payload["total_estimated_cost"],
            {"INR": "0.01666667", "USD": "0.00050000"},
        )
        self.assertNotIn("sarvam_request_id", payload)
        self.assertNotIn("sarvam_job_id", payload)
        self.assertNotIn("openai_request_id", payload)
        self.assertNotIn("openai_request_ids", payload)

        history_response = await self.client.get(
            "/api/v1/audio-uploads",
            params=self._context_params(),
            headers=self.headers,
        )
        self.assertEqual(history_response.status_code, 200)
        history_item = history_response.json()["items"][0]
        for field in (
            "audio_duration_seconds",
            "sarvam_model",
            "sarvam_estimated_cost_inr",
            "openai_model",
            "openai_input_tokens",
            "openai_cached_input_tokens",
            "openai_output_tokens",
            "openai_total_tokens",
            "openai_estimated_cost_usd",
            "total_estimated_cost",
        ):
            self.assertEqual(history_item[field], payload[field])

        processed_date = payload["processed_at"][:10]
        reports_response = await self.client.get(
            "/api/v1/reports",
            params={
                **self._context_params(),
                "start_date": processed_date,
                "end_date": processed_date,
            },
            headers=self.headers,
        )
        self.assertEqual(reports_response.status_code, 200)
        report_item = reports_response.json()["audio_reports"][0]
        for field in (
            "audio_duration_seconds",
            "sarvam_model",
            "sarvam_estimated_cost_inr",
            "openai_model",
            "openai_input_tokens",
            "openai_cached_input_tokens",
            "openai_output_tokens",
            "openai_total_tokens",
            "openai_estimated_cost_usd",
            "total_estimated_cost",
        ):
            self.assertEqual(report_item[field], payload[field])

        async with self.session_factory() as session:
            upload = await session.get(AudioUpload, uuid.UUID(payload["id"]))
            self.assertIsNotNone(upload)
            assert upload is not None
            self.assertEqual(upload.audio_duration_seconds, 2.0)
            self.assertEqual(upload.sarvam_model, "saaras:v3")
            self.assertEqual(upload.sarvam_request_id, "sarvam-request-1")
            self.assertEqual(upload.sarvam_job_id, "sarvam-job-1")
            self.assertEqual(upload.provider_job_id, "sarvam-job-1")
            self.assertEqual(upload.sarvam_estimated_cost_inr, Decimal("0.01666667"))
            self.assertEqual(upload.openai_input_tokens, 150)
            self.assertEqual(upload.openai_cached_input_tokens, 20)
            self.assertEqual(upload.openai_output_tokens, 15)
            self.assertEqual(upload.openai_total_tokens, 165)
            self.assertEqual(upload.openai_model, "gpt-4o-2024-11-20")
            self.assertEqual(upload.openai_request_id, "openai-request-final")
            self.assertEqual(
                upload.openai_request_ids,
                ["openai-request-1", "openai-request-final"],
            )
            self.assertEqual(upload.openai_estimated_cost_usd, Decimal("0.00050000"))
            self.assertEqual(
                upload.total_estimated_cost,
                {"INR": "0.01666667", "USD": "0.00050000"},
            )

        message = "\n".join(captured.output)
        self.assertIn("audio_duration_seconds=2.0", message)
        self.assertIn("sarvam_estimated_cost_inr=0.01666667", message)
        self.assertIn("openai_input_tokens=150", message)
        self.assertIn("openai_output_tokens=15", message)
        self.assertIn("openai_estimated_cost_usd=0.00050000", message)
        self.assertIn("openai_model=gpt-4o-2024-11-20", message)

    async def test_other_owner_records_are_indistinguishable_from_missing(self) -> None:
        payload = (await self._upload()).json()
        upload_id = payload["id"]

        other_list = await self.client.get(
            "/api/v1/audio-uploads",
            params=self._context_params(other=True),
            headers=self.other_headers,
        )
        other_download = await self.client.get(
            f"/api/v1/audio-uploads/{upload_id}/download",
            params=self._context_params(other=True),
            headers=self.other_headers,
        )
        other_stream = await self.client.get(
            f"/api/v1/audio-uploads/{upload_id}/audio",
            params=self._context_params(other=True),
            headers=self.other_headers,
        )
        other_delete = await self.client.delete(
            f"/api/v1/audio-uploads/{upload_id}",
            params=self._context_params(other=True),
            headers=self.other_headers,
        )

        self.assertEqual(other_list.json(), {"items": []})
        self.assertEqual(other_download.status_code, 404)
        self.assertEqual(other_stream.status_code, 404)
        self.assertEqual(other_delete.status_code, 404)

    async def test_duplicate_prevention_is_scoped_to_owner(self) -> None:
        content = b"ID3\x04\x00\x00same audio"
        first = await self._upload(content=content)
        duplicate = await self._upload(filename="renamed.mp3", content=content)
        other_owner = await self._upload(content=content, headers=self.other_headers)

        self.assertEqual(first.status_code, 201)
        self.assertEqual(duplicate.status_code, 409)
        duplicate_detail = duplicate.json()["detail"]
        self.assertEqual(duplicate_detail["code"], "duplicate_completed")
        self.assertEqual(duplicate_detail["existing_upload_id"], first.json()["id"])
        self.assertEqual(duplicate_detail["existing_report_id"], first.json()["report_id"])
        self.assertEqual(other_owner.status_code, 201)

    async def test_rejects_invalid_form_and_audio_inputs(self) -> None:
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

        missing_location = await self._upload(include_location=False)
        invalid_language = await self._upload(language_code="not a code")
        self.assertEqual(missing_location.status_code, 422)
        self.assertEqual(invalid_language.status_code, 422)

    async def test_ai_failure_is_safe_retryable_and_does_not_create_activity(self) -> None:
        app.dependency_overrides[get_audio_ai_pipeline] = lambda: AudioAIPipeline(
            sarvam=_UnavailableTranscriber(),
            openai_service=_Analyzer(),
            normalizer=_PassThroughNormalizer(),
        )
        content = b"ID3\x04\x00\x00provider-failure"
        failed = await self._upload(content=content)

        self.assertEqual(failed.status_code, 503)
        self.assertEqual(
            failed.json()["detail"],
            {
                "code": "sarvam_unavailable",
                "message": "Speech translation is temporarily unavailable. Please try again.",
            },
        )
        self.assertNotIn("provider detail", failed.text)
        history = (
            await self.client.get(
                "/api/v1/audio-uploads",
                params=self._context_params(),
                headers=self.headers,
            )
        ).json()
        self.assertEqual(history["items"][0]["status"], "failed")
        self.assertEqual(history["items"][0]["failure_stage"], "transcribing")
        self.assertFalse(history["items"][0]["transcript_available"])
        async with self.session_factory() as session:
            activity_count = await session.scalar(
                select(func.count()).select_from(DashboardActivity)
            )
        self.assertEqual(activity_count, 0)

        app.dependency_overrides[get_audio_ai_pipeline] = lambda: AudioAIPipeline(
            sarvam=_Transcriber(),
            openai_service=_Analyzer(),
            normalizer=_PassThroughNormalizer(),
        )
        retried = await self._upload(content=content)
        self.assertEqual(retried.status_code, 201, retried.text)
        async with self.session_factory() as session:
            activity_count = await session.scalar(
                select(func.count()).select_from(DashboardActivity)
            )
        self.assertEqual(activity_count, 1)

    async def test_openai_failure_persists_transcript_and_retry_skips_sarvam(self) -> None:
        app.dependency_overrides[get_audio_ai_pipeline] = lambda: AudioAIPipeline(
            sarvam=_Transcriber(),
            openai_service=_UnavailableAnalyzer(),
            normalizer=_PassThroughNormalizer(),
        )
        failed = await self._upload(content=b"ID3\x04\x00\x00openai-failure")
        self.assertEqual(failed.status_code, 503)
        self.assertEqual(failed.json()["detail"]["code"], "openai_unavailable")

        history_response = await self.client.get(
            "/api/v1/audio-uploads",
            params=self._context_params(),
            headers=self.headers,
        )
        item = history_response.json()["items"][0]
        self.assertEqual(item["status"], "failed")
        self.assertTrue(item["transcript_available"])
        self.assertEqual(item["failure_stage"], "analyzing")

        app.dependency_overrides[get_audio_ai_pipeline] = lambda: AudioAIPipeline(
            sarvam=_MustNotTranscribe(),
            openai_service=_Analyzer(),
            normalizer=_PassThroughNormalizer(),
        )
        retried = await self.client.post(
            f"/api/v1/audio-uploads/{item['id']}/retry",
            params=self._context_params(),
            headers=self.headers,
        )
        self.assertEqual(retried.status_code, 200, retried.text)
        self.assertTrue(retried.json()["transcript"])
        async with self.session_factory() as session:
            self.assertEqual(
                await session.scalar(select(func.count()).select_from(DashboardActivity)),
                1,
            )
            self.assertEqual(
                await session.scalar(
                    select(func.count()).select_from(AudioOperationsReport)
                ),
                1,
            )

    async def test_unexpected_ai_failure_returns_a_generic_500(self) -> None:
        app.dependency_overrides[get_audio_ai_pipeline] = lambda: _UnexpectedPipeline()
        response = await self._upload(content=b"ID3\x04\x00\x00unexpected-failure")

        self.assertEqual(response.status_code, 500)
        self.assertEqual(
            response.json()["detail"],
            {
                "code": "processing_failed",
                "message": "The recording could not be processed.",
            },
        )
        self.assertNotIn("sensitive internal", response.text)

    async def test_infected_scan_quarantines_metadata_and_leaves_no_file(self) -> None:
        app.dependency_overrides[get_audio_scanner] = lambda: _VerdictScanner(
            ScanVerdict.INFECTED
        )
        response = await self._upload()

        self.assertEqual(response.status_code, 422)
        history = (
            await self.client.get(
                "/api/v1/audio-uploads",
                params=self._context_params(),
                headers=self.headers,
            )
        ).json()
        self.assertEqual(history["items"][0]["status"], "quarantined")
        self.assertEqual(history["items"][0]["scan_status"], "infected")
        self.assertEqual(list(self.storage_root.rglob("*.mp3")), [])

    async def test_scanner_and_storage_failures_are_retryable_and_clean_partials(self) -> None:
        app.dependency_overrides[get_audio_scanner] = lambda: _ErrorScanner()
        scan_content = b"ID3\x04\x00\x00scan-failure"
        scan_response = await self._upload(content=scan_content)
        self.assertEqual(scan_response.status_code, 503)
        self.assertEqual(list((self.storage_root / ".tmp").glob("*.part")), [])

        app.dependency_overrides[get_audio_scanner] = lambda: _VerdictScanner(
            ScanVerdict.CLEAN
        )
        retry_response = await self._upload(content=scan_content)
        self.assertEqual(retry_response.status_code, 201, retry_response.text)

        failing_root = Path(self.temp_directory.name) / "failing-objects"
        failing_storage = _FailingStorage(failing_root)
        app.dependency_overrides[get_audio_storage] = lambda: failing_storage
        storage_response = await self._upload(content=b"ID3\x04\x00\x00storage-failure")
        self.assertEqual(storage_response.status_code, 503)
        self.assertEqual(list((failing_root / ".tmp").glob("*.part")), [])
        self.assertEqual(list(failing_root.rglob("*.mp3")), [])

    async def test_history_limit_is_bounded(self) -> None:
        response = await self.client.get(
            "/api/v1/audio-uploads",
            params={**self._context_params(), "limit": 51},
            headers=self.headers,
        )
        self.assertEqual(response.status_code, 422)

    def _context_params(self, *, other: bool = False) -> dict[str, str]:
        workspace = self.other_workspace if other else self.workspace
        location = self.other_location if other else self.location
        return {
            "workspace_id": str(workspace.id),
            "location_id": str(location.id),
        }

    async def _upload(
        self,
        *,
        filename: str = "recording.mp3",
        content: bytes = b"ID3\x04\x00\x00audio data",
        media_type: str = "audio/mpeg",
        headers: dict[str, str] | None | object = _DEFAULT_HEADERS,
        location_id: uuid.UUID | None = None,
        language_code: str = "ne-IN",
        include_location: bool = True,
    ):
        request_headers = self.headers if headers is _DEFAULT_HEADERS else headers
        if location_id is None:
            location_id = (
                self.other_location.id
                if request_headers == self.other_headers
                else self.location.id
            )
        data = {"language_code": language_code}
        if include_location:
            data["location_id"] = str(location_id)
        return await self.client.post(
            "/api/v1/audio-uploads",
            headers=request_headers,
            files={"file": (filename, content, media_type)},
            data=data,
        )


if __name__ == "__main__":
    unittest.main()
