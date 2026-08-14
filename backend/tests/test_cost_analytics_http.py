import tempfile
import unittest
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import AsyncIterator

from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.auth.security import create_access_token, hash_password
from backend.database.base import Base
from backend.database.session import get_db
from backend.main import app
from backend.models.audio_upload import AudioUpload
from backend.models.report import AudioOperationsReport, ReportLocation
from backend.models.user import User
from backend.models.workspace import Workspace, WorkspaceMembership


class CostAnalyticsHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        database_path = Path(self.temp_directory.name) / "cost-analytics-http.db"
        self.engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
        self.session_factory = async_sessionmaker(
            self.engine, class_=AsyncSession, expire_on_commit=False
        )
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

        async with self.session_factory() as session:
            self.user = User(
                email="cost-manager@example.com",
                full_name="Cost Manager",
                hashed_password=hash_password("CostAnalyticsPassword123!"),
                is_active=True,
            )
            self.other_user = User(
                email="other-cost-manager@example.com",
                full_name="Other Cost Manager",
                hashed_password=hash_password("CostAnalyticsPassword123!"),
                is_active=True,
            )
            session.add_all([self.user, self.other_user])
            await session.flush()
            self.workspace = Workspace(name="Cost Workspace")
            self.other_workspace = Workspace(name="Other Cost Workspace")
            session.add_all([self.workspace, self.other_workspace])
            await session.flush()
            self.main_kitchen = ReportLocation(
                workspace_id=self.workspace.id,
                name="Main Kitchen",
                currency_code="INR",
            )
            self.pastry_kitchen = ReportLocation(
                workspace_id=self.workspace.id,
                name="Pastry Kitchen",
                currency_code="INR",
            )
            self.other_kitchen = ReportLocation(
                workspace_id=self.other_workspace.id,
                name="Other Kitchen",
                currency_code="INR",
            )
            session.add_all(
                [self.main_kitchen, self.pastry_kitchen, self.other_kitchen]
            )
            await session.flush()
            session.add_all(
                [
                    WorkspaceMembership(
                        workspace_id=self.workspace.id,
                        user_id=self.user.id,
                        role="owner",
                    ),
                    WorkspaceMembership(
                        workspace_id=self.other_workspace.id,
                        user_id=self.other_user.id,
                        role="owner",
                    ),
                ]
            )
            await self._add_report(
                session,
                owner_id=self.user.id,
                workspace_id=self.workspace.id,
                location_id=self.main_kitchen.id,
                filename="staff-note.wav",
                processed_at=datetime(2026, 8, 14, 10, tzinfo=timezone.utc),
                duration=60.0,
                category="staff",
                severity="low",
                sarvam_cost=Decimal("0.50000000"),
                openai_cost=Decimal("0.00200000"),
                total_tokens=1250,
            )
            await self._add_report(
                session,
                owner_id=self.user.id,
                workspace_id=self.workspace.id,
                location_id=self.pastry_kitchen.id,
                filename="inventory-note.wav",
                processed_at=datetime(2026, 8, 14, 11, tzinfo=timezone.utc),
                duration=120.0,
                category="inventory",
                severity="critical",
                sarvam_cost=Decimal("1.00000000"),
                openai_cost=Decimal("0.00600000"),
                total_tokens=2750,
            )
            await self._add_report(
                session,
                owner_id=self.user.id,
                workspace_id=self.workspace.id,
                location_id=self.main_kitchen.id,
                filename="legacy-customer-note.wav",
                processed_at=datetime(2026, 8, 14, 12, tzinfo=timezone.utc),
                duration=30.0,
                category="customer",
                severity="medium",
                sarvam_cost=None,
                openai_cost=None,
                total_tokens=None,
            )
            await self._add_report(
                session,
                owner_id=self.other_user.id,
                workspace_id=self.other_workspace.id,
                location_id=self.other_kitchen.id,
                filename="other-tenant.wav",
                processed_at=datetime(2026, 8, 14, 13, tzinfo=timezone.utc),
                duration=3600.0,
                category="operations",
                severity="high",
                sarvam_cost=Decimal("999.00000000"),
                openai_cost=Decimal("999.00000000"),
                total_tokens=999999,
            )
            await session.commit()

        async def override_database() -> AsyncIterator[AsyncSession]:
            async with self.session_factory() as session:
                yield session

        app.dependency_overrides[get_db] = override_database
        self.client = AsyncClient(
            transport=ASGITransport(app=app), base_url="http://testserver"
        )
        self.headers = {
            "Authorization": f"Bearer {create_access_token(str(self.user.id))}"
        }
        self.other_headers = {
            "Authorization": f"Bearer {create_access_token(str(self.other_user.id))}"
        }

    async def asyncTearDown(self) -> None:
        await self.client.aclose()
        app.dependency_overrides.clear()
        await self.engine.dispose()
        self.temp_directory.cleanup()

    async def test_aggregates_costs_without_combining_currencies(self) -> None:
        response = await self.client.get(
            "/api/v1/cost-analytics",
            params=self._params(),
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        metrics = payload["metrics"]
        self.assertEqual(metrics["total_audio_uploads"], 3)
        self.assertEqual(metrics["costed_audio_uploads"], 2)
        self.assertEqual(metrics["missing_cost_data_uploads"], 1)
        self.assertEqual(metrics["total_recorded_audio_duration_seconds"], 210.0)
        self.assertEqual(metrics["costed_audio_duration_seconds"], 180.0)
        self.assertEqual(Decimal(metrics["total_sarvam_cost_inr"]), Decimal("1.5"))
        self.assertEqual(Decimal(metrics["total_openai_cost_usd"]), Decimal("0.008"))
        self.assertEqual(
            Decimal(metrics["average_sarvam_cost_per_upload_inr"]),
            Decimal("0.75"),
        )
        self.assertEqual(
            Decimal(metrics["estimated_sarvam_cost_per_recorded_hour_inr"]),
            Decimal("30"),
        )
        self.assertEqual(
            Decimal(metrics["estimated_openai_cost_per_recorded_hour_usd"]),
            Decimal("0.16"),
        )
        self.assertNotIn("total_estimated_cost", metrics)
        self.assertNotIn("usd_to_inr", response.text.lower())
        self.assertNotIn("999", response.text)

        severity = {item["key"]: item for item in payload["by_severity"]}
        self.assertEqual(severity["high"]["total_audio_uploads"], 1)
        category = {item["key"]: item for item in payload["by_category"]}
        self.assertEqual(category["other"]["missing_cost_data_uploads"], 1)
        self.assertEqual(payload["recent_usage"][0]["original_filename"], "legacy-customer-note.wav")
        self.assertIsNone(payload["recent_usage"][0]["sarvam_estimated_cost_inr"])
        self.assertEqual(payload["recent_usage"][1]["severity"], "critical")
        self.assertEqual(payload["recent_usage"][2]["openai_total_tokens"], 1250)

    async def test_filters_by_location_and_limits_recent_usage(self) -> None:
        response = await self.client.get(
            "/api/v1/cost-analytics",
            params={
                **self._params(),
                "location_id": str(self.main_kitchen.id),
                "recent_limit": "1",
            },
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["metrics"]["total_audio_uploads"], 2)
        self.assertEqual(payload["metrics"]["costed_audio_uploads"], 1)
        self.assertEqual(payload["metrics"]["missing_cost_data_uploads"], 1)
        self.assertEqual(len(payload["by_location"]), 1)
        self.assertEqual(payload["by_location"][0]["label"], "Main Kitchen")
        self.assertEqual(len(payload["recent_usage"]), 1)

    async def test_requires_auth_and_rejects_cross_tenant_access(self) -> None:
        unauthenticated = await self.client.get(
            "/api/v1/cost-analytics", params=self._params()
        )
        cross_tenant = await self.client.get(
            "/api/v1/cost-analytics",
            params=self._params(),
            headers=self.other_headers,
        )

        self.assertEqual(unauthenticated.status_code, 401)
        self.assertEqual(cross_tenant.status_code, 404)

    async def test_validates_date_range_and_query_bounds(self) -> None:
        reversed_range = await self.client.get(
            "/api/v1/cost-analytics",
            params={
                **self._params(),
                "start_date": "2026-08-15",
                "end_date": "2026-08-14",
            },
            headers=self.headers,
        )
        oversized_range = await self.client.get(
            "/api/v1/cost-analytics",
            params={
                **self._params(),
                "start_date": "2025-01-01",
                "end_date": "2026-08-14",
            },
            headers=self.headers,
        )
        invalid_limit = await self.client.get(
            "/api/v1/cost-analytics",
            params={**self._params(), "recent_limit": "101"},
            headers=self.headers,
        )

        self.assertEqual(reversed_range.status_code, 422)
        self.assertEqual(oversized_range.status_code, 422)
        self.assertEqual(invalid_limit.status_code, 422)

    def _params(self) -> dict[str, str]:
        return {
            "workspace_id": str(self.workspace.id),
            "start_date": "2026-08-14",
            "end_date": "2026-08-14",
        }

    @staticmethod
    async def _add_report(
        session: AsyncSession,
        *,
        owner_id: uuid.UUID,
        workspace_id: uuid.UUID,
        location_id: uuid.UUID,
        filename: str,
        processed_at: datetime,
        duration: float,
        category: str,
        severity: str,
        sarvam_cost: Decimal | None,
        openai_cost: Decimal | None,
        total_tokens: int | None,
    ) -> None:
        identifier = uuid.uuid4().hex
        upload = AudioUpload(
            owner_id=owner_id,
            workspace_id=workspace_id,
            location_id=location_id,
            audio_duration_seconds=duration,
            sarvam_model="saaras:v3" if sarvam_cost is not None else None,
            sarvam_estimated_cost_inr=sarvam_cost,
            openai_model="gpt-4o" if openai_cost is not None else None,
            openai_input_tokens=total_tokens,
            openai_output_tokens=0 if total_tokens is not None else None,
            openai_total_tokens=total_tokens,
            openai_estimated_cost_usd=openai_cost,
            original_filename=filename,
            storage_key=f"cost-tests/{identifier}.wav",
            media_type="audio/wav",
            extension="wav",
            size_bytes=1024,
            sha256=identifier.ljust(64, "0"),
            status="ready",
            scan_status="clean",
            processed_at=processed_at,
        )
        session.add(upload)
        await session.flush()
        session.add(
            AudioOperationsReport(
                upload_id=upload.id,
                owner_id=owner_id,
                workspace_id=workspace_id,
                location_id=location_id,
                transcript="Test transcript",
                summary="Test summary",
                category=category,
                severity=severity,
                requires_attention=severity in {"high", "critical"},
                recommended_action="Test action",
                source="AI Audio Monitor",
                processed_at=processed_at,
            )
        )


if __name__ == "__main__":
    unittest.main()
