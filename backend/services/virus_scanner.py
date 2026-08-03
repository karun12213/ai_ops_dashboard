from abc import ABC, abstractmethod
from enum import StrEnum
from pathlib import Path


class ScanVerdict(StrEnum):
    NOT_CONFIGURED = "not_configured"
    CLEAN = "clean"
    INFECTED = "infected"


class AudioScanError(RuntimeError):
    pass


class AudioVirusScanner(ABC):
    @abstractmethod
    async def scan(self, path: Path) -> ScanVerdict:
        raise NotImplementedError


class NoOpAudioVirusScanner(AudioVirusScanner):
    async def scan(self, path: Path) -> ScanVerdict:
        if not path.is_file():
            raise AudioScanError("Audio upload was unavailable for scanning")
        return ScanVerdict.NOT_CONFIGURED
