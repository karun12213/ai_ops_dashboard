from dataclasses import dataclass
from pathlib import PurePath


class AudioValidationError(ValueError):
    pass


class UnsupportedAudioError(AudioValidationError):
    pass


@dataclass(frozen=True)
class DetectedAudio:
    extension: str
    media_type: str


_SUPPORTED_MEDIA_TYPES = {
    "mp3": ("audio/mpeg", frozenset({"audio/mpeg", "audio/mp3"})),
    "wav": ("audio/wav", frozenset({"audio/wav", "audio/x-wav", "audio/wave"})),
    "m4a": ("audio/mp4", frozenset({"audio/mp4", "audio/m4a", "audio/x-m4a"})),
    "aac": ("audio/aac", frozenset({"audio/aac", "audio/x-aac"})),
    "ogg": ("audio/ogg", frozenset({"audio/ogg", "application/ogg"})),
    "opus": ("audio/ogg", frozenset({"audio/ogg", "audio/opus", "application/ogg"})),
    "mp4": ("audio/mp4", frozenset({"audio/mp4", "video/mp4", "application/mp4"})),
}
_GENERIC_MEDIA_TYPES = frozenset({"", "application/octet-stream"})
_MP4_BRANDS = frozenset({b"M4A ", b"M4B ", b"isom", b"iso2", b"mp41", b"mp42", b"qt  "})


def sanitize_filename(filename: str | None) -> str:
    candidate = (filename or "audio").replace("\\", "/").split("/")[-1]
    cleaned = "".join(character for character in candidate if character.isprintable()).strip()
    if not cleaned or cleaned in {".", ".."}:
        cleaned = "audio"
    return cleaned[:255]


def validate_audio(
    *,
    prefix: bytes,
    filename: str | None,
    client_media_type: str | None,
) -> DetectedAudio:
    safe_filename = sanitize_filename(filename)
    requested_extension = PurePath(safe_filename).suffix.lower().lstrip(".")
    if requested_extension not in _SUPPORTED_MEDIA_TYPES:
        raise UnsupportedAudioError("Unsupported audio filename extension")

    detected = _detect_signature(prefix)
    if detected is None:
        raise UnsupportedAudioError("Unsupported or invalid audio file signature")
    compatible_extensions = {
        "ogg": frozenset({"ogg", "opus"}),
        "mp4": frozenset({"m4a", "mp4"}),
    }.get(detected.extension, frozenset({detected.extension}))
    if requested_extension not in compatible_extensions:
        raise UnsupportedAudioError("Audio signature does not match the filename extension")

    normalized_media_type = (client_media_type or "").split(";", 1)[0].strip().lower()
    accepted_media_types = _SUPPORTED_MEDIA_TYPES[requested_extension][1]
    if normalized_media_type not in _GENERIC_MEDIA_TYPES | accepted_media_types:
        raise UnsupportedAudioError("Client media type conflicts with detected audio format")
    canonical_media_type = _SUPPORTED_MEDIA_TYPES[requested_extension][0]
    return DetectedAudio(extension=requested_extension, media_type=canonical_media_type)


def _detect_signature(prefix: bytes) -> DetectedAudio | None:
    if len(prefix) >= 12 and prefix[:4] == b"RIFF" and prefix[8:12] == b"WAVE":
        return DetectedAudio(extension="wav", media_type="audio/wav")
    if len(prefix) >= 4 and prefix[:4] == b"OggS":
        return DetectedAudio(extension="ogg", media_type="audio/ogg")
    if len(prefix) >= 12 and prefix[4:8] == b"ftyp" and prefix[8:12] in _MP4_BRANDS:
        return DetectedAudio(extension="mp4", media_type="audio/mp4")
    if len(prefix) >= 2 and prefix[0] == 0xFF and (prefix[1] & 0xF6) == 0xF0:
        return DetectedAudio(extension="aac", media_type="audio/aac")
    if prefix.startswith(b"ID3") or _looks_like_mpeg_layer_three(prefix):
        return DetectedAudio(extension="mp3", media_type="audio/mpeg")
    return None


def _looks_like_mpeg_layer_three(prefix: bytes) -> bool:
    if len(prefix) < 2 or prefix[0] != 0xFF or prefix[1] & 0xE0 != 0xE0:
        return False
    version_bits = (prefix[1] >> 3) & 0x03
    layer_bits = (prefix[1] >> 1) & 0x03
    return version_bits != 0x01 and layer_bits == 0x01
