import asyncio
import json
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine
from backend.utils.config import get_settings

async def main():
    engine = create_async_engine(get_settings().database_url)

    async with engine.connect() as connection:
        row = (
            await connection.execute(
                text("""
                SELECT
                    id,
                    audio_duration_seconds,
                    sarvam_model,
                    sarvam_estimated_cost_inr,
                    openai_input_tokens,
                    openai_cached_input_tokens,
                    openai_output_tokens,
                    openai_total_tokens,
                    openai_model,
                    openai_estimated_cost_usd,
                    total_estimated_cost
                FROM audio_uploads
                ORDER BY created_at DESC
                LIMIT 1
                """)
            )
        ).mappings().first()

        print(
            json.dumps(
                dict(row) if row else {"message": "audio_uploads is empty"},
                indent=2,
                default=str
            )
        )

    await engine.dispose()

asyncio.run(main())
