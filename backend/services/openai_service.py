import asyncio
import json
import logging
import re
from dataclasses import dataclass
from decimal import Decimal
from typing import Any, Awaitable, Callable

from openai import (
    APIConnectionError,
    APIStatusError,
    APITimeoutError,
    OpenAI,
    RateLimitError,
)

from backend.api.schemas.audio_upload import AudioAnalysisResponse
from backend.utils.config import get_settings

logger = logging.getLogger(__name__)
_COST_QUANTUM = Decimal("0.00000001")


@dataclass(frozen=True)
class OpenAIResponseUsage:
    input_tokens: int
    cached_input_tokens: int
    output_tokens: int
    total_tokens: int
    model: str | None
    request_id: str | None
    estimated_cost_usd: Decimal
    request_ids: tuple[str, ...] = ()

    @classmethod
    def aggregate(
        cls,
        calls: list["OpenAIResponseUsage"],
    ) -> "OpenAIResponseUsage":
        if not calls:
            return cls(0, 0, 0, 0, None, None, Decimal("0"), ())
        request_ids = tuple(
            request_id
            for call in calls
            for request_id in (call.request_ids or ((call.request_id,) if call.request_id else ()))
        )
        return cls(
            input_tokens=sum(call.input_tokens for call in calls),
            cached_input_tokens=sum(call.cached_input_tokens for call in calls),
            output_tokens=sum(call.output_tokens for call in calls),
            total_tokens=sum(call.total_tokens for call in calls),
            model=calls[-1].model,
            request_id=calls[-1].request_id,
            estimated_cost_usd=sum(
                (call.estimated_cost_usd for call in calls),
                start=Decimal("0"),
            ).quantize(_COST_QUANTUM),
            request_ids=request_ids,
        )


@dataclass(frozen=True)
class OpenAIAnalysisResult:
    analysis: dict[str, Any]
    usage: OpenAIResponseUsage


@dataclass(frozen=True)
class _OpenAICallResult:
    parsed: Any
    usage: OpenAIResponseUsage


UsageCallback = Callable[[OpenAIResponseUsage], Awaitable[None]]


class OpenAIUnavailableError(RuntimeError):
    code = "openai_unavailable"
    retryable = True


class OpenAIRateLimitError(OpenAIUnavailableError):
    code = "ai_busy"


