from datetime import date, datetime, timezone
from typing import Annotated, Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.dashboard import DashboardResponse
from backend.auth.dependencies import CurrentUser
from backend.database.session import get_db
from backend.services.dashboard_service import DashboardService

router = APIRouter(prefix="/dashboard", tags=["dashboard"])


@router.get("", response_model=DashboardResponse, summary="Get a daily operational snapshot")
async def dashboard(
    _: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_db)],
    service_date: Annotated[Optional[date], Query()] = None,
    activity_limit: Annotated[int, Query(ge=1, le=50)] = 10,
) -> DashboardResponse:
    """Return live stored Dashboard data, or an empty date-scoped payload."""
    requested_date = service_date or datetime.now(timezone.utc).date()
    return await DashboardService(session).get(
        requested_date,
        activity_limit=activity_limit,
    )
