import asyncio
import json
import logging
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Awaitable, Callable, TypeVar

import httpx
from sarvamai import SarvamAI

from backend.utils.config import get_settings

logger = logging.getLogger(__name__)
T = TypeVar("T")


class SarvamError(RuntimeError):
    code = "sarvam_unavailable"
    retryable = True

    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        request_id: str | None = None,
        provider_code: str | None = None,
        provider_message: str | None = None,
        strategy: str | None = None,
        job_id: str | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.request_id = request_id
        self.provider_code = provider_code
        self.provider_message = provider_message
        self.strategy = strategy
        self.job_id = job_id


class SarvamUnavailableError(SarvamError):
    pass


class SarvamRateLimitError(SarvamUnavailableError):
    code = "ai_busy"


class SarvamTimeoutError(SarvamUnavailableError):
    code = "sarvam_timeout"


class SarvamInvalidRequestError(SarvamError):
    code = "sarvam_invalid_audio"
    retryable = False


class SarvamAuthenticationError(SarvamError):
    code = "sarvam_authentication"
    # Do not retry within the same request, but allow an operator to correct
    # environment configuration and resume the durable upload later.
    retryable = True


@dataclass(frozen=True)
class SarvamTranscript:
    english_text: str
    detected_language_code: str | None
    request_id: str | None = None
    strategy: str = "short_rest"
    provider_job_id: str | None = None
    model: str | None = None


@dataclass(frozen=True)
class _ProviderDiagnostic:
    status_code: int | None
    request_id: str | None
    code: str | None
    message: str | None


SUPPORTED_SARVAM_LANGUAGE_CODES = frozenset(
    {
        "unknown",
        "hi-IN",
        "bn-IN",
        "kn-IN",
        "ml-IN",
        "mr-IN",
        "od-IN",
        "pa-IN",
        "ta-IN",
        "te-IN",
        "en-IN",
        "gu-IN",
        "as-IN",
        "ur-IN",
        "ne-IN",
        "kok-IN",
        "ks-IN",
        "sd-IN",
        "sa-IN",
        "sat-IN",
        "mni-IN",
        "brx-IN",
        "mai-IN",
        "doi-IN",
    }
)

JobStateCallback = Callable[[str, str], Awaitable[None]]


