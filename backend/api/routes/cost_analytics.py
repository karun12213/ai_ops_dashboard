import uuid
from datetime import date, datetime, timedelta, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.cost_analytics import CostAnalyticsResponse
from backend.auth.dependencies import CurrentUser
from backend.database.session import get_db
from backend.services.cost_analytics_service import CostAnalyticsService
from backend.services.workspace_service import WorkspaceNotFoundError, WorkspaceService

router = APIRouter(prefix="/cost-analytics", tags=["cost analytics"])
MAX_COST_ANALYTICS_RANGE_DAYS = 366


@router.get("", response_model=CostAnalyticsResponse, summary="Get audio cost analytics")
async def cost_analytics(
    current_user: CurrentUser,
    workspace_id: Annotated[uuid.UUID, Query()],
    start_date: Annotated[date | None, Query(description="Inclusive range start")] = None,
    end_date: Annotated[date | None, Query(description="Inclusive range end")] = None,
    location_id: Annotated[uuid.UUID | None, Query()] = None,
    recent_limit: Annotated[int, Query(ge=1, le=100)] = 25,
    session: AsyncSession = Depends(get_db),
) -> CostAnalyticsResponse:
    requested_end = end_date or datetime.now(timezone.utc).date()
    requested_start = start_date or requested_end - timedelta(days=29)
    _validate_range(requested_start, requested_end)
    try:
        workspace_service = WorkspaceService(session)
        if location_id is None:
            await workspace_service.require_membership(
                user_id=current_user.id,
                workspace_id=workspace_id,
            )
        else:
            await workspace_service.require_location(
                user_id=current_user.id,
                workspace_id=workspace_id,
                location_id=location_id,
            )
    except WorkspaceNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Location not found")

    return await CostAnalyticsService(session).get(
        start_date=requested_start,
        end_date=requested_end,
        workspace_id=workspace_id,
        location_id=location_id,
        recent_limit=recent_limit,
    )


def _validate_range(start_date: date, end_date: date) -> None:
    if end_date < start_date:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="end_date must be on or after start_date",
        )
    if (end_date - start_date).days + 1 > MAX_COST_ANALYTICS_RANGE_DAYS:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Date range cannot exceed {MAX_COST_ANALYTICS_RANGE_DAYS} days",
        )