class OpenAIOperationsService:
    def __init__(self, *, client: OpenAI | None = None) -> None:
        settings = get_settings()
        api_key = settings.openai_api_key
        if client is None and (
            api_key is None or not api_key.get_secret_value().strip()
        ):
            raise OpenAIUnavailableError("OPENAI_API_KEY is not configured")
        self.client = client or OpenAI(
            api_key=api_key.get_secret_value(),
            timeout=settings.openai_timeout_seconds,
            max_retries=settings.openai_max_retries,
        )
        self.model = settings.openai_model
        self.chunk_chars = settings.openai_transcript_chunk_chars
        self.input_cost_per_million_usd = settings.openai_input_cost_per_million_usd
        self.cached_input_cost_per_million_usd = (
            settings.openai_cached_input_cost_per_million_usd
        )
        self.output_cost_per_million_usd = settings.openai_output_cost_per_million_usd

    async def analyze_transcript(self, transcript: str) -> dict[str, Any]:
        result = await self.analyze_transcript_with_usage(transcript)
        return result.analysis

    async def analyze_transcript_with_usage(
        self,
        transcript: str,
        *,
        on_usage: UsageCallback | None = None,
    ) -> OpenAIAnalysisResult:
        transcript = transcript.strip()
        if not transcript:
            raise ValueError("Transcript cannot be empty")
        chunks = self._chunk_transcript(transcript, self.chunk_chars)
        calls: list[OpenAIResponseUsage] = []

        async def record(call: _OpenAICallResult) -> AudioAnalysisResponse:
            calls.append(call.usage)
            if on_usage is not None:
                await on_usage(call.usage)
            if not isinstance(call.parsed, AudioAnalysisResponse):
                raise OpenAIUnavailableError("OpenAI returned an invalid analysis")
            return call.parsed

        if len(chunks) == 1:
            analysis = await record(
                await self._provider_call(self._analyze_one, chunks[0], None)
            )
        else:
            partials = []
            for index, chunk in enumerate(chunks, start=1):
                partials.append(
                    await record(
                        await self._provider_call(
                            self._analyze_one,
                            chunk,
                            f"Transcript section {index} of {len(chunks)}",
                        )
                    )
                )
            analysis = await record(
                await self._provider_call(self._synthesize, partials)
            )
        return OpenAIAnalysisResult(
            analysis=analysis.model_dump(),
            usage=OpenAIResponseUsage.aggregate(calls),
        )

    async def _provider_call(self, func: Callable[..., _OpenAICallResult], *args):
        try:
            return await asyncio.to_thread(func, *args)
        except RateLimitError as exc:
            self._log_api_error("rate_limit", exc)
            raise OpenAIRateLimitError("OpenAI is temporarily busy") from exc
        except (APITimeoutError, APIConnectionError) as exc:
            self._log_api_error("network", exc)
            raise OpenAIUnavailableError("OpenAI could not be reached") from exc
        except APIStatusError as exc:
            self._log_api_error("status", exc)
            raise OpenAIUnavailableError("OpenAI analysis failed") from exc
        except Exception as exc:
            logger.error(
                "OpenAI operations analysis failed exception_type=%s",
                type(exc).__name__,
            )
            raise OpenAIUnavailableError("OpenAI analysis failed") from exc

    def _analyze_one(
        self,
        transcript: str,
        section_label: str | None,
    ) -> _OpenAICallResult:
        scope = (
            f"This is {section_label}. Report only facts in this section."
            if section_label
            else "Analyze the complete transcript."
        )
        response = self.client.responses.parse(
            model=self.model,
            instructions=self._instructions(),
            input=f"{scope}\n\nRestaurant operational transcript:\n{transcript}",
            text_format=AudioAnalysisResponse,
            store=False,
        )
        return self._call_result(response)

    def _synthesize(
        self,
        partials: list[AudioAnalysisResponse],
    ) -> _OpenAICallResult:
        evidence = json.dumps(
            [item.model_dump() for item in partials],
            ensure_ascii=False,
        )
        response = self.client.responses.parse(
            model=self.model,
            instructions=(
                self._instructions()
                + " Combine the section reports into one report. Treat only their "
                "explicit statements as evidence and do not add facts. Use the highest "
                "supported operational severity and one concrete recommended action."
            ),
            input=f"Section reports derived from one transcript:\n{evidence}",
            text_format=AudioAnalysisResponse,
            store=False,
        )
        return self._call_result(response)

    def _call_result(self, response: Any) -> _OpenAICallResult:
        usage = getattr(response, "usage", None)
        input_tokens = self._integer_field(usage, "input_tokens")
        input_details = self._field(usage, "input_tokens_details")
        cached_input_tokens = self._integer_field(input_details, "cached_tokens")
        output_tokens = self._integer_field(usage, "output_tokens")
        total_tokens = self._integer_field(usage, "total_tokens")
        request_id = self._optional_string(
            getattr(response, "_request_id", None)
            or getattr(response, "request_id", None)
        )
        model = self._optional_string(getattr(response, "model", None))
        uncached_input_tokens = max(input_tokens - cached_input_tokens, 0)
        estimated_cost = (
            Decimal(uncached_input_tokens) * self.input_cost_per_million_usd
            + Decimal(cached_input_tokens) * self.cached_input_cost_per_million_usd
            + Decimal(output_tokens) * self.output_cost_per_million_usd
        ) / Decimal(1_000_000)
        response_usage = OpenAIResponseUsage(
            input_tokens=input_tokens,
            cached_input_tokens=cached_input_tokens,
            output_tokens=output_tokens,
            total_tokens=total_tokens,
            model=model,
            request_id=request_id,
            estimated_cost_usd=estimated_cost.quantize(_COST_QUANTUM),
            request_ids=(request_id,) if request_id else (),
        )
        return _OpenAICallResult(
            parsed=getattr(response, "output_parsed", None),
            usage=response_usage,
        )

    @staticmethod
    def _field(value: Any, name: str) -> Any:
        if isinstance(value, dict):
            return value.get(name)
        return getattr(value, name, None)

    @classmethod
    def _integer_field(cls, value: Any, name: str) -> int:
        field = cls._field(value, name)
        return field if isinstance(field, int) and field >= 0 else 0

    @staticmethod
    def _optional_string(value: Any) -> str | None:
        return value.strip()[:128] if isinstance(value, str) and value.strip() else None

    @staticmethod
    def _instructions() -> str:
        return (
            "Create a concise restaurant operations report from English transcript "
            "evidence. Use only facts explicitly provided. Do not infer names, quantities, "
            "causes, or events. If evidence is unclear, say so and recommend verification. "
            "Set category to inventory whenever the main issue is ingredient or food stock "
            "availability, including chicken stock, meat stock, ingredient stock, low stock, "
            "stock shortage, stock unavailable, stock running out, a need to reorder "
            "ingredients, or service affected because stock is missing. Inventory must take "
            "priority over operations for these incidents. Apply these inventory severity "
            "rules based on actual impact: low when stock is mentioned but there is no "
            "immediate service impact; medium when stock is low or unavailable and service "
            "may be affected but the situation is manageable; high only when service has "
            "stopped, there is a major stockout, or immediate business disruption is clearly "
            "happening. Repeating the word problem, or repeated wording alone, is not a high-"
            "severity signal. For an inventory shortage that may affect service or requires "
            "replenishment, set requires_attention to true. "
            "Classify severity as low, medium, or high. Assign high severity and set "
            "requires_attention to true when any of the following is present: repeated "
            "scolding after multiple warnings; direct aggressive commands; a threat or "
            "escalation to the head chef, supervisor, or management; abusive, insulting, "
            "or profane language; or a confrontation that may affect staff safety or "
            "restaurant operations. If multiple warning signs are present, prefer high "
            "over medium. Otherwise, assign medium for a meaningful operational or conduct "
            "issue that needs follow-up, and low for a routine or minor issue."
        )

    @staticmethod
    def _chunk_transcript(transcript: str, limit: int) -> list[str]:
        if len(transcript) <= limit:
            return [transcript]
        pieces = [piece.strip() for piece in re.split(r"(?<=[.!?])\s+|\n+", transcript)]
        chunks: list[str] = []
        current = ""
        for piece in pieces:
            if not piece:
                continue
            while len(piece) > limit:
                if current:
                    chunks.append(current)
                    current = ""
                chunks.append(piece[:limit])
                piece = piece[limit:]
            candidate = f"{current} {piece}".strip()
            if current and len(candidate) > limit:
                chunks.append(current)
                current = piece
            else:
                current = candidate
        if current:
            chunks.append(current)
        return chunks

    @staticmethod
    def _log_api_error(kind: str, exc: BaseException) -> None:
        status_code = getattr(exc, "status_code", None)
        request_id = getattr(exc, "request_id", None)
        logger.warning(
            "OpenAI operation failed kind=%s exception_type=%s status=%s request_id=%s",
            kind,
            type(exc).__name__,
            status_code,
            request_id,
        )
