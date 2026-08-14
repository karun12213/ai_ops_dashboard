import uuid
from datetime import date

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.dashboard import (
    DashboardActivityResponse,
    DashboardHourlySalesResponse,
    DashboardMetricsResponse,
    DashboardResponse,
    DashboardServicePulseResponse,
    DashboardSnapshotResponse,
)
from backend.models.dashboard import (
    DashboardActivity,
    DashboardDailySnapshot,
    DashboardHourlySales,
)


class DashboardService:
    """Read coherent, date-scoped Dashboard data from stored aggregates."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(
        self,
        service_date: date,
        *,
        location_id: uuid.UUID,
        activity_limit: int,
    ) -> DashboardResponse:
        """Return the snapshot and newest activity for ``service_date``."""
        snapshot = await self._session.scalar(
            select(DashboardDailySnapshot).where(
                DashboardDailySnapshot.service_date == service_date,
                DashboardDailySnapshot.location_id == location_id,
            )
        )
        activities = list(
            (
                await self._session.scalars(
                    select(DashboardActivity)
                    .where(
                        DashboardActivity.service_date == service_date,
                        DashboardActivity.location_id == location_id,
                    )
                    .order_by(DashboardActivity.occurred_at.desc(), DashboardActivity.id.desc())
                    .limit(activity_limit)
                )
            ).all()
        )

        snapshot_response = None
        if snapshot is not None:
            hourly_sales = list(
                (
                    await self._session.scalars(
                        select(DashboardHourlySales)
                        .where(DashboardHourlySales.snapshot_id == snapshot.id)
                        .order_by(DashboardHourlySales.hour)
                    )
                ).all()
            )
            average_ticket_minor = (
                (snapshot.net_sales_minor + snapshot.orders_served // 2)
                // snapshot.orders_served
                if snapshot.orders_served
                else 0
            )
            snapshot_response = DashboardSnapshotResponse(
                updated_at=snapshot.updated_at,
                service_open=snapshot.service_open,
                metrics=DashboardMetricsResponse(
                    currency_code=snapshot.currency_code.upper(),
                    net_sales_minor=snapshot.net_sales_minor,
                    net_sales_change_percent=snapshot.net_sales_change_percent,
                    orders_served=snapshot.orders_served,
                    orders_change_percent=snapshot.orders_change_percent,
                    average_ticket_minor=average_ticket_minor,
                    average_ticket_change_percent=snapshot.average_ticket_change_percent,
                    average_table_turn_minutes=snapshot.average_table_turn_minutes,
                    table_turn_change_percent=snapshot.table_turn_change_percent,
                ),
                hourly_sales=[
                    DashboardHourlySalesResponse(
                        hour=point.hour,
                        net_sales_minor=point.net_sales_minor,
                    )
                    for point in hourly_sales
                ],
                service_pulse=DashboardServicePulseResponse(
                    occupied_tables=snapshot.occupied_tables,
                    total_tables=snapshot.total_tables,
                    active_kitchen_tickets=snapshot.active_kitchen_tickets,
                    kitchen_capacity=snapshot.kitchen_capacity,
                    pickup_orders=snapshot.pickup_orders,
                    pickup_capacity=snapshot.pickup_capacity,
                    staff_on_shift=snapshot.staff_on_shift,
                    staff_scheduled=snapshot.staff_scheduled,
                ),
            )

        return DashboardResponse(
            service_date=service_date,
            snapshot=snapshot_response,
            recent_activity=[
                DashboardActivityResponse(
                    id=activity.id,
                    occurred_at=activity.occurred_at,
                    title=activity.title,
                    actor=activity.actor,
                    category=activity.category,
                    severity=activity.severity,
                )
                for activity in activities
            ],
        )
