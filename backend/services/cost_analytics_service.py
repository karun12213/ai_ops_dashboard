import uuid
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.cost_analytics import (
    CostAnalyticsBreakdownResponse,
    CostAnalyticsMetricsResponse,
    CostAnalyticsRecentUsageResponse,
    CostAnalyticsResponse,
)
from backend.models.audio_upload import AudioUpload
from backend.models.report import AudioOperationsReport, ReportLocation

_SEVERITY_LABELS = {
    "low": "Low",
    "medium": "Medium",
    "high": "High",
}
_CATEGORY_LABELS = {
    "staff": "Staff",
    "inventory": "Inventory",
    "operations": "Operations",
    "other": "Other",
}


@dataclass
class _Accumulator:
    total_uploads: int = 0
    costed_uploads: int = 0
    total_duration_seconds: Decimal = Decimal("0")
    costed_duration_seconds: Decimal = Decimal("0")
    sarvam_cost_inr: Decimal = Decimal("0")
    openai_cost_usd: Decimal = Decimal("0")

    def add(self, upload: AudioUpload) -> None:
        self.total_uploads += 1
        duration = _duration(upload.audio_duration_seconds)
        self.total_duration_seconds += duration
        if not _has_complete_cost(upload):
            return
        self.costed_uploads += 1
        self.costed_duration_seconds += duration
        self.sarvam_cost_inr += upload.sarvam_estimated_cost_inr or Decimal("0")
        self.openai_cost_usd += upload.openai_estimated_cost_usd or Decimal("0")

    @property
    def missing_uploads(self) -> int:
        return self.total_uploads - self.costed_uploads


