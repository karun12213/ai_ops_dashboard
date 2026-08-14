import csv
import io
import uuid
from datetime import date, datetime, time, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.api.schemas.report import (
    AudioOperationsReportResponse,
    ReportChannelResponse,
    ReportLocationPerformanceResponse,
    ReportLocationResponse,
    ReportResponse,
    ReportTotalsResponse,
    ReportTrendPointResponse,
)
from backend.models.audio_upload import AudioUpload
from backend.models.report import AudioOperationsReport, ReportDailySales, ReportLocation
from backend.models.workspace import Workspace
from backend.services.report_pdf_service import AudioReportPdfData

CSV_MAX_ROWS = 10_000

_CHANNEL_LABELS = {
    "dine_in": "Dine-in",
    "delivery": "Delivery",
    "pickup": "Pickup",
}
_CHANNEL_ORDER = {channel: index for index, channel in enumerate(_CHANNEL_LABELS)}


class UnknownReportLocationError(Exception):
    pass


class MixedReportCurrencyError(Exception):
    pass


class ReportCsvRowLimitError(Exception):
    pass


class ReportService:
    """Build range-scoped reports exclusively from stored sales aggregates."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get_audio_pdf_data(
        self,
        *,
        report_id: uuid.UUID,
    ) -> AudioReportPdfData | None:
        row = (
            await self._session.execute(
                select(AudioOperationsReport, AudioUpload, ReportLocation, Workspace)
                .join(AudioUpload, AudioUpload.id == AudioOperationsReport.upload_id)
                .join(ReportLocation, ReportLocation.id == AudioOperationsReport.location_id)
                .join(Workspace, Workspace.id == AudioOperationsReport.workspace_id)
                .where(AudioOperationsReport.id == report_id)
            )
        ).one_or_none()
        if row is None:
            return None
        report, upload, location, workspace = row
        return AudioReportPdfData(
            report_id=report.id,
            upload_id=report.upload_id,
            workspace_id=report.workspace_id,
            location_id=report.location_id,
            original_filename=upload.original_filename,
            workspace_name=workspace.name,
            location_name=location.name,
            source_language=upload.language_code or "unknown",
            detected_language=upload.detected_language_code,
            processed_at=report.processed_at,
            transcript=report.transcript,
            summary=report.summary,
            category=report.category,
            severity=report.severity,
            requires_attention=report.requires_attention,
            recommended_action=report.recommended_action,
            source=report.source,
        )

    async def get(
        self,
        *,
        start_date: date,
        end_date: date,
        workspace_id: uuid.UUID,
        location_id: uuid.UUID | None,
    ) -> ReportResponse:
        locations = list(
            (
                await self._session.scalars(
                    select(ReportLocation)
                    .where(ReportLocation.workspace_id == workspace_id)
                    .order_by(ReportLocation.name, ReportLocation.id)
                )
            ).all()
        )
        selected_location = self._selected_location(locations, location_id)
        allowed_location_ids = [location.id for location in locations]
        filters = self._sales_filters(
            start_date,
            end_date,
            allowed_location_ids,
            location_id,
        )

        revenue_total, order_total = (
            await self._session.execute(
                select(
                    func.coalesce(func.sum(ReportDailySales.net_sales_minor), 0),
                    func.coalesce(func.sum(ReportDailySales.order_count), 0),
                ).where(*filters)
            )
        ).one()
        revenue_total = int(revenue_total)
        order_total = int(order_total)

        currency_code = await self._currency_code(
            filters=filters,
            locations=locations,
            selected_location=selected_location,
        )

        channel_rows = (
            await self._session.execute(
                select(
                    ReportDailySales.channel,
                    func.sum(ReportDailySales.net_sales_minor),
                    func.sum(ReportDailySales.order_count),
                )
                .where(*filters)
                .group_by(ReportDailySales.channel)
            )
        ).all()
        channel_rows = sorted(
            channel_rows,
            key=lambda row: _CHANNEL_ORDER.get(row.channel, len(_CHANNEL_ORDER)),
        )

        trend_rows = (
            await self._session.execute(
                select(
                    ReportDailySales.service_date,
                    func.sum(ReportDailySales.net_sales_minor),
                    func.sum(ReportDailySales.order_count),
                )
                .where(*filters)
                .group_by(ReportDailySales.service_date)
                .order_by(ReportDailySales.service_date)
            )
        ).all()

        location_rows = (
            await self._session.execute(
                select(
                    ReportLocation.id,
                    ReportLocation.name,
                    ReportLocation.currency_code,
                    func.sum(ReportDailySales.net_sales_minor),
                    func.sum(ReportDailySales.order_count),
                )
                .join(ReportDailySales, ReportDailySales.location_id == ReportLocation.id)
                .where(*filters)
                .group_by(
                    ReportLocation.id,
                    ReportLocation.name,
                    ReportLocation.currency_code,
                )
                .order_by(func.sum(ReportDailySales.net_sales_minor).desc(), ReportLocation.name)
            )
        ).all()

        period_days = (end_date - start_date).days + 1
        previous_filters = self._sales_filters(
            start_date - timedelta(days=period_days),
            start_date - timedelta(days=1),
            allowed_location_ids,
            location_id,
        )
        previous_rows = (
            await self._session.execute(
                select(
                    ReportDailySales.location_id,
                    func.sum(ReportDailySales.net_sales_minor),
                )
                .where(*previous_filters)
                .group_by(ReportDailySales.location_id)
            )
        ).all()
        previous_revenue = {
            row.location_id: int(row[1]) for row in previous_rows
        }

        audio_filters = [
            AudioOperationsReport.workspace_id == workspace_id,
            AudioOperationsReport.processed_at
            >= datetime.combine(start_date, time.min, tzinfo=timezone.utc),
            AudioOperationsReport.processed_at
            < datetime.combine(
                end_date + timedelta(days=1), time.min, tzinfo=timezone.utc
            ),
        ]
        if location_id is not None:
            audio_filters.append(AudioOperationsReport.location_id == location_id)
        audio_rows = (
            await self._session.execute(
                select(AudioOperationsReport, ReportLocation.name, AudioUpload)
                .join(
                    ReportLocation,
                    ReportLocation.id == AudioOperationsReport.location_id,
                )
                .join(AudioUpload, AudioUpload.id == AudioOperationsReport.upload_id)
                .where(*audio_filters)
                .order_by(
                    AudioOperationsReport.processed_at.desc(),
                    AudioOperationsReport.id.desc(),
                )
            )
        ).all()

        return ReportResponse(
            start_date=start_date,
            end_date=end_date,
            location_id=location_id,
            locations=[
                ReportLocationResponse(id=location.id, name=location.name)
                for location in locations
            ],
            totals=ReportTotalsResponse(
                currency_code=currency_code,
                revenue_total_minor=revenue_total,
                order_total=order_total,
                average_ticket_minor=_average_ticket(revenue_total, order_total),
            ),
            channel_split=[
                ReportChannelResponse(
                    channel=row.channel,
                    label=_CHANNEL_LABELS[row.channel],
                    revenue_minor=int(row[1]),
                    order_total=int(row[2]),
                    revenue_percent=(
                        round(int(row[1]) * 100 / revenue_total, 2)
                        if revenue_total
                        else 0.0
                    ),
                )
                for row in channel_rows
            ],
            revenue_trend=[
                ReportTrendPointResponse(
                    date=row.service_date,
                    revenue_minor=int(row[1]),
                    order_total=int(row[2]),
                )
                for row in trend_rows
            ],
            location_performance=[
                ReportLocationPerformanceResponse(
                    location_id=row.id,
                    location_name=row.name,
                    currency_code=row.currency_code.upper(),
                    revenue_minor=int(row[3]),
                    order_total=int(row[4]),
                    average_ticket_minor=_average_ticket(int(row[3]), int(row[4])),
                    revenue_growth_percent=_growth_percent(
                        current=int(row[3]),
                        previous=previous_revenue.get(row.id, 0),
                    ),
                )
                for row in location_rows
            ],
            audio_reports=[
                AudioOperationsReportResponse(
                    id=audio_report.id,
                    upload_id=audio_report.upload_id,
                    workspace_id=audio_report.workspace_id,
                    location_id=audio_report.location_id,
                    location_name=location_name,
                    transcript=audio_report.transcript,
                    summary=audio_report.summary,
                    category=audio_report.category,
                    severity=audio_report.severity,
                    requires_attention=audio_report.requires_attention,
                    recommended_action=audio_report.recommended_action,
                    source=audio_report.source,
                    processed_at=audio_report.processed_at,
                    original_filename=upload.original_filename,
                    media_type=upload.media_type,
                    source_language=upload.language_code,
                    detected_language=upload.detected_language_code,
                    audio_duration_seconds=upload.audio_duration_seconds,
                    sarvam_model=upload.sarvam_model,
                    sarvam_estimated_cost_inr=upload.sarvam_estimated_cost_inr,
                    openai_model=upload.openai_model,
                    openai_input_tokens=upload.openai_input_tokens,
                    openai_cached_input_tokens=upload.openai_cached_input_tokens,
                    openai_output_tokens=upload.openai_output_tokens,
                    openai_total_tokens=upload.openai_total_tokens,
                    openai_estimated_cost_usd=upload.openai_estimated_cost_usd,
                    total_estimated_cost=upload.total_estimated_cost,
                )
                for audio_report, location_name, upload in audio_rows
            ],
        )

    async def export_csv(
        self,
        *,
        start_date: date,
        end_date: date,
        workspace_id: uuid.UUID,
        location_id: uuid.UUID | None,
    ) -> bytes:
        locations = list(
            (
                await self._session.scalars(
                    select(ReportLocation).where(
                        ReportLocation.workspace_id == workspace_id
                    )
                )
            ).all()
        )
        self._selected_location(locations, location_id)
        filters = self._sales_filters(
            start_date,
            end_date,
            [location.id for location in locations],
            location_id,
        )
        rows = (
            await self._session.execute(
                select(
                    ReportDailySales.service_date,
                    ReportLocation.name,
                    ReportDailySales.channel,
                    ReportLocation.currency_code,
                    ReportDailySales.net_sales_minor,
                    ReportDailySales.order_count,
                )
                .join(ReportLocation, ReportLocation.id == ReportDailySales.location_id)
                .where(*filters)
                .order_by(
                    ReportDailySales.service_date,
                    ReportLocation.name,
                    ReportDailySales.channel,
                )
                .limit(CSV_MAX_ROWS + 1)
            )
        ).all()
        if len(rows) > CSV_MAX_ROWS:
            raise ReportCsvRowLimitError

        output = io.StringIO(newline="")
        writer = csv.writer(output, lineterminator="\r\n")
        writer.writerow(
            [
                "service_date",
                "location",
                "channel",
                "currency_code",
                "net_sales_minor",
                "order_total",
                "average_ticket_minor",
            ]
        )
        for row in rows:
            revenue = int(row.net_sales_minor)
            orders = int(row.order_count)
            writer.writerow(
                [
                    row.service_date.isoformat(),
                    _spreadsheet_safe_text(row.name),
                    _CHANNEL_LABELS[row.channel],
                    row.currency_code.upper(),
                    revenue,
                    orders,
                    _average_ticket(revenue, orders),
                ]
            )
        return output.getvalue().encode("utf-8")

    @staticmethod
    def _sales_filters(
        start_date: date,
        end_date: date,
        allowed_location_ids: list[uuid.UUID],
        location_id: uuid.UUID | None,
    ) -> list:
        filters = [
            ReportDailySales.service_date >= start_date,
            ReportDailySales.service_date <= end_date,
            ReportDailySales.location_id.in_(allowed_location_ids),
        ]
        if location_id is not None:
            filters.append(ReportDailySales.location_id == location_id)
        return filters

    @staticmethod
    def _selected_location(
        locations: list[ReportLocation],
        location_id: uuid.UUID | None,
    ) -> ReportLocation | None:
        if location_id is None:
            return None
        selected = next(
            (location for location in locations if location.id == location_id),
            None,
        )
        if selected is None:
            raise UnknownReportLocationError
        return selected

    async def _currency_code(
        self,
        *,
        filters: list,
        locations: list[ReportLocation],
        selected_location: ReportLocation | None,
    ) -> str | None:
        currencies = {
            currency.upper()
            for currency in (
                await self._session.scalars(
                    select(ReportLocation.currency_code)
                    .join(
                        ReportDailySales,
                        ReportDailySales.location_id == ReportLocation.id,
                    )
                    .where(*filters)
                    .distinct()
                )
            ).all()
        }
        if len(currencies) > 1:
            raise MixedReportCurrencyError
        if currencies:
            return next(iter(currencies))
        if selected_location is not None:
            return selected_location.currency_code.upper()
        defined_currencies = {location.currency_code.upper() for location in locations}
        return next(iter(defined_currencies)) if len(defined_currencies) == 1 else None


def _average_ticket(revenue_minor: int, order_total: int) -> int:
    if order_total == 0:
        return 0
    return (revenue_minor + order_total // 2) // order_total


def _growth_percent(*, current: int, previous: int) -> float | None:
    if previous == 0:
        return None
    return round((current - previous) * 100 / previous, 2)


def _spreadsheet_safe_text(value: str) -> str:
    sanitized = value.replace("\x00", "")
    if sanitized.lstrip().startswith(("=", "+", "-", "@", "\t", "\r")):
        return f"'{sanitized}"
    return sanitized
