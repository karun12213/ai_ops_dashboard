import asyncio
import json
import logging
import shutil
import subprocess
import tempfile
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import AsyncIterator, Awaitable, Callable

from backend.utils.config import get_settings

logger = logging.getLogger(__name__)


class AudioProcessingError(RuntimeError):
    code = "audio_processing_failed"
    retryable = False


class AudioToolUnavailableError(AudioProcessingError):
    code = "ffmpeg_unavailable"
    retryable = True


class InvalidAudioContentError(AudioProcessingError):
    code = "invalid_audio_content"


class AudioDurationLimitError(AudioProcessingError):
    code = "audio_too_long"


class AudioNormalizationError(AudioProcessingError):
    code = "audio_normalization_failed"


@dataclass(frozen=True)
class AudioProbe:
    container: str
    codec: str
    duration_seconds: float
    sample_rate: int | None
    channels: int | None
    size_bytes: int


@dataclass(frozen=True)
class PreparedAudio:
    path: Path
    probe: AudioProbe
    media_type: str = "audio/wav"
    codec: str = "pcm_s16le"
    sample_rate: int = 16000
    channels: int = 1


StageCallback = Callable[[str], Awaitable[None]]


class AudioNormalizationService:
    """Probe real media and create a provider-safe 16 kHz mono PCM WAV."""

    def __init__(
        self,
        *,
        ffmpeg_binary: str | None = None,
        ffprobe_binary: str | None = None,
        max_duration_seconds: float | None = None,
    ) -> None:
        settings = get_settings()
        self.ffmpeg_binary = self._resolve_binary(
            ffmpeg_binary or settings.ffmpeg_binary,
            "ffmpeg",
        )
        self.ffprobe_binary = self._resolve_binary(
            ffprobe_binary or settings.ffprobe_binary,
            "ffprobe",
        )
        self.max_duration_seconds = (
            max_duration_seconds
            if max_duration_seconds is not None
            else settings.audio_max_duration_seconds
        )

    @staticmethod
    def _resolve_binary(configured: str | None, default_name: str) -> str | None:
        candidate = configured.strip() if configured else default_name
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
        explicit = Path(candidate)
        if explicit.is_file():
            return str(explicit.resolve())
        return None

    @property
    def is_available(self) -> bool:
        return self.ffmpeg_binary is not None and self.ffprobe_binary is not None

    def require_available(self) -> None:
        missing = []
        if self.ffmpeg_binary is None:
            missing.append("ffmpeg")
        if self.ffprobe_binary is None:
            missing.append("ffprobe")
        if missing:
            raise AudioToolUnavailableError(
                f"Required audio tool is unavailable: {', '.join(missing)}"
            )

    async def probe(self, audio_path: Path) -> AudioProbe:
        self.require_available()
        return await asyncio.to_thread(self._probe_sync, audio_path)

    def _probe_sync(self, audio_path: Path) -> AudioProbe:
        assert self.ffprobe_binary is not None
        command = [
            self.ffprobe_binary,
            "-v",
            "error",
            "-show_entries",
            "format=format_name,duration,size:stream=codec_type,codec_name,sample_rate,channels",
            "-of",
            "json",
            str(audio_path),
        ]
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
                shell=False,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise AudioToolUnavailableError("Audio inspection could not start") from exc
        if result.returncode != 0:
            raise InvalidAudioContentError("FFprobe could not read the audio")
        try:
            payload = json.loads(result.stdout)
            audio_stream = next(
                stream
                for stream in payload.get("streams", [])
                if stream.get("codec_type") == "audio"
            )
            format_data = payload["format"]
            duration = float(format_data["duration"])
            size_bytes = int(format_data.get("size") or audio_path.stat().st_size)
        except (KeyError, StopIteration, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise InvalidAudioContentError("No readable audio stream was found") from exc
        if duration <= 0:
            raise InvalidAudioContentError("The audio duration is invalid")
        if duration > self.max_duration_seconds:
            raise AudioDurationLimitError(
                "The recording exceeds the supported two-hour duration limit"
            )
        sample_rate = audio_stream.get("sample_rate")
        channels = audio_stream.get("channels")
        return AudioProbe(
            container=str(format_data.get("format_name") or "unknown")[:64],
            codec=str(audio_stream.get("codec_name") or "unknown")[:64],
            duration_seconds=duration,
            sample_rate=int(sample_rate) if sample_rate else None,
            channels=int(channels) if channels else None,
            size_bytes=size_bytes,
        )

    @asynccontextmanager
    async def prepare(
        self,
        audio_path: Path,
        *,
        probe: AudioProbe | None = None,
        on_stage: StageCallback | None = None,
    ) -> AsyncIterator[PreparedAudio]:
        probe = probe or await self.probe(audio_path)
        if on_stage is not None:
            await on_stage("normalizing")
        temporary = tempfile.TemporaryDirectory(prefix="restaurant-ops-audio-")
        output_path = Path(temporary.name) / "provider-audio.wav"
        try:
            await asyncio.to_thread(self._normalize_sync, audio_path, output_path)
            yield PreparedAudio(path=output_path, probe=probe)
        finally:
            temporary.cleanup()

    def _normalize_sync(self, audio_path: Path, output_path: Path) -> None:
        self.require_available()
        assert self.ffmpeg_binary is not None
        command = [
            self.ffmpeg_binary,
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(audio_path),
            "-map",
            "0:a:0",
            "-vn",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(output_path),
        ]
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
                shell=False,
                timeout=max(60, int(self.max_duration_seconds * 2)),
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise AudioNormalizationError("Audio normalization did not complete") from exc
        if result.returncode != 0 or not output_path.is_file() or output_path.stat().st_size == 0:
            logger.warning(
                "Audio normalization failed return_code=%s",
                result.returncode,
            )
            raise AudioNormalizationError("Audio normalization failed")