class CostAnalyticsService:
    """Aggregate existing per-upload usage without mixing INR and USD."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(
        self,
        *,
        start_date: date,
        end_date: date,
        workspace_id: uuid.UUID,
        location_id: uuid.UUID | None,
        recent_limit: int,
    ) -> CostAnalyticsResponse:
        filters = [
            AudioOperationsReport.workspace_id == workspace_id,
            AudioUpload.status == "ready",
            AudioOperationsReport.processed_at
            >= datetime.combine(start_date, time.min, tzinfo=timezone.utc),
            AudioOperationsReport.processed_at
            < datetime.combine(
                end_date + timedelta(days=1), time.min, tzinfo=timezone.utc
            ),
        ]
        if location_id is not None:
            filters.append(AudioOperationsReport.location_id == location_id)

        rows = (
            await self._session.execute(
                select(AudioUpload, AudioOperationsReport, ReportLocation)
                .join(
                    AudioOperationsReport,
                    AudioOperationsReport.upload_id == AudioUpload.id,
                )
                .join(
                    ReportLocation,
                    ReportLocation.id == AudioOperationsReport.location_id,
                )
                .where(*filters)
                .order_by(
                    AudioOperationsReport.processed_at.desc(),
                    AudioOperationsReport.id.desc(),
                )
            )
        ).all()

        totals = _Accumulator()
        locations: dict[str, tuple[str, _Accumulator]] = {}
        severities = {
            key: _Accumulator() for key in _SEVERITY_LABELS
        }
        categories = {
            key: _Accumulator() for key in _CATEGORY_LABELS
        }

        for upload, report, location in rows:
            totals.add(upload)
            location_key = str(location.id)
            location_bucket = locations.setdefault(
                location_key, (location.name, _Accumulator())
            )[1]
            location_bucket.add(upload)
            severities[_severity_bucket(report.severity)].add(upload)
            categories[_category_bucket(report.category)].add(upload)

        return CostAnalyticsResponse(
            start_date=start_date,
            end_date=end_date,
            location_id=location_id,
            metrics=_metrics(totals),
            by_location=[
                _breakdown(key, label, bucket)
                for key, (label, bucket) in sorted(
                    locations.items(), key=lambda item: item[1][0].lower()
                )
            ],
            by_severity=[
                _breakdown(key, label, severities[key])
                for key, label in _SEVERITY_LABELS.items()
            ],
            by_category=[
                _breakdown(key, label, categories[key])
                for key, label in _CATEGORY_LABELS.items()
            ],
            recent_usage=[
                CostAnalyticsRecentUsageResponse(
                    upload_id=upload.id,
                    processed_at=report.processed_at,
                    original_filename=upload.original_filename,
                    audio_duration_seconds=upload.audio_duration_seconds,
                    category=report.category,
                    severity=report.severity,
                    sarvam_estimated_cost_inr=upload.sarvam_estimated_cost_inr,
                    openai_estimated_cost_usd=upload.openai_estimated_cost_usd,
                    openai_total_tokens=upload.openai_total_tokens,
                )
                for upload, report, _ in rows[:recent_limit]
            ],
        )


def _metrics(bucket: _Accumulator) -> CostAnalyticsMetricsResponse:
    has_cost = bucket.costed_uploads > 0
    has_costed_duration = bucket.costed_duration_seconds > 0
    costed_uploads = Decimal(bucket.costed_uploads)
    duration_minutes = bucket.costed_duration_seconds / Decimal("60")
    duration_hours = bucket.costed_duration_seconds / Decimal("3600")
    return CostAnalyticsMetricsResponse(
        total_audio_uploads=bucket.total_uploads,
        costed_audio_uploads=bucket.costed_uploads,
        missing_cost_data_uploads=bucket.missing_uploads,
        total_recorded_audio_duration_seconds=float(bucket.total_duration_seconds),
        costed_audio_duration_seconds=float(bucket.costed_duration_seconds),
        total_sarvam_cost_inr=bucket.sarvam_cost_inr if has_cost else None,
        total_openai_cost_usd=bucket.openai_cost_usd if has_cost else None,
        average_sarvam_cost_per_upload_inr=(
            bucket.sarvam_cost_inr / costed_uploads if has_cost else None
        ),
        average_openai_cost_per_upload_usd=(
            bucket.openai_cost_usd / costed_uploads if has_cost else None
        ),
        average_sarvam_cost_per_recorded_minute_inr=(
            bucket.sarvam_cost_inr / duration_minutes
            if has_costed_duration
            else None
        ),
        average_openai_cost_per_recorded_minute_usd=(
            bucket.openai_cost_usd / duration_minutes
            if has_costed_duration
            else None
        ),
        estimated_sarvam_cost_per_recorded_hour_inr=(
            bucket.sarvam_cost_inr / duration_hours if has_costed_duration else None
        ),
        estimated_openai_cost_per_recorded_hour_usd=(
            bucket.openai_cost_usd / duration_hours if has_costed_duration else None
        ),
    )


def _breakdown(
    key: str, label: str, bucket: _Accumulator
) -> CostAnalyticsBreakdownResponse:
    has_cost = bucket.costed_uploads > 0
    return CostAnalyticsBreakdownResponse(
        key=key,
        label=label,
        total_audio_uploads=bucket.total_uploads,
        costed_audio_uploads=bucket.costed_uploads,
        missing_cost_data_uploads=bucket.missing_uploads,
        recorded_audio_duration_seconds=float(bucket.total_duration_seconds),
        sarvam_cost_inr=bucket.sarvam_cost_inr if has_cost else None,
        openai_cost_usd=bucket.openai_cost_usd if has_cost else None,
    )


def _has_complete_cost(upload: AudioUpload) -> bool:
    return (
        upload.sarvam_estimated_cost_inr is not None
        and upload.openai_estimated_cost_usd is not None
    )


def _duration(value: float | None) -> Decimal:
    if value is None or value <= 0:
        return Decimal("0")
    return Decimal(str(value))


def _severity_bucket(value: str) -> str:
    normalized = value.strip().lower()
    return normalized if normalized in {"low", "medium"} else "high"


def _category_bucket(value: str) -> str:
    normalized = value.strip().lower()
    return normalized if normalized in {"staff", "inventory", "operations"} else "other"
