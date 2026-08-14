import unittest
from decimal import Decimal
from types import SimpleNamespace

from backend.api.schemas.audio_upload import AudioAnalysisResponse
from backend.services.openai_service import OpenAIOperationsService


def _analysis(summary: str) -> AudioAnalysisResponse:
    return AudioAnalysisResponse(
        summary=summary,
        category="operations",
        severity="medium",
        requires_attention=True,
        recommended_action="Verify and follow up.",
    )


def _response(
    *,
    summary: str,
    input_tokens: int,
    cached_tokens: int,
    output_tokens: int,
    request_id: str,
):
    return SimpleNamespace(
        output_parsed=_analysis(summary),
        usage=SimpleNamespace(
            input_tokens=input_tokens,
            input_tokens_details=SimpleNamespace(cached_tokens=cached_tokens),
            output_tokens=output_tokens,
            total_tokens=input_tokens + output_tokens,
        ),
        model="gpt-4o-2024-11-20",
        _request_id=request_id,
    )


class _Responses:
    def __init__(self, responses) -> None:
        self.responses = list(responses)
        self.calls: list[dict] = []

    def parse(self, **kwargs):
        self.calls.append(kwargs)
        return self.responses.pop(0)


class _Client:
    def __init__(self, responses) -> None:
        self.responses = _Responses(responses)


class OpenAIOperationsUsageTests(unittest.IsolatedAsyncioTestCase):
    async def test_single_response_captures_usage_model_request_and_cost(self) -> None:
        client = _Client(
            [
                _response(
                    summary="Single report",
                    input_tokens=100,
                    cached_tokens=20,
                    output_tokens=10,
                    request_id="req-single",
                )
            ]
        )
        service = OpenAIOperationsService(client=client)

        result = await service.analyze_transcript_with_usage("One transcript.")

        self.assertEqual(result.analysis["summary"], "Single report")
        self.assertEqual(result.usage.input_tokens, 100)
        self.assertEqual(result.usage.cached_input_tokens, 20)
        self.assertEqual(result.usage.output_tokens, 10)
        self.assertEqual(result.usage.total_tokens, 110)
        self.assertEqual(result.usage.model, "gpt-4o-2024-11-20")
        self.assertEqual(result.usage.request_id, "req-single")
        self.assertEqual(result.usage.request_ids, ("req-single",))
        self.assertEqual(result.usage.estimated_cost_usd, Decimal("0.00032500"))

    async def test_multi_chunk_usage_includes_each_chunk_and_final_synthesis(self) -> None:
        client = _Client(
            [
                _response(
                    summary="Part one",
                    input_tokens=100,
                    cached_tokens=20,
                    output_tokens=10,
                    request_id="req-part-1",
                ),
                _response(
                    summary="Part two",
                    input_tokens=200,
                    cached_tokens=50,
                    output_tokens=20,
                    request_id="req-part-2",
                ),
                _response(
                    summary="Combined report",
                    input_tokens=50,
                    cached_tokens=0,
                    output_tokens=5,
                    request_id="req-final",
                ),
            ]
        )
        service = OpenAIOperationsService(client=client)
        service.chunk_chars = 7
        recorded = []

        async def on_usage(usage) -> None:
            recorded.append(usage)

        result = await service.analyze_transcript_with_usage(
            "First. Second.",
            on_usage=on_usage,
        )

        self.assertEqual(len(client.responses.calls), 3)
        self.assertEqual(len(recorded), 3)
        self.assertEqual(result.analysis["summary"], "Combined report")
        self.assertEqual(result.usage.input_tokens, 350)
        self.assertEqual(result.usage.cached_input_tokens, 70)
        self.assertEqual(result.usage.output_tokens, 35)
        self.assertEqual(result.usage.total_tokens, 385)
        self.assertEqual(
            result.usage.request_ids,
            ("req-part-1", "req-part-2", "req-final"),
        )
        self.assertEqual(result.usage.request_id, "req-final")
        self.assertEqual(result.usage.estimated_cost_usd, Decimal("0.00113750"))


if __name__ == "__main__":
    unittest.main()
