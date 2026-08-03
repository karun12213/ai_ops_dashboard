import uuid
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.report import ReportResponse
from backend.auth.dependencies import CurrentUser
from backend.database.session import get_db
from backend.services.report_service import (
    MixedReportCurrencyError,
    ReportCsvRowLimitError,
    ReportService,
    UnknownReportLocationError,
)
from backend.services.workspace_service import WorkspaceNotFoundError, WorkspaceService

router = APIRouter(prefix="/reports", tags=["reports"])

MAX_REPORT_RANGE_DAYS = 366


@router.get("", response_model=ReportResponse, summary="Get a sales performance report")
async def report(
    current_user: CurrentUser,
    start_date: Annotated[date, Query(description="Inclusive range start")],
    end_date: Annotated[date, Query(description="Inclusive range end")],
    workspace_id: Annotated[uuid.UUID, Query()],
    location_id: Annotated[uuid.UUID | None, Query()] = None,
    session: AsyncSession = Depends(get_db),
) -> ReportResponse:
    _validate_range(start_date, end_date)
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
        return await ReportService(session).get(
            start_date=start_date,
            end_date=end_date,
            workspace_id=workspace_id,
            location_id=location_id,
        )
    except (UnknownReportLocationError, WorkspaceNotFoundError):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Location not found")
    except MixedReportCurrencyError:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="The selected report contains multiple currencies",
        )


@router.get("/export.csv", summary="Export sales performance rows as CSV")
async def export_report_csv(
    current_user: CurrentUser,
    start_date: Annotated[date, Query(description="Inclusive range start")],
    end_date: Annotated[date, Query(description="Inclusive range end")],
    workspace_id: Annotated[uuid.UUID, Query()],
    location_id: Annotated[uuid.UUID | None, Query()] = None,
    session: AsyncSession = Depends(get_db),
) -> Response:
    _validate_range(start_date, end_date)
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
        content = await ReportService(session).export_csv(
            start_date=start_date,
            end_date=end_date,
            workspace_id=workspace_id,
            location_id=location_id,
        )
    except (UnknownReportLocationError, WorkspaceNotFoundError):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Location not found")
    except ReportCsvRowLimitError:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail="CSV export exceeds the 10000 row limit",
        )

    filename = f"reports_{start_date.isoformat()}_to_{end_date.isoformat()}.csv"
    return Response(
        content=content,
        media_type="text/csv",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Cache-Control": "no-store",
        },
    )


def _validate_range(start_date: date, end_date: date) -> None:
    if end_date < start_date:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="end_date must be on or after start_date",
        )
    if (end_date - start_date).days + 1 > MAX_REPORT_RANGE_DAYS:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Date range cannot exceed {MAX_REPORT_RANGE_DAYS} days",
        )
