import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from backend.services.audio_processing import (
    AudioDurationLimitError,
    AudioNormalizationService,
    AudioToolUnavailableError,
    InvalidAudioContentError,
)


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg is required")
class AudioNormalizationIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.service = AudioNormalizationService(max_duration_seconds=120)

    async def asyncTearDown(self) -> None:
        self.directory.cleanup()

    async def test_claimed_formats_are_probed_and_normalized_to_pcm_wav(self) -> None:
        formats = {
            "mp3": ["-c:a", "libmp3lame"],
            "wav": ["-c:a", "pcm_s16le"],
            "m4a": ["-c:a", "aac"],
            "aac": ["-c:a", "aac", "-f", "adts"],
            "ogg": ["-c:a", "libopus"],
            "opus": ["-c:a", "libopus", "-f", "ogg"],
            "mp4": ["-c:a", "aac", "-f", "mp4"],
        }
        for extension, encoding in formats.items():
            with self.subTest(extension=extension):
                source = self.root / f"fixture.{extension}"
                self._generate(source, encoding)
                probe = await self.service.probe(source)
                self.assertGreater(probe.duration_seconds, 0.8)
                self.assertGreater(source.stat().st_size, 0)
                stages: list[str] = []

                async def record_stage(stage: str) -> None:
                    stages.append(stage)

                async with self.service.prepare(
                    source,
                    probe=probe,
                    on_stage=record_stage,
                ) as prepared:
                    normalized = await self.service.probe(prepared.path)
                    self.assertIn("wav", normalized.container)
                    self.assertEqual(normalized.codec, "pcm_s16le")
                    self.assertEqual(normalized.sample_rate, 16000)
                    self.assertEqual(normalized.channels, 1)
                    self.assertNotEqual(prepared.path, source)
                    self.assertTrue(source.is_file())
                self.assertEqual(stages, ["normalizing"])

    async def test_corrupt_audio_and_duration_limit_fail_cleanly(self) -> None:
        corrupt = self.root / "corrupt.mp3"
        corrupt.write_bytes(b"ID3\x04\x00\x00not-valid-audio")
        with self.assertRaises(InvalidAudioContentError):
            await self.service.probe(corrupt)

        valid = self.root / "too-long.wav"
        self._generate(valid, ["-c:a", "pcm_s16le"], duration="1.2")
        limited = AudioNormalizationService(max_duration_seconds=0.5)
        with self.assertRaises(AudioDurationLimitError):
            await limited.probe(valid)

    def _generate(
        self,
        target: Path,
        encoding: list[str],
        *,
        duration: str = "1.1",
    ) -> None:
        result = subprocess.run(
            [
                shutil.which("ffmpeg") or "ffmpeg",
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"sine=frequency=440:duration={duration}",
                *encoding,
                str(target),
            ],
            capture_output=True,
            check=False,
            shell=False,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))


class AudioToolPreflightTests(unittest.TestCase):
    def test_missing_ffmpeg_is_reported_without_starting_a_shell(self) -> None:
        service = AudioNormalizationService(
            ffmpeg_binary="definitely-missing-restaurant-ops-ffmpeg",
            ffprobe_binary="definitely-missing-restaurant-ops-ffprobe",
        )
        self.assertFalse(service.is_available)
        with self.assertRaises(AudioToolUnavailableError):
            service.require_available()


if __name__ == "__main__":
    unittest.main()
