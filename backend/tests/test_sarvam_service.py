import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from backend.services.sarvam_service import (
    SarvamInvalidRequestError,
    SarvamRateLimitError,
    SarvamTranscriptionService,
)


class _SpeechToText:
    def __init__(self, response=None, errors=None) -> None:
        self.response = response or SimpleNamespace(
            transcript="English short transcript",
            language_code="hi-IN",
            request_id="short-request-id",
        )
        self.errors = list(errors or [])
        self.calls: list[dict] = []

    def transcribe(self, **kwargs):
        self.calls.append(kwargs)
        if self.errors:
            raise self.errors.pop(0)
        return self.response


class _BatchJob:
    def __init__(self, *, job_id="batch-job-1", transcript="English batch transcript") -> None:
        self.job_id = job_id
        self.transcript = transcript
        self.upload_calls = 0
        self.start_calls = 0
        self.status_calls = 0

    def upload_files(self, **kwargs):
        self.upload_calls += 1
        self.upload_kwargs = kwargs

    def start(self):
        self.start_calls += 1

    def get_status(self):
        self.status_calls += 1
        return SimpleNamespace(job_state="Completed")

    def download_outputs(self, directory):
        Path(directory, "provider-audio.json").write_text(
            json.dumps(
                {
                    "transcript": self.transcript,
                    "language_code": "ne-IN",
                    "request_id": "batch-request-id",
                }
            ),
            encoding="utf-8",
        )

    def get_file_results(self):
        return {"failed": []}


class _SpeechToTextJobs:
    def __init__(self, job: _BatchJob) -> None:
        self.job = job
        self.create_calls: list[dict] = []
        self.get_calls: list[str] = []

    def create_job(self, **kwargs):
        self.create_calls.append(kwargs)
        return self.job

    def get_job(self, job_id):
        self.get_calls.append(job_id)
        return self.job


class _Client:
    def __init__(self, *, speech=None, job=None) -> None:
        self.speech_to_text = speech or _SpeechToText()
        self.job = job or _BatchJob()
        self.speech_to_text_job = _SpeechToTextJobs(self.job)


class _ProviderError(Exception):
    def __init__(self, status_code: int) -> None:
        super().__init__("provider failure")
        self.status_code = status_code
        self.headers = {"x-request-id": "safe-provider-request"}
        self.body = {
            "error": {
                "code": "provider_code",
                "message": "safe provider message",
            }
        }


class SarvamTranscriptionServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.audio = Path(self.directory.name) / "provider-audio.wav"
        self.audio.write_bytes(b"RIFF-valid-test-placeholder")

    async def asyncTearDown(self) -> None:
        self.directory.cleanup()

    async def test_short_audio_uses_translate_mode_and_auto_language(self) -> None:
        client = _Client()
        service = SarvamTranscriptionService(client=client)
        result = await service.transcribe_to_english(
            audio_path=self.audio,
            language_code="unknown",
            duration_seconds=29.9,
        )

        self.assertEqual(result.english_text, "English short transcript")
        self.assertEqual(result.detected_language_code, "hi-IN")
        self.assertEqual(result.strategy, "short_rest")
        self.assertEqual(result.request_id, "short-request-id")
        self.assertEqual(result.model, "saaras:v3")
        call = client.speech_to_text.calls[0]
        self.assertEqual(call["model"], "saaras:v3")
        self.assertEqual(call["mode"], "translate")
        self.assertEqual(call["language_code"], "unknown")

    async def test_long_audio_creates_polls_and_downloads_a_batch_job(self) -> None:
        client = _Client()
        service = SarvamTranscriptionService(client=client)
        service.batch_poll_seconds = 0
        states: list[tuple[str, str]] = []

        async def on_state(job_id: str, state: str) -> None:
            states.append((job_id, state))

        result = await service.transcribe_to_english(
            audio_path=self.audio,
            language_code="ne-IN",
            duration_seconds=30.1,
            on_job_state=on_state,
        )

        self.assertEqual(result.english_text, "English batch transcript")
        self.assertEqual(result.detected_language_code, "ne-IN")
        self.assertEqual(result.strategy, "long_batch")
        self.assertEqual(result.provider_job_id, "batch-job-1")
        self.assertEqual(result.request_id, "batch-request-id")
        self.assertEqual(result.model, "saaras:v3")
        self.assertEqual(client.job.upload_calls, 1)
        self.assertEqual(client.job.start_calls, 1)
        self.assertEqual(
            [state for _, state in states],
            ["created", "uploaded", "started", "completed"],
        )
        create = client.speech_to_text_job.create_calls[0]
        self.assertEqual(create["mode"], "translate")
        self.assertEqual(create["language_code"], "ne-IN")

    async def test_restart_resume_polls_existing_started_job_without_reupload(self) -> None:
        client = _Client()
        service = SarvamTranscriptionService(client=client)
        service.batch_poll_seconds = 0
        result = await service.transcribe_to_english(
            audio_path=self.audio,
            duration_seconds=45,
            existing_job_id="batch-job-1",
            existing_job_state="started",
        )

        self.assertEqual(result.strategy, "long_batch")
        self.assertEqual(client.speech_to_text_job.get_calls, ["batch-job-1"])
        self.assertEqual(client.job.upload_calls, 0)
        self.assertEqual(client.job.start_calls, 0)

    async def test_transient_429_retries_once_then_succeeds(self) -> None:
        speech = _SpeechToText(errors=[_ProviderError(429)])
        service = SarvamTranscriptionService(client=_Client(speech=speech))
        service.max_retries = 1
        service.backoff_seconds = 0
        result = await service.transcribe_to_english(
            audio_path=self.audio,
            duration_seconds=2,
        )
        self.assertEqual(result.english_text, "English short transcript")
        self.assertEqual(len(speech.calls), 2)

    async def test_persistent_429_and_bad_request_are_mapped_safely(self) -> None:
        rate_speech = _SpeechToText(errors=[_ProviderError(429), _ProviderError(429)])
        rate_service = SarvamTranscriptionService(client=_Client(speech=rate_speech))
        rate_service.max_retries = 1
        rate_service.backoff_seconds = 0
        with self.assertRaises(SarvamRateLimitError) as rate_context:
            await rate_service.transcribe_to_english(
                audio_path=self.audio,
                duration_seconds=2,
            )
        self.assertEqual(rate_context.exception.request_id, "safe-provider-request")

        bad_service = SarvamTranscriptionService(
            client=_Client(speech=_SpeechToText(errors=[_ProviderError(400)]))
        )
        with self.assertRaises(SarvamInvalidRequestError) as bad_context:
            await bad_service.transcribe_to_english(
                audio_path=self.audio,
                duration_seconds=2,
            )
        self.assertFalse(bad_context.exception.retryable)
        self.assertEqual(bad_context.exception.status_code, 400)
        self.assertEqual(bad_context.exception.provider_code, "provider_code")


if __name__ == "__main__":
    unittest.main()
