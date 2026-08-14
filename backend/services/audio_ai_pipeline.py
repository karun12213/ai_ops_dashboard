import logging
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.audio_upload import AudioAnalysisResponse
from backend.models.audio_upload import AudioUpload
from backend.models.dashboard import DashboardActivity
from backend.models.report import AudioOperationsReport, ReportLocation
from backend.services.audio_processing import (
    AudioNormalizationService,
    AudioProbe,
)
from backend.services.openai_service import (
    OpenAIAnalysisResult,
    OpenAIOperationsService,
    OpenAIResponseUsage,
    OpenAIUnavailableError,
)
from backend.services.sarvam_service import SarvamTranscript, SarvamTranscriptionService
from backend.utils.config import get_settings

AI_AUDIO_SOURCE = "AI Audio Monitor"
logger = logging.getLogger(__name__)
_COST_QUANTUM = Decimal("0.00000001")


class AudioAIPersistenceError(RuntimeError):
    pass


@dataclass(frozen=True)
class AudioAIResult:
    transcript: str
    analysis: AudioAnalysisResponse
    activity_id: uuid.UUID
    report_id: uuid.UUID
    processed_at: datetime
    source: str = AI_AUDIO_SOURCE


class AudioAIPipeline:
    def __init__(
        self,
        *,
        sarvam: SarvamTranscriptionService | None = None,
        openai_service: OpenAIOperationsService | None = None,
        normalizer: AudioNormalizationService | None = None,
    ) -> None:
        self.sarvam = sarvam
        self.openai = openai_service
        self.normalizer = normalizer

    async def process_audio(
        self,
        *,
        audio_path: Path,
        session: AsyncSession,
        upload: AudioUpload,
        location: ReportLocation,
        language_code: str = "unknown",
    ) -> AudioAIResult:
        if location.workspace_id is None:
            raise AudioAIPersistenceError("The selected location has no workspace")

        # A report row is the durable idempotency boundary. A successful retry
        # never invokes either provider or creates another Dashboard activity.
        existing_report = await session.scalar(
            select(AudioOperationsReport).where(
                AudioOperationsReport.upload_id == upload.id
            )
        )
        if existing_report is not None:
            existing_activity = await session.scalar(
                select(DashboardActivity).where(
                    DashboardActivity.audio_upload_id == upload.id
                )
            )
            if existing_activity is None:
                raise AudioAIPersistenceError(
                    "The completed audio report has no Dashboard activity"
                )
            return self._stored_result(existing_report, existing_activity)

        transcript = (upload.english_transcript or "").strip()
        if not transcript:
            normalizer = self.normalizer or AudioNormalizationService()
            sarvam = self.sarvam or SarvamTranscriptionService()
            await self._save_stage(session, upload, "validating")
            probe = await normalizer.probe(audio_path)
            short_limit_seconds = float(
                getattr(sarvam, "short_limit_seconds", 30.0)
            )
            await self._save_probe(session, upload, probe, short_limit_seconds)

            async def save_normalizing(stage: str) -> None:
                await self._save_stage(session, upload, stage)

            async def save_job_state(job_id: str, state: str) -> None:
                upload.provider_job_id = job_id
                upload.sarvam_job_id = job_id
                upload.provider_job_state = state
                await self._commit_upload(session, upload, "Sarvam job state")

            async with normalizer.prepare(
                audio_path,
                probe=probe,
                on_stage=save_normalizing,
            ) as prepared:
                upload.sarvam_model = self._optional_string(
                    getattr(sarvam, "model", None)
                )
                await self._save_stage(session, upload, "transcribing")
                if self.sarvam is not None:
                    # Test/local adapters written for the previous interface
                    # remain injectable; the production adapter always takes
                    # the full duration/job-state contract below.
                    try:
                        transcription = await sarvam.transcribe_to_english(
                            audio_path=prepared.path,
                            language_code=language_code,
                            duration_seconds=probe.duration_seconds,
                            existing_job_id=upload.provider_job_id,
                            existing_job_state=upload.provider_job_state,
                            on_job_state=save_job_state,
                        )
                    except TypeError:
                        transcription = await sarvam.transcribe_to_english(
                            audio_path=prepared.path,
                            language_code=language_code,
                        )
                else:
                    transcription = await sarvam.transcribe_to_english(
                        audio_path=prepared.path,
                        language_code=language_code,
                        duration_seconds=probe.duration_seconds,
                        existing_job_id=upload.provider_job_id,
                        existing_job_state=upload.provider_job_state,
                        on_job_state=save_job_state,
                    )

            if isinstance(transcription, SarvamTranscript):
                transcript = transcription.english_text.strip()
                upload.detected_language_code = transcription.detected_language_code
                upload.transcription_strategy = transcription.strategy
                upload.sarvam_model = (
                    self._optional_string(transcription.model)
                    or upload.sarvam_model
                )
                upload.sarvam_request_id = self._optional_string(
                    transcription.request_id
                )
                if transcription.provider_job_id:
                    upload.provider_job_id = transcription.provider_job_id
                    upload.sarvam_job_id = transcription.provider_job_id
                    upload.provider_job_state = "completed"
            else:
                transcript = str(transcription).strip()
            if transcript:
                rate = getattr(
                    sarvam,
                    "cost_per_audio_hour_inr",
                    get_settings().sarvam_cost_per_audio_hour_inr,
                )
                upload.sarvam_estimated_cost_inr = (
                    self._decimal(upload.sarvam_estimated_cost_inr)
                    + self._sarvam_cost(probe.duration_seconds, rate)
                ).quantize(_COST_QUANTUM)
                self._update_total_estimated_cost(upload)
                upload.english_transcript = transcript
                await self._save_stage(session, upload, "analyzing")
        else:
            # A previous Sarvam success is durable. OpenAI-only retry resumes
            # here without retranscribing or re-normalizing the original audio.
            await self._save_stage(session, upload, "analyzing")
        if not transcript:
            raise OpenAIUnavailableError("Transcription returned no text")

        openai_service = self.openai or OpenAIOperationsService()

        async def save_openai_usage(usage: OpenAIResponseUsage) -> None:
            self._add_openai_usage(upload, usage)
            await self._commit_upload(session, upload, "OpenAI usage")

        metered_analyze = getattr(
            openai_service,
            "analyze_transcript_with_usage",
            None,
        )
        if callable(metered_analyze):
            metered_result = await metered_analyze(
                transcript,
                on_usage=save_openai_usage,
            )
            raw_analysis = (
                metered_result.analysis
                if isinstance(metered_result, OpenAIAnalysisResult)
                else metered_result
            )
        else:
            raw_analysis = await openai_service.analyze_transcript(transcript)
        try:
            analysis = AudioAnalysisResponse.model_validate(raw_analysis)
        except ValidationError as exc:
            raise OpenAIUnavailableError("OpenAI returned an invalid analysis") from exc

        await self._save_stage(session, upload, "saving_report")
        now = datetime.now(timezone.utc)
        activity = DashboardActivity(
            audio_upload_id=upload.id,
            location_id=location.id,
            service_date=now.date(),
            occurred_at=now,
            title=analysis.summary[:160],
            actor=AI_AUDIO_SOURCE,
            category=analysis.category,
            severity=analysis.severity,
        )
        report = AudioOperationsReport(
            upload_id=upload.id,
            owner_id=upload.owner_id,
            workspace_id=location.workspace_id,
            location_id=location.id,
            transcript=transcript,
            summary=analysis.summary,
            category=analysis.category,
            severity=analysis.severity,
            requires_attention=analysis.requires_attention,
            recommended_action=analysis.recommended_action,
            source=AI_AUDIO_SOURCE,
            processed_at=now,
        )
        upload.workspace_id = location.workspace_id
        upload.location_id = location.id
        upload.status = "ready"
        upload.processing_stage = "completed"
        upload.failure_stage = None
        upload.failure_code = None
        upload.failure_message = None
        upload.retryable = False
        upload.processed_at = now
        upload.english_transcript = transcript
        session.add_all([activity, report])
        try:
            await session.commit()
            await session.refresh(upload)
            await session.refresh(activity)
            await session.refresh(report)
        except Exception as exc:
            await session.rollback()
            raise AudioAIPersistenceError(
                "Audio report and Dashboard activity could not be saved"
            ) from exc

        logger.info(
            "Audio processing usage upload_id=%s audio_duration_seconds=%s "
            "sarvam_estimated_cost_inr=%s openai_input_tokens=%s "
            "openai_output_tokens=%s openai_estimated_cost_usd=%s openai_model=%s",
            upload.id,
            upload.audio_duration_seconds,
            upload.sarvam_estimated_cost_inr,
            upload.openai_input_tokens,
            upload.openai_output_tokens,
            upload.openai_estimated_cost_usd,
            upload.openai_model,
        )

        return AudioAIResult(
            transcript=transcript,
            analysis=analysis,
            activity_id=activity.id,
            report_id=report.id,
            processed_at=report.processed_at,
        )

    @staticmethod
    async def _save_probe(
        session: AsyncSession,
        upload: AudioUpload,
        probe: AudioProbe,
        short_limit_seconds: float,
    ) -> None:
        upload.audio_container = probe.container
        upload.audio_codec = probe.codec
        upload.audio_duration_seconds = probe.duration_seconds
        upload.audio_sample_rate = probe.sample_rate
        upload.audio_channels = probe.channels
        upload.transcription_strategy = (
            "short_rest"
            if probe.duration_seconds <= short_limit_seconds
            else "long_batch"
        )
        await AudioAIPipeline._commit_upload(session, upload, "audio probe")

    @staticmethod
    async def _save_stage(
        session: AsyncSession,
        upload: AudioUpload,
        stage: str,
    ) -> None:
        upload.status = "processing"
        upload.processing_stage = stage
        upload.failure_stage = None
        upload.failure_code = None
        upload.failure_message = None
        upload.retryable = True
        await AudioAIPipeline._commit_upload(session, upload, f"stage {stage}")

    @staticmethod
    async def _commit_upload(
        session: AsyncSession,
        upload: AudioUpload,
        description: str,
    ) -> None:
        try:
            await session.commit()
            await session.refresh(upload)
        except Exception as exc:
            await session.rollback()
            raise AudioAIPersistenceError(
                f"Audio {description} could not be saved"
            ) from exc

    @staticmethod
    def _add_openai_usage(
        upload: AudioUpload,
        usage: OpenAIResponseUsage,
    ) -> None:
        upload.openai_input_tokens = (upload.openai_input_tokens or 0) + usage.input_tokens
        upload.openai_cached_input_tokens = (
            upload.openai_cached_input_tokens or 0
        ) + usage.cached_input_tokens
        upload.openai_output_tokens = (
            upload.openai_output_tokens or 0
        ) + usage.output_tokens
        upload.openai_total_tokens = (upload.openai_total_tokens or 0) + usage.total_tokens
        if usage.model:
            upload.openai_model = usage.model
        if usage.request_id:
            upload.openai_request_id = usage.request_id
        request_ids = list(upload.openai_request_ids or [])
        request_ids.extend(usage.request_ids)
        upload.openai_request_ids = request_ids
        upload.openai_estimated_cost_usd = (
            AudioAIPipeline._decimal(upload.openai_estimated_cost_usd)
            + usage.estimated_cost_usd
        ).quantize(_COST_QUANTUM)
        AudioAIPipeline._update_total_estimated_cost(upload)

    @staticmethod
    def _update_total_estimated_cost(upload: AudioUpload) -> None:
        upload.total_estimated_cost = {
            "INR": str(
                AudioAIPipeline._decimal(upload.sarvam_estimated_cost_inr).quantize(
                    _COST_QUANTUM
                )
            ),
            "USD": str(
                AudioAIPipeline._decimal(upload.openai_estimated_cost_usd).quantize(
                    _COST_QUANTUM
                )
            ),
        }

    @staticmethod
    def _sarvam_cost(duration_seconds: float, rate_per_hour: Decimal) -> Decimal:
        return (
            Decimal(str(max(duration_seconds, 0)))
            * AudioAIPipeline._decimal(rate_per_hour)
            / Decimal(3600)
        ).quantize(_COST_QUANTUM)

    @staticmethod
    def _decimal(value) -> Decimal:
        return value if isinstance(value, Decimal) else Decimal(str(value or 0))

    @staticmethod
    def _optional_string(value) -> str | None:
        return value.strip()[:128] if isinstance(value, str) and value.strip() else None

    @staticmethod
    def _stored_result(
        report: AudioOperationsReport,
        activity: DashboardActivity,
    ) -> AudioAIResult:
        return AudioAIResult(
            transcript=report.transcript,
            analysis=AudioAnalysisResponse(
                summary=report.summary,
                category=report.category,
                severity=report.severity,
                requires_attention=report.requires_attention,
                recommended_action=report.recommended_action,
            ),
            activity_id=activity.id,
            report_id=report.id,
            processed_at=report.processed_at,
            source=report.source,
        )
