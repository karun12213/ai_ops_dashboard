import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, EmailStr, Field, field_validator


class WorkspaceCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    location_name: str = Field(min_length=1, max_length=120)
    currency_code: str = Field(min_length=3, max_length=3)

    @field_validator("name", "location_name")
    @classmethod
    def normalize_name(cls, value: str) -> str:
        normalized = " ".join(value.split())
        if not normalized:
            raise ValueError("Name cannot be blank")
        return normalized

    @field_validator("currency_code")
    @classmethod
    def normalize_currency(cls, value: str) -> str:
        normalized = value.strip().upper()
        if len(normalized) != 3 or not normalized.isalpha():
            raise ValueError("Currency code must contain three letters")
        return normalized


class LocationCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    currency_code: str = Field(min_length=3, max_length=3)

    @field_validator("name")
    @classmethod
    def normalize_name(cls, value: str) -> str:
        normalized = " ".join(value.split())
        if not normalized:
            raise ValueError("Name cannot be blank")
        return normalized

    @field_validator("currency_code")
    @classmethod
    def normalize_currency(cls, value: str) -> str:
        normalized = value.strip().upper()
        if len(normalized) != 3 or not normalized.isalpha():
            raise ValueError("Currency code must contain three letters")
        return normalized


class WorkspaceMemberCreateRequest(BaseModel):
    email: EmailStr
    role: Literal["owner", "member"] = "member"


class WorkspaceLocationResponse(BaseModel):
    id: uuid.UUID
    name: str
    currency_code: str


class WorkspaceContextItemResponse(BaseModel):
    id: uuid.UUID
    name: str
    role: Literal["owner", "member"]
    locations: list[WorkspaceLocationResponse]


class WorkspaceContextResponse(BaseModel):
    workspaces: list[WorkspaceContextItemResponse]


class WorkspaceMemberResponse(BaseModel):
    user_id: uuid.UUID
    email: str
    full_name: str
    role: Literal["owner", "member"]
    created_at: datetime
