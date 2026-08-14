import uuid
from collections import defaultdict

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.workspace import (
    WorkspaceContextItemResponse,
    WorkspaceContextResponse,
    WorkspaceLocationResponse,
    WorkspaceMemberResponse,
)
from backend.models.report import ReportLocation
from backend.models.user import User
from backend.models.workspace import Workspace, WorkspaceMembership


class WorkspaceNotFoundError(LookupError):
    pass


class WorkspaceAccessDeniedError(PermissionError):
    pass


class WorkspaceMemberUserNotFoundError(LookupError):
    pass


class WorkspaceConflictError(ValueError):
    pass


class WorkspaceService:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def context_for_user(self, user_id: uuid.UUID) -> WorkspaceContextResponse:
        rows = (
            await self._session.execute(
                select(WorkspaceMembership, Workspace)
                .join(Workspace, Workspace.id == WorkspaceMembership.workspace_id)
                .where(WorkspaceMembership.user_id == user_id)
                .order_by(Workspace.name, Workspace.id)
            )
        ).all()
        workspace_ids = [workspace.id for _, workspace in rows]
        locations_by_workspace: dict[uuid.UUID, list[ReportLocation]] = defaultdict(list)
        if workspace_ids:
            locations = (
                await self._session.scalars(
                    select(ReportLocation)
                    .where(ReportLocation.workspace_id.in_(workspace_ids))
                    .order_by(ReportLocation.name, ReportLocation.id)
                )
            ).all()
            for location in locations:
                if location.workspace_id is not None:
                    locations_by_workspace[location.workspace_id].append(location)

        return WorkspaceContextResponse(
            workspaces=[
                WorkspaceContextItemResponse(
                    id=workspace.id,
                    name=workspace.name,
                    role=membership.role,
                    locations=[
                        self._location_response(location)
                        for location in locations_by_workspace[workspace.id]
                    ],
                )
                for membership, workspace in rows
            ]
        )

    async def create_workspace(
        self,
        *,
        owner_id: uuid.UUID,
        name: str,
        location_name: str,
        currency_code: str,
    ) -> WorkspaceContextItemResponse:
        workspace = Workspace(name=name)
        self._session.add(workspace)
        await self._session.flush()
        membership = WorkspaceMembership(
            workspace_id=workspace.id,
            user_id=owner_id,
            role="owner",
        )
        location = ReportLocation(
            workspace_id=workspace.id,
            name=location_name,
            currency_code=currency_code,
        )
        self._session.add_all([membership, location])
        try:
            await self._session.commit()
        except IntegrityError as exc:
            await self._session.rollback()
            raise WorkspaceConflictError("Workspace could not be created") from exc
        await self._session.refresh(workspace)
        await self._session.refresh(location)
        return WorkspaceContextItemResponse(
            id=workspace.id,
            name=workspace.name,
            role="owner",
            locations=[self._location_response(location)],
        )

    async def create_location(
        self,
        *,
        requester_id: uuid.UUID,
        workspace_id: uuid.UUID,
        name: str,
        currency_code: str,
    ) -> WorkspaceLocationResponse:
        await self.require_membership(
            user_id=requester_id,
            workspace_id=workspace_id,
            required_role="owner",
        )
        location = ReportLocation(
            workspace_id=workspace_id,
            name=name,
            currency_code=currency_code,
        )
        self._session.add(location)
        try:
            await self._session.commit()
        except IntegrityError as exc:
            await self._session.rollback()
            raise WorkspaceConflictError("A location with this name already exists") from exc
        await self._session.refresh(location)
        return self._location_response(location)

    async def add_member(
        self,
        *,
        requester_id: uuid.UUID,
        workspace_id: uuid.UUID,
        email: str,
        role: str,
    ) -> WorkspaceMemberResponse:
        await self.require_membership(
            user_id=requester_id,
            workspace_id=workspace_id,
            required_role="owner",
        )
        user = await self._session.scalar(
            select(User).where(User.email == email.strip().lower())
        )
        if user is None:
            raise WorkspaceMemberUserNotFoundError
        membership = WorkspaceMembership(
            workspace_id=workspace_id,
            user_id=user.id,
            role=role,
        )
        self._session.add(membership)
        try:
            await self._session.commit()
        except IntegrityError as exc:
            await self._session.rollback()
            raise WorkspaceConflictError("User is already a workspace member") from exc
        await self._session.refresh(membership)
        return self._member_response(membership, user)

    async def list_members(
        self,
        *,
        requester_id: uuid.UUID,
        workspace_id: uuid.UUID,
    ) -> list[WorkspaceMemberResponse]:
        await self.require_membership(
            user_id=requester_id,
            workspace_id=workspace_id,
            required_role="owner",
        )
        rows = (
            await self._session.execute(
                select(WorkspaceMembership, User)
                .join(User, User.id == WorkspaceMembership.user_id)
                .where(WorkspaceMembership.workspace_id == workspace_id)
                .order_by(User.full_name, User.email)
            )
        ).all()
        return [self._member_response(membership, user) for membership, user in rows]

    async def require_membership(
        self,
        *,
        user_id: uuid.UUID,
        workspace_id: uuid.UUID,
        required_role: str | None = None,
    ) -> WorkspaceMembership:
        membership = await self._session.scalar(
            select(WorkspaceMembership).where(
                WorkspaceMembership.workspace_id == workspace_id,
                WorkspaceMembership.user_id == user_id,
            )
        )
        if membership is None or (
            required_role is not None and membership.role != required_role
        ):
            raise WorkspaceNotFoundError
        return membership

    async def require_location(
        self,
        *,
        user_id: uuid.UUID,
        workspace_id: uuid.UUID,
        location_id: uuid.UUID,
    ) -> ReportLocation:
        location = await self._session.scalar(
            select(ReportLocation)
            .join(
                WorkspaceMembership,
                WorkspaceMembership.workspace_id == ReportLocation.workspace_id,
            )
            .where(
                ReportLocation.id == location_id,
                ReportLocation.workspace_id == workspace_id,
                WorkspaceMembership.user_id == user_id,
            )
        )
        if location is None:
            raise WorkspaceNotFoundError
        return location

    async def require_accessible_location(
        self,
        *,
        user_id: uuid.UUID,
        location_id: uuid.UUID,
    ) -> ReportLocation:
        """Distinguish a missing location from a real authorization denial."""
        location = await self._session.get(ReportLocation, location_id)
        if location is None:
            raise WorkspaceNotFoundError
        if location.workspace_id is None:
            raise WorkspaceAccessDeniedError
        membership = await self._session.scalar(
            select(WorkspaceMembership).where(
                WorkspaceMembership.workspace_id == location.workspace_id,
                WorkspaceMembership.user_id == user_id,
            )
        )
        if membership is None:
            raise WorkspaceAccessDeniedError
        return location

    @staticmethod
    def _location_response(location: ReportLocation) -> WorkspaceLocationResponse:
        return WorkspaceLocationResponse(
            id=location.id,
            name=location.name,
            currency_code=location.currency_code.upper(),
        )

    @staticmethod
    def _member_response(
        membership: WorkspaceMembership,
        user: User,
    ) -> WorkspaceMemberResponse:
        return WorkspaceMemberResponse(
            user_id=user.id,
            email=user.email,
            full_name=user.full_name,
            role=membership.role,
            created_at=membership.created_at,
        )
