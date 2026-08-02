from fastapi import APIRouter, HTTPException, status
from sqlalchemy import text

from backend.database.session import AsyncSessionLocal

router = APIRouter(tags=["system"])


@router.get("/health", summary="Readiness and dependency health")
async def health() -> dict:
    try:
        async with AsyncSessionLocal() as session:
            await session.execute(text("SELECT 1"))
    except Exception as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"status": "degraded", "database": "unavailable"},
        ) from error
    return {"status": "ok", "database": "connected"}
