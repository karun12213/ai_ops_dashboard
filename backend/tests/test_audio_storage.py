import tempfile
import unittest
import uuid
from pathlib import Path

from backend.services.audio_validation import UnsupportedAudioError, sanitize_filename, validate_audio
from backend.storage.audio_storage import InvalidStorageKeyError, LocalAudioStorage


class AudioValidationTests(unittest.TestCase):
    def test_detects_each_supported_signature(self) -> None:
        cases = (
            (b"ID3\x04\x00\x00", "recording.mp3", "audio/mpeg", "mp3"),
            (b"RIFF\x10\x00\x00\x00WAVEfmt ", "recording.wav", "audio/x-wav", "wav"),
            (b"\x00\x00\x00\x18ftypM4A \x00", "recording.m4a", "audio/mp4", "m4a"),
            (b"\xff\xf1\x50\x80", "recording.aac", "audio/aac", "aac"),
            (b"OggS\x00\x02", "recording.ogg", "application/ogg", "ogg"),
        )

        for signature, filename, media_type, extension in cases:
            with self.subTest(extension=extension):
                detected = validate_audio(
                    prefix=signature,
                    filename=filename,
                    client_media_type=media_type,
                )
                self.assertEqual(detected.extension, extension)

    def test_rejects_extension_signature_and_media_type_conflicts(self) -> None:
        invalid_cases = (
            (b"not audio", "recording.mp3", "audio/mpeg"),
            (b"ID3\x04\x00\x00", "recording.wav", "audio/wav"),
            (b"ID3\x04\x00\x00", "recording.mp3", "audio/wav"),
            (b"ID3\x04\x00\x00", "recording.exe", "audio/mpeg"),
        )

        for prefix, filename, media_type in invalid_cases:
            with self.subTest(filename=filename, media_type=media_type):
                with self.assertRaises(UnsupportedAudioError):
                    validate_audio(
                        prefix=prefix,
                        filename=filename,
                        client_media_type=media_type,
                    )

    def test_sanitizes_paths_and_control_characters(self) -> None:
        self.assertEqual(sanitize_filename("../../private/voice.mp3"), "voice.mp3")
        self.assertEqual(sanitize_filename("..\\private\\voice.mp3"), "voice.mp3")
        self.assertEqual(sanitize_filename("\x00\n"), "audio")


class LocalAudioStorageTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_directory.name) / "objects"
        self.storage = LocalAudioStorage(self.root)
        self.owner_id = uuid.uuid4()
        self.upload_id = uuid.uuid4()
        self.key = f"{self.owner_id.hex}/{self.upload_id.hex}.mp3"

    async def asyncTearDown(self) -> None:
        self.temp_directory.cleanup()

    async def test_atomic_save_stream_delete_and_temporary_cleanup(self) -> None:
        temporary_path = self.storage.create_temporary_path()
        temporary_path.write_bytes(b"ID3payload")

        await self.storage.save(temporary_path, self.key)

        self.assertFalse(temporary_path.exists())
        self.assertTrue(await self.storage.exists(self.key))
        self.assertEqual(self.storage.get_path(self.key), (self.root / self.key).resolve())
        chunks = [chunk async for chunk in self.storage.iter_bytes(self.key, chunk_size=3)]
        self.assertEqual(b"".join(chunks), b"ID3payload")
        await self.storage.delete(self.key)
        self.assertFalse(await self.storage.exists(self.key))

        disposable_path = self.storage.create_temporary_path()
        await self.storage.discard_temporary(disposable_path)
        self.assertFalse(disposable_path.exists())

    async def test_rejects_path_traversal_and_non_server_key_shapes(self) -> None:
        invalid_keys = (
            "../outside.mp3",
            f"{self.owner_id.hex}/../../outside.mp3",
            f"{self.owner_id}/file.mp3",
            f"{self.owner_id.hex}/file.exe",
            "/absolute/file.mp3",
        )

        for key in invalid_keys:
            with self.subTest(key=key):
                with self.assertRaises(InvalidStorageKeyError):
                    await self.storage.exists(key)
                with self.assertRaises(InvalidStorageKeyError):
                    self.storage.get_path(key)


if __name__ == "__main__":
    unittest.main()
