import html
import io
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    KeepTogether,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)


@dataclass(frozen=True)
class AudioReportPdfData:
    report_id: uuid.UUID
    upload_id: uuid.UUID
    workspace_id: uuid.UUID
    location_id: uuid.UUID
    original_filename: str
    workspace_name: str
    location_name: str
    source_language: str
    detected_language: str | None
    processed_at: datetime
    transcript: str
    summary: str
    category: str
    severity: str
    requires_attention: bool
    recommended_action: str
    source: str = "AI Audio Monitor"


class NumberedCanvasDocument(BaseDocTemplate):
    """A4 document whose page callback never exposes application internals."""


class AudioReportPdfService:
    title = "Restaurant Ops - AI Audio Report"

    def render(self, data: AudioReportPdfData) -> bytes:
        output = io.BytesIO()
        document = NumberedCanvasDocument(
            output,
            pagesize=A4,
            leftMargin=18 * mm,
            rightMargin=18 * mm,
            topMargin=18 * mm,
            bottomMargin=18 * mm,
            title=self.title,
            author="Restaurant Ops",
            subject="AI Audio Monitor report",
        )
        frame = Frame(
            document.leftMargin,
            document.bottomMargin,
            document.width,
            document.height,
            id="report-body",
        )
        document.addPageTemplates(
            [
                PageTemplate(
                    id="report",
                    frames=[frame],
                    onPage=self._draw_page,
                )
            ]
        )

        styles = getSampleStyleSheet()
        title_style = ParagraphStyle(
            "AudioReportTitle",
            parent=styles["Title"],
            fontName="Helvetica-Bold",
            fontSize=19,
            leading=24,
            alignment=TA_CENTER,
            textColor=colors.HexColor("#17324D"),
            spaceAfter=10,
        )
        subtitle_style = ParagraphStyle(
            "AudioReportSubtitle",
            parent=styles["Normal"],
            fontName="Helvetica",
            fontSize=9,
            leading=12,
            alignment=TA_CENTER,
            textColor=colors.HexColor("#5A6772"),
            spaceAfter=15,
        )
        section_style = ParagraphStyle(
            "AudioReportSection",
            parent=styles["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=13,
            leading=17,
            textColor=colors.HexColor("#17324D"),
            spaceBefore=10,
            spaceAfter=8,
        )
        body_style = ParagraphStyle(
            "AudioReportBody",
            parent=styles["BodyText"],
            fontName="Helvetica",
            fontSize=10,
            leading=15,
            textColor=colors.HexColor("#202B33"),
            spaceAfter=8,
            allowWidows=0,
            allowOrphans=0,
        )
        label_style = ParagraphStyle(
            "AudioReportLabel",
            parent=body_style,
            fontName="Helvetica-Bold",
            fontSize=9,
            leading=12,
            textColor=colors.HexColor("#41505D"),
        )

        processed = _utc_text(data.processed_at)
        metadata_rows = [
            ("Report ID", str(data.report_id)),
            ("Upload / Audio ID", str(data.upload_id)),
            ("Original filename", data.original_filename),
            ("Workspace", data.workspace_name),
            ("Location", data.location_name),
            ("Selected source language", data.source_language),
            ("Detected language", data.detected_language or "Not reported"),
            ("Processed", processed),
            ("Source", data.source),
        ]
        metadata_table = Table(
            [
                [
                    Paragraph(_escape(label), label_style),
                    Paragraph(_paragraph(value), body_style),
                ]
                for label, value in metadata_rows
            ],
            colWidths=[45 * mm, document.width - 45 * mm],
            repeatRows=0,
            hAlign="LEFT",
        )
        metadata_table.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#F3F7F9")),
                    ("BOX", (0, 0), (-1, -1), 0.6, colors.HexColor("#C7D3DB")),
                    ("INNERGRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#D9E2E7")),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 7),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 7),
                    ("TOPPADDING", (0, 0), (-1, -1), 5),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
                ]
            )
        )

        story = [
            Paragraph(self.title, title_style),
            Paragraph("Persisted report from the AI Audio Monitor", subtitle_style),
            metadata_table,
            Spacer(1, 8),
            Paragraph("SECTION 1 - English Transcript", section_style),
            Paragraph(_paragraph(data.transcript), body_style),
            Spacer(1, 4),
            Paragraph("SECTION 2 - AI Operations Report", section_style),
        ]
        for label, value in (
            ("Summary", data.summary),
            ("Category", data.category.title()),
            ("Severity", data.severity.title()),
            ("Requires Attention", "Yes" if data.requires_attention else "No"),
            ("Recommended Action", data.recommended_action),
        ):
            story.append(
                KeepTogether(
                    [
                        Paragraph(_escape(label), label_style),
                        Paragraph(_paragraph(value), body_style),
                        Spacer(1, 4),
                    ]
                )
            )
        document.build(story)
        return output.getvalue()

    @staticmethod
    def filename(data: AudioReportPdfData) -> str:
        stem = re.sub(r"[^A-Za-z0-9_-]+", "-", data.original_filename.rsplit(".", 1)[0])
        stem = stem.strip("-_")[:60] or "audio"
        return f"ai-audio-report-{stem}-{str(data.report_id)[:8]}.pdf"

    @staticmethod
    def _draw_page(canvas, document) -> None:
        canvas.saveState()
        canvas.setStrokeColor(colors.HexColor("#D9E2E7"))
        canvas.line(document.leftMargin, 14 * mm, A4[0] - document.rightMargin, 14 * mm)
        canvas.setFont("Helvetica", 8)
        canvas.setFillColor(colors.HexColor("#677681"))
        canvas.drawString(document.leftMargin, 9.5 * mm, "Restaurant Ops - AI Audio Monitor")
        canvas.drawRightString(
            A4[0] - document.rightMargin,
            9.5 * mm,
            f"Page {document.page}",
        )
        canvas.restoreState()


def _escape(value: object) -> str:
    return html.escape(str(value), quote=True)


def _paragraph(value: object) -> str:
    return _escape(value).replace("\r\n", "\n").replace("\r", "\n").replace("\n", "<br/>")


def _utc_text(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
