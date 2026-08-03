import uuid
from datetime import date, datetime, timezone
from typing import Annotated, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.dashboard import DashboardResponse
from backend.auth.dependencies import CurrentUser
from backend.database.session import get_db
from backend.services.dashboard_service import DashboardService
from backend.services.workspace_service import WorkspaceNotFoundError, WorkspaceService

router = APIRouter(prefix="/dashboard", tags=["dashboard"])


@router.get("", response_model=DashboardResponse, summary="Get a daily operational snapshot")
async def dashboard(
    current_user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_db)],
    workspace_id: Annotated[uuid.UUID, Query()],
    location_id: Annotated[uuid.UUID, Query()],
    service_date: Annotated[Optional[date], Query()] = None,
    activity_limit: Annotated[int, Query(ge=1, le=50)] = 10,
) -> DashboardResponse:
    """Return live stored Dashboard data, or an empty date-scoped payload."""
    try:
        await WorkspaceService(session).require_location(
            user_id=current_user.id,
            workspace_id=workspace_id,
            location_id=location_id,
        )
    except WorkspaceNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Location not found")
    requested_date = service_date or datetime.now(timezone.utc).date()
    return await DashboardService(session).get(
        requested_date,
        location_id=location_id,
        activity_limit=activity_limit,
    )
