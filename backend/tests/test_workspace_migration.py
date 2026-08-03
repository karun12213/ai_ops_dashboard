import tempfile
import unittest
from pathlib import Path

import sqlalchemy as sa
from alembic import command

from backend.tests.test_migrations import _alembic_config


class LegacyOperationalOwnershipMigrationTests(unittest.TestCase):
    def test_existing_operational_rows_remain_explicitly_unowned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "legacy-operational.db"
            async_url = f"sqlite+aiosqlite:///{database_path.as_posix()}"
            sync_url = f"sqlite:///{database_path.as_posix()}"
            config = _alembic_config(async_url)
            command.upgrade(config, "20260803_04")

            engine = sa.create_engine(sync_url)
            with engine.begin() as connection:
                connection.execute(
                    sa.text(
                        "INSERT INTO report_locations (id, name, currency_code) "
                        "VALUES (:id, :name, :currency)"
                    ),
                    {"id": "1" * 32, "name": "Legacy Location", "currency": "INR"},
                )
                connection.execute(
                    sa.text(
                        "INSERT INTO dashboard_daily_snapshots "
                        "(id, service_date, currency_code, net_sales_minor, "
                        "net_sales_change_percent, orders_served, orders_change_percent, "
                        "average_ticket_change_percent, average_table_turn_minutes, "
                        "table_turn_change_percent, service_open, occupied_tables, "
                        "total_tables, active_kitchen_tickets, kitchen_capacity, "
                        "pickup_orders, pickup_capacity, staff_on_shift, staff_scheduled) "
                        "VALUES (:id, '2026-08-03', 'INR', 100, NULL, 1, NULL, NULL, "
                        "NULL, NULL, 1, 1, 1, 0, 1, 0, 1, 1, 1)"
                    ),
                    {"id": "2" * 32},
                )
                connection.execute(
                    sa.text(
                        "INSERT INTO dashboard_activities "
                        "(id, service_date, occurred_at, title, actor, category) "
                        "VALUES (:id, '2026-08-03', '2026-08-03 10:00:00', "
                        "'Legacy activity', 'Operator', 'operations')"
                    ),
                    {"id": "3" * 32},
                )
            engine.dispose()

            command.upgrade(config, "head")

            engine = sa.create_engine(sync_url)
            with engine.connect() as connection:
                location_owner = connection.execute(
                    sa.text("SELECT workspace_id FROM report_locations WHERE id = :id"),
                    {"id": "1" * 32},
                ).scalar_one()
                snapshot_owner = connection.execute(
                    sa.text(
                        "SELECT location_id FROM dashboard_daily_snapshots WHERE id = :id"
                    ),
                    {"id": "2" * 32},
                ).scalar_one()
                activity_owner = connection.execute(
                    sa.text("SELECT location_id FROM dashboard_activities WHERE id = :id"),
                    {"id": "3" * 32},
                ).scalar_one()
                workspace_count = connection.execute(
                    sa.text("SELECT COUNT(*) FROM workspaces")
                ).scalar_one()
                membership_count = connection.execute(
                    sa.text("SELECT COUNT(*) FROM workspace_memberships")
                ).scalar_one()
            engine.dispose()

        self.assertIsNone(location_owner)
        self.assertIsNone(snapshot_owner)
        self.assertIsNone(activity_owner)
        self.assertEqual(workspace_count, 0)
        self.assertEqual(membership_count, 0)


if __name__ == "__main__":
    unittest.main()
