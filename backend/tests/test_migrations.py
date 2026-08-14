import asyncio
import tempfile
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import sqlalchemy as sa
from alembic import command
from alembic.config import Config
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.auth.security import hash_password
from backend.database.base import Base
from backend.models.audio_upload import AudioUpload
from backend.models.dashboard import DashboardActivity, DashboardDailySnapshot, DashboardHourlySales
from backend.models.refresh_session import RefreshSession
from backend.models.report import ReportDailySales, ReportLocation
from backend.models.user import User
from backend.models.workspace import Workspace, WorkspaceMembership

REPO_ROOT = Path(__file__).resolve().parents[2]


def _alembic_config(database_url: str) -> Config:
    config = Config(str(REPO_ROOT / "backend" / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", database_url)
    return config


class FreshDatabaseTests(unittest.TestCase):
    def test_create_all_registers_current_application_tables(self) -> None:
        asyncio.run(self._create_all_and_check())

    @staticmethod
    async def _create_all_and_check() -> None:
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "fresh.db"
            engine = create_async_engine(f"sqlite+aiosqlite:///{database_path.as_posix()}")
            async with engine.begin() as connection:
                await connection.run_sync(Base.metadata.create_all)
                tables = set(
                    await connection.run_sync(lambda sync_conn: sa.inspect(sync_conn).get_table_names())
                )
            await engine.dispose()

        assert "users" in tables
        assert "refresh_sessions" in tables
        assert "dashboard_daily_snapshots" in tables
        assert "dashboard_hourly_sales" in tables
        assert "dashboard_activities" in tables
        assert "report_locations" in tables
        assert "report_daily_sales" in tables
        assert "audio_uploads" in tables
        assert "audio_operations_reports" in tables
        assert "workspaces" in tables
        assert "workspace_memberships" in tables

    def test_alembic_upgrade_builds_complete_fresh_schema(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "fresh-migrated.db"
            async_url = f"sqlite+aiosqlite:///{database_path.as_posix()}"
            sync_url = f"sqlite:///{database_path.as_posix()}"

            command.upgrade(_alembic_config(async_url), "head")

            engine = sa.create_engine(sync_url)
            inspector = sa.inspect(engine)
            tables = set(inspector.get_table_names())
            user_columns = {column["name"] for column in inspector.get_columns("users")}
            refresh_foreign_keys = inspector.get_foreign_keys("refresh_sessions")
            report_foreign_keys = inspector.get_foreign_keys("report_daily_sales")
            report_indexes = {
                tuple(index["column_names"])
                for index in inspector.get_indexes("report_daily_sales")
            }
            audio_foreign_keys = inspector.get_foreign_keys("audio_uploads")
            audio_columns = {
                column["name"] for column in inspector.get_columns("audio_uploads")
            }
            audio_indexes = {
                tuple(index["column_names"])
                for index in inspector.get_indexes("audio_uploads")
            }
            membership_foreign_keys = inspector.get_foreign_keys("workspace_memberships")
            membership_indexes = {
                tuple(index["column_names"])
                for index in inspector.get_indexes("workspace_memberships")
            }
            location_columns = {
                column["name"] for column in inspector.get_columns("report_locations")
            }
            snapshot_columns = {
                column["name"]
                for column in inspector.get_columns("dashboard_daily_snapshots")
            }
            activity_columns = {
                column["name"] for column in inspector.get_columns("dashboard_activities")
            }
            with engine.connect() as connection:
                version = connection.execute(
                    sa.text("SELECT version_num FROM alembic_version")
                ).scalar_one()
            engine.dispose()

        self.assertEqual(
            tables,
            {
                "alembic_version",
                "audio_uploads",
                "audio_operations_reports",
                "dashboard_activities",
                "dashboard_daily_snapshots",
                "dashboard_hourly_sales",
                "refresh_sessions",
                "report_daily_sales",
                "report_locations",
                "users",
                "workspace_memberships",
                "workspaces",
            },
        )
        self.assertEqual(
            user_columns,
            {
                "id",
                "email",
                "full_name",
                "hashed_password",
                "is_active",
                "is_superuser",
                "created_at",
                "updated_at",
            },
        )
        self.assertTrue(
            any(foreign_key["referred_table"] == "users" for foreign_key in refresh_foreign_keys)
        )
        self.assertTrue(
            any(
                foreign_key["referred_table"] == "report_locations"
                for foreign_key in report_foreign_keys
            )
        )
        self.assertIn(("service_date",), report_indexes)
        self.assertIn(("location_id", "service_date"), report_indexes)
        self.assertTrue(
            any(foreign_key["referred_table"] == "users" for foreign_key in audio_foreign_keys)
        )
        self.assertIn(("owner_id", "created_at"), audio_indexes)
        self.assertTrue(
            {
                "english_transcript",
                "detected_language_code",
                "audio_container",
                "audio_codec",
                "audio_duration_seconds",
                "transcription_strategy",
                "provider_job_id",
                "provider_job_state",
                "sarvam_model",
                "sarvam_request_id",
                "sarvam_job_id",
                "sarvam_estimated_cost_inr",
                "openai_input_tokens",
                "openai_cached_input_tokens",
                "openai_output_tokens",
                "openai_total_tokens",
                "openai_model",
                "openai_request_id",
                "openai_request_ids",
                "openai_estimated_cost_usd",
                "total_estimated_cost",
                "processing_stage",
                "failure_stage",
                "failure_code",
                "failure_message",
                "retryable",
                "processed_at",
            }.issubset(audio_columns)
        )
        self.assertEqual(
            {foreign_key["referred_table"] for foreign_key in membership_foreign_keys},
            {"users", "workspaces"},
        )
        self.assertIn(("user_id", "workspace_id"), membership_indexes)
        self.assertIn("workspace_id", location_columns)
        self.assertIn("location_id", snapshot_columns)
        self.assertIn("location_id", activity_columns)
        self.assertIn("audio_upload_id", activity_columns)
        self.assertTrue(
            any(foreign_key["referred_table"] == "workspaces" for foreign_key in audio_foreign_keys)
        )
        self.assertTrue(
            any(
                foreign_key["referred_table"] == "report_locations"
                for foreign_key in audio_foreign_keys
            )
        )
        self.assertEqual(version, "20260814_10")


class PreMigrationDatabaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        self.database_path = Path(self.temp_directory.name) / "pre-migration.db"
        self.async_url = f"sqlite+aiosqlite:///{self.database_path.as_posix()}"
        self.sync_url = f"sqlite:///{self.database_path.as_posix()}"
        asyncio.run(self._seed_pre_migration_database())

    async def _seed_pre_migration_database(self) -> None:
        # Simulate a database created by the pre-fix application: only the
        # `users` table exists (via create_all as it worked before this
        # change), with a real seeded account, and no `refresh_sessions` or
        # `alembic_version` tracking table yet.
        engine = create_async_engine(self.async_url)
        async with engine.begin() as connection:
            await connection.run_sync(User.__table__.create)

        session_factory = async_sessionmaker(bind=engine, class_=AsyncSession, expire_on_commit=False)
        async with session_factory() as session:
            session.add(
                User(
                    email="existing-operator@example.com",
                    full_name="Existing Operator",
                    hashed_password=hash_password("OriginalPassword123!"),
                    is_active=True,
                )
            )
            await session.commit()
        await engine.dispose()

    def tearDown(self) -> None:
        self.temp_directory.cleanup()

    def test_alembic_upgrade_preserves_existing_users(self) -> None:
        config = _alembic_config(self.async_url)
        command.upgrade(config, "head")

        engine = sa.create_engine(self.sync_url)
        with engine.connect() as connection:
            tables = set(sa.inspect(connection).get_table_names())
            row = connection.execute(
                sa.text("SELECT email, hashed_password FROM users WHERE email = :email"),
                {"email": "existing-operator@example.com"},
            ).one()
        engine.dispose()

        self.assertIn("refresh_sessions", tables)
        self.assertIn("dashboard_daily_snapshots", tables)
        self.assertIn("dashboard_hourly_sales", tables)
        self.assertIn("dashboard_activities", tables)
        self.assertIn("report_locations", tables)
        self.assertIn("report_daily_sales", tables)
        self.assertIn("audio_uploads", tables)
        self.assertIn("audio_operations_reports", tables)
        self.assertIn("workspaces", tables)
        self.assertIn("workspace_memberships", tables)
        self.assertIn("users", tables)
        self.assertEqual(row.email, "existing-operator@example.com")
        self.assertTrue(row.hashed_password.startswith("$argon2id$"))

    def test_alembic_downgrade_is_lossless_for_users(self) -> None:
        config = _alembic_config(self.async_url)
        command.upgrade(config, "head")
        command.downgrade(config, "base")

        engine = sa.create_engine(self.sync_url)
        with engine.connect() as connection:
            tables = set(sa.inspect(connection).get_table_names())
            row = connection.execute(
                sa.text("SELECT email FROM users WHERE email = :email"),
                {"email": "existing-operator@example.com"},
            ).one()
        engine.dispose()

        self.assertNotIn("refresh_sessions", tables)
        self.assertNotIn("dashboard_daily_snapshots", tables)
        self.assertNotIn("dashboard_hourly_sales", tables)
        self.assertNotIn("dashboard_activities", tables)
        self.assertNotIn("report_locations", tables)
        self.assertNotIn("report_daily_sales", tables)
        self.assertNotIn("audio_uploads", tables)
        self.assertNotIn("workspaces", tables)
        self.assertNotIn("workspace_memberships", tables)
        self.assertIn("users", tables)
        self.assertEqual(row.email, "existing-operator@example.com")


class CreateAllDatabaseAdoptionTests(unittest.TestCase):
    def test_upgrade_adopts_existing_auth_tables_without_changing_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "create-all-database.db"
            async_url = f"sqlite+aiosqlite:///{database_path.as_posix()}"
            sync_url = f"sqlite:///{database_path.as_posix()}"
            user_id = uuid.uuid4()
            refresh_session_id = uuid.uuid4()
            original_hash = hash_password("OriginalPassword123!")
            original_token_hash = "a" * 64

            asyncio.run(
                self._create_existing_database(
                    async_url=async_url,
                    user_id=user_id,
                    refresh_session_id=refresh_session_id,
                    password_hash=original_hash,
                    token_hash=original_token_hash,
                )
            )

            command.upgrade(_alembic_config(async_url), "head")

            engine = sa.create_engine(sync_url)
            with engine.connect() as connection:
                user_row = connection.execute(
                    sa.text(
                        "SELECT id, email, hashed_password FROM users WHERE email = :email"
                    ),
                    {"email": "existing-operator@example.com"},
                ).one()
                session_row = connection.execute(
                    sa.text(
                        "SELECT id, user_id, token_hash FROM refresh_sessions "
                        "WHERE token_hash = :token_hash"
                    ),
                    {"token_hash": original_token_hash},
                ).one()
                version = connection.execute(
                    sa.text("SELECT version_num FROM alembic_version")
                ).scalar_one()
            engine.dispose()

        self.assertEqual(str(user_row.id), user_id.hex)
        self.assertEqual(user_row.email, "existing-operator@example.com")
        self.assertEqual(user_row.hashed_password, original_hash)
        self.assertEqual(str(session_row.id), refresh_session_id.hex)
        self.assertEqual(str(session_row.user_id), user_id.hex)
        self.assertEqual(session_row.token_hash, original_token_hash)
        self.assertEqual(version, "20260814_10")

    @staticmethod
    async def _create_existing_database(
        *,
        async_url: str,
        user_id: uuid.UUID,
        refresh_session_id: uuid.UUID,
        password_hash: str,
        token_hash: str,
    ) -> None:
        engine = create_async_engine(async_url)
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        session_factory = async_sessionmaker(
            bind=engine,
            class_=AsyncSession,
            expire_on_commit=False,
        )
        async with session_factory() as session:
            session.add(
                User(
                    id=user_id,
                    email="existing-operator@example.com",
                    full_name="Existing Operator",
                    hashed_password=password_hash,
                    is_active=True,
                )
            )
            session.add(
                RefreshSession(
                    id=refresh_session_id,
                    user_id=user_id,
                    token_hash=token_hash,
                    issued_at=datetime.now(timezone.utc),
                    expires_at=datetime.now(timezone.utc) + timedelta(days=7),
                )
            )
            await session.commit()
        await engine.dispose()


if __name__ == "__main__":
    unittest.main()
