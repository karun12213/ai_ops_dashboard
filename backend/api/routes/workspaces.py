import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.workspace import (
    LocationCreateRequest,
    WorkspaceContextItemResponse,
    WorkspaceContextResponse,
    WorkspaceCreateRequest,
    WorkspaceLocationResponse,
    WorkspaceMemberCreateRequest,
    WorkspaceMemberResponse,
)
from backend.auth.dependencies import CurrentUser
from backend.database.session import get_db
from backend.services.workspace_service import (
    WorkspaceConflictError,
    WorkspaceMemberUserNotFoundError,
    WorkspaceNotFoundError,
    WorkspaceService,
)

router = APIRouter(prefix="/workspaces", tags=["workspaces"])


@router.get("/context", response_model=WorkspaceContextResponse)
async def workspace_context(
    current_user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_db)],
) -> WorkspaceContextResponse:
    return await WorkspaceService(session).context_for_user(current_user.id)


@router.post(
    "",
    response_model=WorkspaceContextItemResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_workspace(
    payload: WorkspaceCreateRequest,
    current_user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_db)],
) -> WorkspaceContextItemResponse:
    try:
        return await WorkspaceService(session).create_workspace(
            owner_id=current_user.id,
            name=payload.name,
            location_name=payload.location_name,
            currency_code=payload.currency_code,
        )
    except WorkspaceConflictError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))


@router.post(
    "/{workspace_id}/locations",
    response_model=WorkspaceLocationResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_location(
    workspace_id: uuid.UUID,
    payload: LocationCreateRequest,
    current_user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_db)],
) -> WorkspaceLocationResponse:
    try:
        return await WorkspaceService(session).create_location(
            requester_id=current_user.id,
            workspace_id=workspace_id,
            name=payload.name,
            currency_code=payload.currency_code,
        )
    except WorkspaceNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Workspace not found")
    except WorkspaceConflictError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))


@router.get("/{workspace_id}/members", response_model=list[WorkspaceMemberResponse])
async def list_workspace_members(
    workspace_id: uuid.UUID,
    current_user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_db)],
) -> list[WorkspaceMemberResponse]:
    try:
        return await WorkspaceService(session).list_members(
            requester_id=current_user.id,
            workspace_id=workspace_id,
        )
    except WorkspaceNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Workspace not found")


@router.post(
    "/{workspace_id}/members",
    response_model=WorkspaceMemberResponse,
    status_code=status.HTTP_201_CREATED,
)
async def add_workspace_member(
    workspace_id: uuid.UUID,
    payload: WorkspaceMemberCreateRequest,
    current_user: CurrentUser,
    session: Annotated[AsyncSession, Depends(get_db)],
) -> WorkspaceMemberResponse:
    try:
        return await WorkspaceService(session).add_member(
            requester_id=current_user.id,
            workspace_id=workspace_id,
            email=str(payload.email),
            role=payload.role,
        )
    except (WorkspaceNotFoundError, WorkspaceMemberUserNotFoundError):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Workspace not found")
    except WorkspaceConflictError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))