class SarvamTranscriptionService:
    def __init__(self, *, client: SarvamAI | None = None) -> None:
        settings = get_settings()
        api_key = settings.sarvam_api_key
        if client is None and (
            api_key is None or not api_key.get_secret_value().strip()
        ):
            raise SarvamAuthenticationError("SARVAM_API_KEY is not configured")
        self.client = client or SarvamAI(
            api_subscription_key=api_key.get_secret_value(),
            timeout=settings.sarvam_timeout_seconds,
        )
        self.model = settings.sarvam_model
        self.mode = settings.sarvam_mode
        self.short_limit_seconds = settings.sarvam_short_audio_max_seconds
        self.max_retries = settings.sarvam_max_retries
        self.backoff_seconds = settings.sarvam_retry_backoff_seconds
        self.batch_timeout_seconds = settings.sarvam_batch_timeout_seconds
        self.batch_poll_seconds = settings.sarvam_batch_poll_seconds
        self.cost_per_audio_hour_inr = settings.sarvam_cost_per_audio_hour_inr

    async def transcribe_to_english(
        self,
        *,
        audio_path: Path,
        language_code: str = "unknown",
        duration_seconds: float | None = None,
        existing_job_id: str | None = None,
        existing_job_state: str | None = None,
        on_job_state: JobStateCallback | None = None,
    ) -> SarvamTranscript:
        if language_code not in SUPPORTED_SARVAM_LANGUAGE_CODES:
            raise ValueError("Unsupported Sarvam language code")
        if self.model != "saaras:v3" or self.mode != "translate":
            raise SarvamInvalidRequestError(
                "Sarvam must use saaras:v3 with translate mode for English output"
            )
        if duration_seconds is None or duration_seconds <= self.short_limit_seconds:
            return await self._transcribe_short(audio_path, language_code)
        return await self._transcribe_batch(
            audio_path,
            language_code,
            existing_job_id=existing_job_id,
            existing_job_state=existing_job_state,
            on_job_state=on_job_state,
        )

    async def _transcribe_short(
        self,
        audio_path: Path,
        language_code: str,
    ) -> SarvamTranscript:
        def operation():
            with audio_path.open("rb") as audio_file:
                return self.client.speech_to_text.transcribe(
                    file=audio_file,
                    model=self.model,
                    language_code=language_code,
                    mode=self.mode,
                )

        response = await self._call_with_retry(
            operation,
            operation="short_transcription",
            strategy="short_rest",
        )
        transcript = getattr(response, "transcript", None)
        if not isinstance(transcript, str) or not transcript.strip():
            raise SarvamUnavailableError(
                "Sarvam returned an empty transcript",
                strategy="short_rest",
            )
        return SarvamTranscript(
            english_text=transcript.strip(),
            detected_language_code=self._optional_string(
                getattr(response, "language_code", None)
            ),
            request_id=self._optional_string(getattr(response, "request_id", None)),
            strategy="short_rest",
            model=self.model,
        )

    async def _transcribe_batch(
        self,
        audio_path: Path,
        language_code: str,
        *,
        existing_job_id: str | None,
        existing_job_state: str | None,
        on_job_state: JobStateCallback | None,
    ) -> SarvamTranscript:
        strategy = "long_batch"
        job = None
        job_state = (existing_job_state or "").lower()
        if existing_job_id:
            job = await self._call_with_retry(
                lambda: self.client.speech_to_text_job.get_job(existing_job_id),
                operation="batch_get_job",
                strategy=strategy,
                job_id=existing_job_id,
            )
        else:
            job = await self._call_with_retry(
                lambda: self.client.speech_to_text_job.create_job(
                    model=self.model,
                    mode=self.mode,
                    language_code=language_code,
                    with_diarization=False,
                    with_timestamps=True,
                ),
                operation="batch_create",
                strategy=strategy,
            )
            existing_job_id = job.job_id
            job_state = "created"
            await self._notify_job_state(on_job_state, job.job_id, job_state)

        if job_state in {"", "created", "initialized"}:
            await self._call_with_retry(
                lambda: job.upload_files(
                    file_paths=[str(audio_path)],
                    timeout=max(60.0, self.batch_timeout_seconds / 2),
                ),
                operation="batch_upload",
                strategy=strategy,
                job_id=job.job_id,
            )
            job_state = "uploaded"
            await self._notify_job_state(on_job_state, job.job_id, job_state)

        if job_state in {"uploaded"}:
            await self._call_with_retry(
                job.start,
                operation="batch_start",
                strategy=strategy,
                job_id=job.job_id,
            )
            job_state = "started"
            await self._notify_job_state(on_job_state, job.job_id, job_state)

        final_status = await self._poll_batch(job, on_job_state)
        if str(final_status.job_state).lower() != "completed":
            failed = await self._call_with_retry(
                job.get_file_results,
                operation="batch_file_results",
                strategy=strategy,
                job_id=job.job_id,
            )
            message = self._first_batch_error(failed) or "Sarvam batch job failed"
            raise SarvamInvalidRequestError(
                "Sarvam could not process the long recording",
                provider_message=message,
                strategy=strategy,
                job_id=job.job_id,
            )

        with tempfile.TemporaryDirectory(prefix="restaurant-ops-sarvam-") as directory:
            await self._call_with_retry(
                lambda: job.download_outputs(directory),
                operation="batch_download",
                strategy=strategy,
                job_id=job.job_id,
            )
            output_files = list(Path(directory).glob("*.json"))
            if len(output_files) != 1:
                raise SarvamUnavailableError(
                    "Sarvam batch output was missing",
                    strategy=strategy,
                    job_id=job.job_id,
                )
            try:
                payload = json.loads(output_files[0].read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError) as exc:
                raise SarvamUnavailableError(
                    "Sarvam batch output was invalid",
                    strategy=strategy,
                    job_id=job.job_id,
                ) from exc

        transcript = payload.get("transcript")
        if not isinstance(transcript, str) or not transcript.strip():
            raise SarvamUnavailableError(
                "Sarvam returned an empty batch transcript",
                strategy=strategy,
                job_id=job.job_id,
            )
        return SarvamTranscript(
            english_text=transcript.strip(),
            detected_language_code=self._optional_string(
                payload.get("language_code")
            ),
            request_id=self._optional_string(payload.get("request_id")),
            strategy=strategy,
            provider_job_id=job.job_id,
            model=self.model,
        )

    async def _poll_batch(self, job, callback: JobStateCallback | None):
        started = time.monotonic()
        previous_state = None
        while True:
            status = await self._call_with_retry(
                job.get_status,
                operation="batch_status",
                strategy="long_batch",
                job_id=job.job_id,
            )
            state = str(status.job_state).lower()
            if state != previous_state:
                await self._notify_job_state(callback, job.job_id, state)
                previous_state = state
            if state in {"completed", "failed"}:
                return status
            if time.monotonic() - started >= self.batch_timeout_seconds:
                raise SarvamTimeoutError(
                    "Sarvam batch processing timed out",
                    strategy="long_batch",
                    job_id=job.job_id,
                )
            await asyncio.sleep(self.batch_poll_seconds)

    async def _call_with_retry(
        self,
        func: Callable[[], T],
        *,
        operation: str,
        strategy: str,
        job_id: str | None = None,
    ) -> T:
        last_error: BaseException | None = None
        for attempt in range(self.max_retries + 1):
            try:
                return await asyncio.to_thread(func)
            except Exception as exc:
                last_error = exc
                diagnostic = self._provider_diagnostic(exc)
                transient = self._is_transient(exc, diagnostic.status_code)
                logger.warning(
                    "Sarvam operation failed operation=%s strategy=%s attempt=%s "
                    "status=%s request_id=%s provider_code=%s retryable=%s job_id=%s "
                    "provider_message=%s",
                    operation,
                    strategy,
                    attempt + 1,
                    diagnostic.status_code,
                    diagnostic.request_id,
                    diagnostic.code,
                    transient,
                    job_id,
                    diagnostic.message,
                )
                if transient and attempt < self.max_retries:
                    await asyncio.sleep(self.backoff_seconds * (2**attempt))
                    continue
                raise self._mapped_error(
                    exc,
                    diagnostic,
                    strategy=strategy,
                    job_id=job_id,
                ) from exc
        raise SarvamUnavailableError("Sarvam operation failed") from last_error

    @staticmethod
    async def _notify_job_state(
        callback: JobStateCallback | None,
        job_id: str,
        state: str,
    ) -> None:
        if callback is not None:
            await callback(job_id, state[:32])

    @staticmethod
    def _provider_diagnostic(exc: BaseException) -> _ProviderDiagnostic:
        status_code = getattr(exc, "status_code", None)
        headers = getattr(exc, "headers", None) or {}
        body = getattr(exc, "body", None)
        error = body.get("error") if isinstance(body, dict) else None
        if not isinstance(error, dict) and isinstance(body, dict):
            error = body
        request_id = None
        code = None
        message = None
        if isinstance(error, dict):
            request_id = SarvamTranscriptionService._optional_string(
                error.get("request_id")
            )
            code = SarvamTranscriptionService._optional_string(error.get("code"))
            message = SarvamTranscriptionService._optional_string(
                error.get("message") or error.get("detail")
            )
        if request_id is None and isinstance(headers, dict):
            request_id = SarvamTranscriptionService._optional_string(
                headers.get("x-request-id") or headers.get("request-id")
            )
        return _ProviderDiagnostic(
            status_code=status_code if isinstance(status_code, int) else None,
            request_id=request_id,
            code=code,
            message=message,
        )

    @staticmethod
    def _is_transient(exc: BaseException, status_code: int | None) -> bool:
        if status_code == 429 or (status_code is not None and status_code >= 500):
            return True
        return isinstance(
            exc,
            (
                TimeoutError,
                httpx.TimeoutException,
                httpx.NetworkError,
                ConnectionError,
            ),
        )

    @staticmethod
    def _mapped_error(
        exc: BaseException,
        diagnostic: _ProviderDiagnostic,
        *,
        strategy: str,
        job_id: str | None,
    ) -> SarvamError:
        fields = {
            "status_code": diagnostic.status_code,
            "request_id": diagnostic.request_id,
            "provider_code": diagnostic.code,
            "provider_message": diagnostic.message,
            "strategy": strategy,
            "job_id": job_id,
        }
        if diagnostic.status_code == 429:
            return SarvamRateLimitError("Sarvam is temporarily busy", **fields)
        if diagnostic.status_code in {401, 403}:
            return SarvamAuthenticationError("Sarvam authentication failed", **fields)
        if diagnostic.status_code is not None and 400 <= diagnostic.status_code < 500:
            return SarvamInvalidRequestError("Sarvam rejected the audio request", **fields)
        if isinstance(exc, (TimeoutError, httpx.TimeoutException)):
            return SarvamTimeoutError("Sarvam request timed out", **fields)
        return SarvamUnavailableError("Sarvam transcription failed", **fields)

    @staticmethod
    def _first_batch_error(results: Any) -> str | None:
        if not isinstance(results, dict):
            return None
        failed = results.get("failed")
        if not isinstance(failed, list) or not failed:
            return None
        first = failed[0]
        if not isinstance(first, dict):
            return None
        return SarvamTranscriptionService._optional_string(
            first.get("error_message")
        )

    @staticmethod
    def _optional_string(value: Any) -> str | None:
        return value.strip()[:500] if isinstance(value, str) and value.strip() else None
