"""Safe development preflight checks with no paid provider calls."""

import argparse
import asyncio
import socket
import sys
import tempfile
from pathlib import Path

from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import text

from backend.database.session import AsyncSessionLocal, engine
from backend.services.audio_processing import AudioNormalizationService
from backend.utils.config import get_settings


async def _database_and_migration() -> tuple[bool, str | None]:
    try:
        async with AsyncSessionLocal() as session:
            await session.execute(text("SELECT 1"))
            current = await session.scalar(text("SELECT version_num FROM alembic_version"))
        return True, str(current) if current else None
    except Exception:
        return False, None


def _migration_head() -> str:
    config = Config(str(Path(__file__).parent / "alembic.ini"))
    return ScriptDirectory.from_config(config).get_current_head()


def _storage_available(root: Path) -> bool:
    try:
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(prefix="preflight-", dir=root, delete=True) as handle:
            handle.write(b"storage-check")
            handle.flush()
        return True
    except OSError:
        return False


def _key_configured(secret) -> bool:
    return bool(secret and secret.get_secret_value().strip())


def _dns_available(hostname: str) -> bool:
    try:
        socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)
        return True
    except OSError:
        return False


async def run(*, backend_url: str, check_dns: bool) -> int:
    settings = get_settings()
    database_ok, current_revision = await _database_and_migration()
    expected_head = _migration_head()
    storage_root = Path(settings.audio_local_storage_path).expanduser().resolve()
    storage_ok = _storage_available(storage_root)
    audio_tools = AudioNormalizationService()
    sarvam_ok = _key_configured(settings.sarvam_api_key)
    openai_ok = _key_configured(settings.openai_api_key)
    migration_ok = database_ok and current_revision == expected_head

    print(f"Database: {'AVAILABLE' if database_ok else 'UNAVAILABLE'}")
    print(f"Sarvam key configured: {'YES' if sarvam_ok else 'NO'}")
    print(f"OpenAI key configured: {'YES' if openai_ok else 'NO'}")
    print(f"Audio storage: {'AVAILABLE' if storage_ok else 'UNAVAILABLE'}")
    print(f"FFmpeg: {'AVAILABLE' if audio_tools.is_available else 'UNAVAILABLE'}")
    print(f"Backend base URL: {backend_url.rstrip('/')}")
    print(f"Current migration: {current_revision or 'UNAVAILABLE'}")
    print(f"Migration head: {expected_head}")
    if check_dns:
        print(
            "Sarvam DNS: "
            + ("AVAILABLE" if _dns_available("api.sarvam.ai") else "UNAVAILABLE")
        )
        print(
            "OpenAI DNS: "
            + ("AVAILABLE" if _dns_available("api.openai.com") else "UNAVAILABLE")
        )

    required = database_ok and migration_ok and storage_ok and audio_tools.is_available
    required = required and sarvam_ok and openai_ok
    await engine.dispose()
    return 0 if required else 1


def main() -> None:
    parser = argparse.ArgumentParser(description="Restaurant Ops development preflight")
    parser.add_argument(
        "--backend-url",
        default="http://127.0.0.1:8000",
        help="Backend URL printed for Flutter configuration",
    )
    parser.add_argument(
        "--check-dns",
        action="store_true",
        help="Resolve provider hostnames without making API requests",
    )
    args = parser.parse_args()
    raise SystemExit(asyncio.run(run(backend_url=args.backend_url, check_dns=args.check_dns)))


if __name__ == "__main__":
    main()
