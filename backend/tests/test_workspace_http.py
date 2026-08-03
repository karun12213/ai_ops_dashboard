import tempfile
import unittest
import uuid
from pathlib import Path
from typing import AsyncIterator

from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from backend.auth.security import create_access_token, hash_password
from backend.database.base import Base
from backend.database.session import get_db
from backend.main import app
from backend.models.user import User
from backend.models.workspace import WorkspaceMembership


class WorkspaceHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        database_path = Path(self.temp_directory.name) / "workspace-http.db"
        self.engine = create_async_engine(f"sqlite+aiosqlite:///{database_path.as_posix()}")
        self.session_factory = async_sessionmaker(
            bind=self.engine,
            class_=AsyncSession,
            expire_on_commit=False,
        )
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

        async with self.session_factory() as session:
            self.owner = User(
                email="workspace-owner@example.com",
                full_name="Workspace Owner",
                hashed_password=hash_password("WorkspaceTestPassword123!"),
                is_active=True,
            )
            self.member = User(
                email="workspace-member@example.com",
                full_name="Workspace Member",
                hashed_password=hash_password("WorkspaceTestPassword123!"),
                is_active=True,
            )
            self.outsider = User(
                email="workspace-outsider@example.com",
                full_name="Workspace Outsider",
                hashed_password=hash_password("WorkspaceTestPassword123!"),
                is_active=True,
            )
            session.add_all([self.owner, self.member, self.outsider])
            await session.commit()
            for user in (self.owner, self.member, self.outsider):
                await session.refresh(user)

        async def override_database() -> AsyncIterator[AsyncSession]:
            async with self.session_factory() as session:
                yield session

        app.dependency_overrides[get_db] = override_database
        self.client = AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://testserver",
        )
        self.owner_headers = self._headers(self.owner)
        self.member_headers = self._headers(self.member)
        self.outsider_headers = self._headers(self.outsider)

    async def asyncTearDown(self) -> None:
        await self.client.aclose()
        app.dependency_overrides.clear()
        await self.engine.dispose()
        self.temp_directory.cleanup()

    async def test_workspace_routes_require_authentication(self) -> None:
        context = await self.client.get("/api/v1/workspaces/context")
        create = await self.client.post(
            "/api/v1/workspaces",
            json={"name": "Restaurant", "location_name": "Main", "currency_code": "INR"},
        )
        self.assertEqual(context.status_code, 401)
        self.assertEqual(create.status_code, 401)

    async def test_create_workspace_atomically_creates_owner_and_location(self) -> None:
        empty = await self.client.get(
            "/api/v1/workspaces/context",
            headers=self.owner_headers,
        )
        self.assertEqual(empty.json(), {"workspaces": []})

        created = await self._create_workspace()
        self.assertEqual(created.status_code, 201, created.text)
        payload = created.json()
        self.assertEqual(payload["name"], "My Restaurant")
        self.assertEqual(payload["role"], "owner")
        self.assertEqual(payload["locations"][0]["name"], "Main Floor")
        self.assertEqual(payload["locations"][0]["currency_code"], "INR")

        context = await self.client.get(
            "/api/v1/workspaces/context",
            headers=self.owner_headers,
        )
        self.assertEqual(context.status_code, 200)
        self.assertEqual(context.json()["workspaces"], [payload])

    async def test_owner_can_add_locations_and_members(self) -> None:
        workspace = (await self._create_workspace()).json()
        workspace_id = workspace["id"]

        location = await self.client.post(
            f"/api/v1/workspaces/{workspace_id}/locations",
            headers=self.owner_headers,
            json={"name": "Terrace", "currency_code": "inr"},
        )
        member = await self.client.post(
            f"/api/v1/workspaces/{workspace_id}/members",
            headers=self.owner_headers,
            json={"email": self.member.email, "role": "member"},
        )
        members = await self.client.get(
            f"/api/v1/workspaces/{workspace_id}/members",
            headers=self.owner_headers,
        )

        self.assertEqual(location.status_code, 201, location.text)
        self.assertEqual(location.json()["currency_code"], "INR")
        self.assertEqual(member.status_code, 201, member.text)
        self.assertEqual(member.json()["role"], "member")
        self.assertEqual(len(members.json()), 2)

        member_context = await self.client.get(
            "/api/v1/workspaces/context",
            headers=self.member_headers,
        )
        self.assertEqual(member_context.status_code, 200)
        self.assertEqual(member_context.json()["workspaces"][0]["role"], "member")
        self.assertEqual(
            [item["name"] for item in member_context.json()["workspaces"][0]["locations"]],
            ["Main Floor", "Terrace"],
        )

    async def test_nonowners_and_outsiders_receive_404_for_owner_operations(self) -> None:
        workspace_id = (await self._create_workspace()).json()["id"]
        await self.client.post(
            f"/api/v1/workspaces/{workspace_id}/members",
            headers=self.owner_headers,
            json={"email": self.member.email, "role": "member"},
        )

        for headers in (self.member_headers, self.outsider_headers):
            with self.subTest(headers=headers):
                location = await self.client.post(
                    f"/api/v1/workspaces/{workspace_id}/locations",
                    headers=headers,
                    json={"name": "Unauthorized", "currency_code": "INR"},
                )
                members = await self.client.get(
                    f"/api/v1/workspaces/{workspace_id}/members",
                    headers=headers,
                )
                add_member = await self.client.post(
                    f"/api/v1/workspaces/{workspace_id}/members",
                    headers=headers,
                    json={"email": self.outsider.email, "role": "member"},
                )
                self.assertEqual(location.status_code, 404)
                self.assertEqual(members.status_code, 404)
                self.assertEqual(add_member.status_code, 404)

    async def test_roles_are_database_backed_and_take_effect_without_new_tokens(self) -> None:
        workspace_id = (await self._create_workspace()).json()["id"]
        await self.client.post(
            f"/api/v1/workspaces/{workspace_id}/members",
            headers=self.owner_headers,
            json={"email": self.member.email, "role": "member"},
        )
        denied = await self.client.post(
            f"/api/v1/workspaces/{workspace_id}/locations",
            headers=self.member_headers,
            json={"name": "Garden", "currency_code": "INR"},
        )
        self.assertEqual(denied.status_code, 404)

        async with self.session_factory() as session:
            membership = await session.scalar(
                select(WorkspaceMembership).where(
                    WorkspaceMembership.workspace_id == uuid.UUID(workspace_id),
                    WorkspaceMembership.user_id == self.member.id,
                )
            )
            membership.role = "owner"
            await session.commit()

        allowed = await self.client.post(
            f"/api/v1/workspaces/{workspace_id}/locations",
            headers=self.member_headers,
            json={"name": "Garden", "currency_code": "INR"},
        )
        self.assertEqual(allowed.status_code, 201, allowed.text)

    async def test_duplicate_location_and_membership_return_conflict(self) -> None:
        workspace_id = (await self._create_workspace()).json()["id"]
        duplicate_location = await self.client.post(
            f"/api/v1/workspaces/{workspace_id}/locations",
            headers=self.owner_headers,
            json={"name": "Main Floor", "currency_code": "INR"},
        )
        first_member = await self.client.post(
            f"/api/v1/workspaces/{workspace_id}/members",
            headers=self.owner_headers,
            json={"email": self.member.email, "role": "member"},
        )
        duplicate_member = await self.client.post(
            f"/api/v1/workspaces/{workspace_id}/members",
            headers=self.owner_headers,
            json={"email": self.member.email, "role": "owner"},
        )
        self.assertEqual(duplicate_location.status_code, 409)
        self.assertEqual(first_member.status_code, 201)
        self.assertEqual(duplicate_member.status_code, 409)

    async def _create_workspace(self):
        return await self.client.post(
            "/api/v1/workspaces",
            headers=self.owner_headers,
            json={
                "name": "  My   Restaurant  ",
                "location_name": " Main   Floor ",
                "currency_code": "inr",
            },
        )

    @staticmethod
    def _headers(user: User) -> dict[str, str]:
        return {"Authorization": f"Bearer {create_access_token(str(user.id))}"}


if __name__ == "__main__":
    unittest.main()
