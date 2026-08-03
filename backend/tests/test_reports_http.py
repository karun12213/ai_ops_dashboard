import csv
import io
import tempfile
import unittest
import uuid
from datetime import date
from pathlib import Path
from typing import AsyncIterator
from unittest.mock import patch

from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.auth.security import create_access_token, hash_password
from backend.database.base import Base
from backend.database.session import get_db
from backend.main import app
from backend.models.report import ReportDailySales, ReportLocation
from backend.models.user import User
from backend.models.workspace import Workspace, WorkspaceMembership


class ReportsHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        database_path = Path(self.temp_directory.name) / "reports-http.db"
        self.engine = create_async_engine(f"sqlite+aiosqlite:///{database_path.as_posix()}")
        self.session_factory = async_sessionmaker(
            bind=self.engine,
            class_=AsyncSession,
            expire_on_commit=False,
        )
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

        async with self.session_factory() as session:
            self.user = User(
                email="reports-operator@example.com",
                full_name="Reports Operator",
                hashed_password=hash_password("ReportsTestPassword123!"),
                is_active=True,
            )
            self.other_user = User(
                email="other-reports-operator@example.com",
                full_name="Other Reports Operator",
                hashed_password=hash_password("ReportsTestPassword123!"),
                is_active=True,
            )
            session.add_all([self.user, self.other_user])
            await session.flush()
            self.workspace = Workspace(name="Reports Workspace")
            self.other_workspace = Workspace(name="Other Reports Workspace")
            session.add_all([self.workspace, self.other_workspace])
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
            await session.commit()
            await session.refresh(self.user)
            await session.refresh(self.other_user)
            await session.refresh(self.workspace)
            await session.refresh(self.other_workspace)

        async def override_database() -> AsyncIterator[AsyncSession]:
            async with self.session_factory() as session:
                yield session

        app.dependency_overrides[get_db] = override_database
        self.client = AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://testserver",
        )
        self.headers = {"Authorization": f"Bearer {create_access_token(str(self.user.id))}"}
        self.other_headers = {
            "Authorization": f"Bearer {create_access_token(str(self.other_user.id))}"
        }

    async def asyncTearDown(self) -> None:
        await self.client.aclose()
        app.dependency_overrides.clear()
        await self.engine.dispose()
        self.temp_directory.cleanup()

    async def test_reports_and_csv_require_authentication(self) -> None:
        params = self._params()

        report_response = await self.client.get("/api/v1/reports", params=params)
        export_response = await self.client.get("/api/v1/reports/export.csv", params=params)

        self.assertEqual(report_response.status_code, 401)
        self.assertEqual(export_response.status_code, 401)

    async def test_report_returns_an_exact_empty_contract(self) -> None:
        response = await self.client.get(
            "/api/v1/reports",
            params=self._params(),
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "start_date": "2026-07-03",
                "end_date": "2026-07-04",
                "location_id": None,
                "locations": [],
                "totals": {
                    "currency_code": None,
                    "revenue_total_minor": 0,
                    "order_total": 0,
                    "average_ticket_minor": 0,
                },
                "channel_split": [],
                "revenue_trend": [],
                "location_performance": [],
            },
        )

    async def test_report_aggregates_range_channels_trend_and_location_growth(self) -> None:
        bandra_id, powai_id = await self._seed_performance_data()

        response = await self.client.get(
            "/api/v1/reports",
            params=self._params(),
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["location_id"], None)
        self.assertEqual(
            payload["locations"],
            [
                {"id": str(bandra_id), "name": "Bandra"},
                {"id": str(powai_id), "name": "Powai"},
            ],
        )
        self.assertEqual(
            payload["totals"],
            {
                "currency_code": "INR",
                "revenue_total_minor": 50000,
                "order_total": 40,
                "average_ticket_minor": 1250,
            },
        )
        self.assertEqual(
            payload["channel_split"],
            [
                {
                    "channel": "dine_in",
                    "label": "Dine-in",
                    "revenue_minor": 25000,
                    "order_total": 25,
                    "revenue_percent": 50.0,
                },
                {
                    "channel": "delivery",
                    "label": "Delivery",
                    "revenue_minor": 5000,
                    "order_total": 5,
                    "revenue_percent": 10.0,
                },
                {
                    "channel": "pickup",
                    "label": "Pickup",
                    "revenue_minor": 20000,
                    "order_total": 10,
                    "revenue_percent": 40.0,
                },
            ],
        )
        self.assertEqual(
            payload["revenue_trend"],
            [
                {"date": "2026-07-03", "revenue_minor": 40000, "order_total": 30},
                {"date": "2026-07-04", "revenue_minor": 10000, "order_total": 10},
            ],
        )
        self.assertEqual(
            payload["location_performance"],
            [
                {
                    "location_id": str(bandra_id),
                    "location_name": "Bandra",
                    "currency_code": "INR",
                    "revenue_minor": 30000,
                    "order_total": 30,
                    "average_ticket_minor": 1000,
                    "revenue_growth_percent": 200.0,
                },
                {
                    "location_id": str(powai_id),
                    "location_name": "Powai",
                    "currency_code": "INR",
                    "revenue_minor": 20000,
                    "order_total": 10,
                    "average_ticket_minor": 2000,
                    "revenue_growth_percent": 0.0,
                },
            ],
        )

    async def test_location_filter_scopes_every_report_section(self) -> None:
        _, powai_id = await self._seed_performance_data()

        response = await self.client.get(
            "/api/v1/reports",
            params={
                **self._params(),
                "location_id": str(powai_id),
            },
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["location_id"], str(powai_id))
        self.assertEqual(payload["totals"]["revenue_total_minor"], 20000)
        self.assertEqual(payload["totals"]["order_total"], 10)
        self.assertEqual([row["channel"] for row in payload["channel_split"]], ["pickup"])
        self.assertEqual(len(payload["location_performance"]), 1)
        self.assertEqual(payload["location_performance"][0]["location_name"], "Powai")

    async def test_report_and_csv_are_isolated_between_tenants(self) -> None:
        await self._seed_performance_data()
        async with self.session_factory() as session:
            other_location = ReportLocation(
                workspace_id=self.other_workspace.id,
                name="Other Tenant Location",
                currency_code="INR",
            )
            legacy_location = ReportLocation(
                workspace_id=None,
                name="Unowned Legacy Location",
                currency_code="INR",
            )
            session.add_all([other_location, legacy_location])
            await session.flush()
            session.add_all(
                [
                    ReportDailySales(
                        service_date=date(2026, 7, 3),
                        location_id=other_location.id,
                        channel="delivery",
                        net_sales_minor=777777,
                        order_count=7,
                    ),
                    ReportDailySales(
                        service_date=date(2026, 7, 3),
                        location_id=legacy_location.id,
                        channel="delivery",
                        net_sales_minor=888888,
                        order_count=8,
                    ),
                ]
            )
            await session.commit()

        owner_report = await self.client.get(
            "/api/v1/reports",
            params=self._params(),
            headers=self.headers,
        )
        outsider_report = await self.client.get(
            "/api/v1/reports",
            params=self._params(),
            headers=self.other_headers,
        )
        outsider_csv = await self.client.get(
            "/api/v1/reports/export.csv",
            params=self._params(),
            headers=self.other_headers,
        )

        self.assertEqual(owner_report.status_code, 200)
        self.assertEqual(owner_report.json()["totals"]["revenue_total_minor"], 50000)
        self.assertNotIn("Other Tenant Location", owner_report.text)
        self.assertNotIn("Unowned Legacy Location", owner_report.text)
        self.assertEqual(outsider_report.status_code, 404)
        self.assertEqual(outsider_csv.status_code, 404)

    async def test_report_rejects_unknown_location_and_mixed_currencies(self) -> None:
        unknown_response = await self.client.get(
            "/api/v1/reports",
            params={
                **self._params(),
                "location_id": str(uuid.uuid4()),
            },
            headers=self.headers,
        )
        self.assertEqual(unknown_response.status_code, 404)

        async with self.session_factory() as session:
            inr = ReportLocation(
                workspace_id=self.workspace.id,
                name="INR Location",
                currency_code="INR",
            )
            usd = ReportLocation(
                workspace_id=self.workspace.id,
                name="USD Location",
                currency_code="USD",
            )
            session.add_all([inr, usd])
            await session.flush()
            session.add_all(
                [
                    ReportDailySales(
                        service_date=date(2026, 7, 3),
                        location_id=inr.id,
                        channel="dine_in",
                        net_sales_minor=100,
                        order_count=1,
                    ),
                    ReportDailySales(
                        service_date=date(2026, 7, 3),
                        location_id=usd.id,
                        channel="delivery",
                        net_sales_minor=100,
                        order_count=1,
                    ),
                ]
            )
            await session.commit()

        mixed_response = await self.client.get(
            "/api/v1/reports",
            params=self._params(),
            headers=self.headers,
        )
        self.assertEqual(mixed_response.status_code, 409)

    async def test_report_and_csv_validate_date_range_bounds(self) -> None:
        invalid_ranges = [
            {"start_date": "2026-07-04", "end_date": "2026-07-03"},
            {"start_date": "2025-01-01", "end_date": "2026-01-02"},
        ]
        for path in ("/api/v1/reports", "/api/v1/reports/export.csv"):
            for params in invalid_ranges:
                with self.subTest(path=path, params=params):
                    response = await self.client.get(
                        path,
                        params={**params, "workspace_id": str(self.workspace.id)},
                        headers=self.headers,
                    )
                    self.assertEqual(response.status_code, 422)

    async def test_csv_has_safe_headers_fields_filename_and_spreadsheet_text(self) -> None:
        async with self.session_factory() as session:
            location = ReportLocation(
                workspace_id=self.workspace.id,
                name="=Unsafe Location",
                currency_code="inr",
            )
            session.add(location)
            await session.flush()
            session.add(
                ReportDailySales(
                    service_date=date(2026, 7, 3),
                    location_id=location.id,
                    channel="delivery",
                    net_sales_minor=12345,
                    order_count=3,
                )
            )
            await session.commit()

        response = await self.client.get(
            "/api/v1/reports/export.csv",
            params=self._params(),
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["content-type"], "text/csv; charset=utf-8")
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(
            response.headers["content-disposition"],
            'attachment; filename="reports_2026-07-03_to_2026-07-04.csv"',
        )
        rows = list(csv.reader(io.StringIO(response.text)))
        self.assertEqual(
            rows[0],
            [
                "service_date",
                "location",
                "channel",
                "currency_code",
                "net_sales_minor",
                "order_total",
                "average_ticket_minor",
            ],
        )
        self.assertEqual(
            rows[1],
            ["2026-07-03", "'=Unsafe Location", "Delivery", "INR", "12345", "3", "4115"],
        )
        self.assertNotIn("location_id", response.text)
        self.assertNotIn("reports-operator@example.com", response.text)

    async def test_csv_fails_closed_above_the_row_limit(self) -> None:
        await self._seed_performance_data()

        with patch("backend.services.report_service.CSV_MAX_ROWS", 1):
            response = await self.client.get(
                "/api/v1/reports/export.csv",
                params=self._params(),
                headers=self.headers,
            )

        self.assertEqual(response.status_code, 413)
        self.assertEqual(response.json()["detail"], "CSV export exceeds the 10000 row limit")

    async def _seed_performance_data(self) -> tuple[uuid.UUID, uuid.UUID]:
        async with self.session_factory() as session:
            bandra = ReportLocation(
                workspace_id=self.workspace.id,
                name="Bandra",
                currency_code="inr",
            )
            powai = ReportLocation(
                workspace_id=self.workspace.id,
                name="Powai",
                currency_code="INR",
            )
            session.add_all([bandra, powai])
            await session.flush()
            session.add_all(
                [
                    ReportDailySales(
                        service_date=date(2026, 7, 1),
                        location_id=bandra.id,
                        channel="dine_in",
                        net_sales_minor=10000,
                        order_count=10,
                    ),
                    ReportDailySales(
                        service_date=date(2026, 7, 1),
                        location_id=powai.id,
                        channel="pickup",
                        net_sales_minor=20000,
                        order_count=20,
                    ),
                    ReportDailySales(
                        service_date=date(2026, 7, 3),
                        location_id=bandra.id,
                        channel="dine_in",
                        net_sales_minor=15000,
                        order_count=15,
                    ),
                    ReportDailySales(
                        service_date=date(2026, 7, 3),
                        location_id=bandra.id,
                        channel="delivery",
                        net_sales_minor=5000,
                        order_count=5,
                    ),
                    ReportDailySales(
                        service_date=date(2026, 7, 4),
                        location_id=bandra.id,
                        channel="dine_in",
                        net_sales_minor=10000,
                        order_count=10,
                    ),
                    ReportDailySales(
                        service_date=date(2026, 7, 3),
                        location_id=powai.id,
                        channel="pickup",
                        net_sales_minor=20000,
                        order_count=10,
                    ),
                    ReportDailySales(
                        service_date=date(2026, 7, 5),
                        location_id=bandra.id,
                        channel="dine_in",
                        net_sales_minor=999999,
                        order_count=1,
                    ),
                ]
            )
            await session.commit()
            return bandra.id, powai.id

    def _params(self) -> dict[str, str]:
        return {
            "workspace_id": str(self.workspace.id),
            "start_date": "2026-07-03",
            "end_date": "2026-07-04",
        }


if __name__ == "__main__":
    unittest.main()
