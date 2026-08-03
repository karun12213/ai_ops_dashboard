import tempfile
import unittest
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
from backend.models.user import User


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
            session.add(self.user)
            await session.commit()
            await session.refresh(self.user)

        async def override_database() -> AsyncIterator[AsyncSession]:
            async with self.session_factory() as session:
                yield session

        app.dependency_overrides[get_db] = override_database
        self.client = AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://testserver",
        )
        self.headers = {"Authorization": f"Bearer {create_access_token(str(self.user.id))}"}

    async def asyncTearDown(self) -> None:
        await self.client.aclose()
        app.dependency_overrides.clear()
        await self.engine.dispose()
        self.temp_directory.cleanup()

    async def test_dashboard_requires_authentication(self) -> None:
        response = await self.client.get("/api/v1/dashboard")

        self.assertEqual(response.status_code, 401)

    async def test_dashboard_returns_a_date_scoped_empty_payload(self) -> None:
        response = await self.client.get(
            "/api/v1/dashboard",
            params={"service_date": "2026-08-03"},
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

    async def test_dashboard_returns_live_metrics_in_display_order(self) -> None:
        service_date = date(2026, 8, 3)
        updated_at = datetime(2026, 8, 3, 12, 30, tzinfo=timezone.utc)
        async with self.session_factory() as session:
            snapshot = DashboardDailySnapshot(
                service_date=service_date,
                currency_code="inr",
                net_sales_minor=10200,
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
            session.add(snapshot)
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
                        service_date=service_date,
                        occurred_at=datetime(2026, 8, 3, 17, 2, tzinfo=timezone.utc),
                        title="Dinner shift opened",
                        actor="Floor Manager",
                        category="service",
                    ),
                    DashboardActivity(
                        service_date=service_date,
                        occurred_at=datetime(2026, 8, 3, 16, 28, tzinfo=timezone.utc),
                        title="Inventory count submitted",
                        actor="Kitchen Team",
                        category="inventory",
                    ),
                    DashboardActivity(
                        service_date=date(2026, 8, 2),
                        occurred_at=datetime(2026, 8, 2, 18, 0, tzinfo=timezone.utc),
                        title="Previous service closed",
                        actor="Operations",
                        category="operations",
                    ),
                ]
            )
            await session.commit()

        response = await self.client.get(
            "/api/v1/dashboard",
            params={"service_date": service_date.isoformat(), "activity_limit": 1},
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["service_date"], "2026-08-03")
        self.assertEqual(
            payload["snapshot"]["metrics"],
            {
                "currency_code": "INR",
                "net_sales_minor": 10200,
                "net_sales_change_percent": 12.4,
                "orders_served": 4,
                "orders_change_percent": 8.1,
                "average_ticket_minor": 2550,
                "average_ticket_change_percent": 3.7,
                "average_table_turn_minutes": 47,
                "table_turn_change_percent": -5.2,
            },
        )
        self.assertEqual(
            payload["snapshot"]["hourly_sales"],
            [
                {"hour": 17, "net_sales_minor": 3000},
                {"hour": 18, "net_sales_minor": 7200},
            ],
        )
        self.assertEqual(
            payload["snapshot"]["service_pulse"],
            {
                "occupied_tables": 18,
                "total_tables": 24,
                "active_kitchen_tickets": 14,
                "kitchen_capacity": 20,
                "pickup_orders": 6,
                "pickup_capacity": 12,
                "staff_on_shift": 21,
                "staff_scheduled": 23,
            },
        )
        self.assertTrue(payload["snapshot"]["service_open"])
        self.assertEqual(payload["snapshot"]["updated_at"], "2026-08-03T12:30:00")
        self.assertEqual(len(payload["recent_activity"]), 1)
        self.assertEqual(payload["recent_activity"][0]["title"], "Dinner shift opened")

    async def test_dashboard_validates_query_bounds(self) -> None:
        response = await self.client.get(
            "/api/v1/dashboard",
            params={"service_date": "not-a-date", "activity_limit": 51},
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 422)


if __name__ == "__main__":
    unittest.main()
