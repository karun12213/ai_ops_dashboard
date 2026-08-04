import tempfile
import unittest
import uuid
from datetime import date, datetime, timezone
from pathlib import Path
from typing import AsyncIterator

from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.auth.security import create_access_token, hash_password
from backend.database.base import Base
from backend.database.session import get_db
from backend.main import app
from backend.models.dashboard import (
    DashboardActivity,
    DashboardDailySnapshot,
    DashboardHourlySales,
)
from backend.models.report import ReportLocation
from backend.models.user import User
from backend.models.workspace import Workspace, WorkspaceMembership


class DashboardHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        database_path = Path(self.temp_directory.name) / "dashboard-http.db"
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
                email="dashboard-operator@example.com",
                full_name="Dashboard Operator",
                hashed_password=hash_password("DashboardTestPassword123!"),
                is_active=True,
            )
            self.other_user = User(
                email="other-dashboard-operator@example.com",
                full_name="Other Dashboard Operator",
                hashed_password=hash_password("DashboardTestPassword123!"),
                is_active=True,
            )
            session.add_all([self.user, self.other_user])
            await session.flush()
            self.workspace = Workspace(name="Owner Workspace")
            self.other_workspace = Workspace(name="Other Workspace")
            session.add_all([self.workspace, self.other_workspace])
            await session.flush()
            self.location = ReportLocation(
                workspace_id=self.workspace.id,
                name="Main Floor",
                currency_code="INR",
            )
            self.other_location = ReportLocation(
                workspace_id=self.other_workspace.id,
                name="Other Floor",
                currency_code="INR",
            )
            session.add_all([self.location, self.other_location])
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
            for item in (
                self.user,
                self.other_user,
                self.workspace,
                self.other_workspace,
                self.location,
                self.other_location,
            ):
                await session.refresh(item)

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

    async def test_dashboard_requires_authentication(self) -> None:
        response = await self.client.get("/api/v1/dashboard", params=self._params())
        self.assertEqual(response.status_code, 401)

    async def test_dashboard_returns_a_location_scoped_empty_payload(self) -> None:
        async with self.session_factory() as session:
            session.add(
                DashboardActivity(
                    location_id=None,
                    service_date=date(2026, 8, 3),
                    occurred_at=datetime(2026, 8, 3, 9, tzinfo=timezone.utc),
                    title="Unowned legacy activity",
                    actor="Legacy",
                    category="operations",
                )
            )
            await session.commit()

        response = await self.client.get(
            "/api/v1/dashboard",
            params=self._params(),
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "service_date": "2026-08-03",
                "snapshot": None,
                "recent_activity": [],
            },
        )

    async def test_dashboard_returns_only_the_authorized_location(self) -> None:
        service_date = date(2026, 8, 3)
        updated_at = datetime(2026, 8, 3, 12, 30, tzinfo=timezone.utc)
        async with self.session_factory() as session:
            snapshot = self._snapshot(self.location.id, service_date, 10200, updated_at)
            other_snapshot = self._snapshot(
                self.other_location.id,
                service_date,
                999999,
                updated_at,
            )
            session.add_all([snapshot, other_snapshot])
            await session.flush()
            session.add_all(
                [
                    DashboardHourlySales(
                        snapshot_id=snapshot.id,
                        hour=18,
                        net_sales_minor=7200,
                    ),
                    DashboardHourlySales(
                        snapshot_id=snapshot.id,
                        hour=17,
                        net_sales_minor=3000,
                    ),
                    DashboardActivity(
                        location_id=self.location.id,
                        service_date=service_date,
                        occurred_at=datetime(2026, 8, 3, 17, 2, tzinfo=timezone.utc),
                        title="Dinner shift opened",
                        actor="Floor Manager",
                        category="service",
                    ),
                    DashboardActivity(
                        location_id=self.other_location.id,
                        service_date=service_date,
                        occurred_at=datetime(2026, 8, 3, 18, 0, tzinfo=timezone.utc),
                        title="Other tenant activity",
                        actor="Other Operator",
                        category="operations",
                    ),
                ]
            )
            await session.commit()

        response = await self.client.get(
            "/api/v1/dashboard",
            params={**self._params(), "activity_limit": 1},
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["snapshot"]["metrics"]["net_sales_minor"], 10200)
        self.assertEqual(
            payload["snapshot"]["hourly_sales"],
            [
                {"hour": 17, "net_sales_minor": 3000},
                {"hour": 18, "net_sales_minor": 7200},
            ],
        )
        self.assertEqual(payload["recent_activity"][0]["title"], "Dinner shift opened")
        self.assertNotIn("Other tenant activity", response.text)
        self.assertNotIn("999999", response.text)

    async def test_cross_tenant_workspace_and_location_access_returns_404(self) -> None:
        outsider_to_owner = await self.client.get(
            "/api/v1/dashboard",
            params=self._params(),
            headers=self.other_headers,
        )
        owner_to_outsider = await self.client.get(
            "/api/v1/dashboard",
            params={
                "workspace_id": str(self.other_workspace.id),
                "location_id": str(self.other_location.id),
                "service_date": "2026-08-03",
            },
            headers=self.headers,
        )
        mismatched_pair = await self.client.get(
            "/api/v1/dashboard",
            params={
                "workspace_id": str(self.workspace.id),
                "location_id": str(self.other_location.id),
                "service_date": "2026-08-03",
            },
            headers=self.headers,
        )
        self.assertEqual(outsider_to_owner.status_code, 404)
        self.assertEqual(owner_to_outsider.status_code, 404)
        self.assertEqual(mismatched_pair.status_code, 404)

    async def test_database_member_role_can_read_dashboard(self) -> None:
        async with self.session_factory() as session:
            session.add(
                WorkspaceMembership(
                    workspace_id=self.workspace.id,
                    user_id=self.other_user.id,
                    role="member",
                )
            )
            await session.commit()

        response = await self.client.get(
            "/api/v1/dashboard",
            params=self._params(),
            headers=self.other_headers,
        )

        self.assertEqual(response.status_code, 200)

    async def test_dashboard_validates_required_context_and_query_bounds(self) -> None:
        missing_context = await self.client.get(
            "/api/v1/dashboard",
            params={"service_date": "2026-08-03"},
            headers=self.headers,
        )
        invalid = await self.client.get(
            "/api/v1/dashboard",
            params={**self._params(), "service_date": "not-a-date", "activity_limit": 51},
            headers=self.headers,
        )
        self.assertEqual(missing_context.status_code, 422)
        self.assertEqual(invalid.status_code, 422)

    def _params(self) -> dict[str, str]:
        return {
            "workspace_id": str(self.workspace.id),
            "location_id": str(self.location.id),
            "service_date": "2026-08-03",
        }

    @staticmethod
    def _snapshot(
        location_id: uuid.UUID,
        service_date: date,
        net_sales_minor: int,
        updated_at: datetime,
    ) -> DashboardDailySnapshot:
        return DashboardDailySnapshot(
            location_id=location_id,
            service_date=service_date,
            currency_code="inr",
            net_sales_minor=net_sales_minor,
            net_sales_change_percent=12.4,
            orders_served=4,
            orders_change_percent=8.1,
            average_ticket_change_percent=3.7,
            average_table_turn_minutes=47,
            table_turn_change_percent=-5.2,
            service_open=True,
            occupied_tables=18,
            total_tables=24,
            active_kitchen_tickets=14,
            kitchen_capacity=20,
            pickup_orders=6,
            pickup_capacity=12,
            staff_on_shift=21,
            staff_scheduled=23,
            updated_at=updated_at,
        )


if __name__ == "__main__":
    unittest.main()
