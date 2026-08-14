import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/audio_upload.dart';
import '../providers/audio_upload_provider.dart';
import '../providers/report_provider.dart';
import '../routes/app_router.dart';
import '../services/audio_file_picker.dart';
import '../widgets/api_cost_report_card.dart';
import '../widgets/audio_bytes_player.dart';
import '../widgets/page_header.dart';

const _audioLanguages = <(String, String)>[
  ('unknown', 'Auto detect'),
  ('en-IN', 'English'),
  ('hi-IN', 'Hindi'),
  ('ne-IN', 'Nepali'),
  ('ta-IN', 'Tamil'),
  ('te-IN', 'Telugu'),
  ('bn-IN', 'Bengali'),
  ('kn-IN', 'Kannada'),
  ('ml-IN', 'Malayalam'),
  ('mr-IN', 'Marathi'),
  ('gu-IN', 'Gujarati'),
  ('pa-IN', 'Punjabi'),
  ('od-IN', 'Odia'),
  ('as-IN', 'Assamese'),
  ('ur-IN', 'Urdu'),
  ('kok-IN', 'Konkani'),
  ('ks-IN', 'Kashmiri'),
  ('sd-IN', 'Sindhi'),
  ('sa-IN', 'Sanskrit'),
  ('sat-IN', 'Santali'),
  ('mni-IN', 'Manipuri'),
  ('brx-IN', 'Bodo'),
  ('mai-IN', 'Maithili'),
  ('doi-IN', 'Dogri'),
];

class AudioUploadScreen extends ConsumerWidget {
  const AudioUploadScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(audioUploadProvider);
    final notifier = ref.read(audioUploadProvider.notifier);

    return RefreshIndicator(
      onRefresh: notifier.refresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageHeader(
              title: 'Audio upload',
              description:
                  'Translate operational recordings to English and create an AI report.',
              action: OutlinedButton.icon(
                key: const Key('audio-refresh-button'),
                onPressed: state.isLoadingHistory ? null : notifier.refresh,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Refresh history'),
              ),
            ),
            const SizedBox(height: 28),
            LayoutBuilder(
              builder: (context, constraints) {
                final content = [
                  _UploadCard(
                    state: state,
                    onPick: notifier.pickAudio,
                    onRemove: notifier.clearSelection,
                    onUpload: () => _upload(context, notifier),
                    onLanguageChanged: notifier.selectLanguage,
                  ),
                  const _UploadGuidance(),
                ];
                if (constraints.maxWidth < 840) {
                  return Column(
                    children: [
                      content[0],
                      const SizedBox(height: 16),
                      content[1],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: content[0]),
                    const SizedBox(width: 16),
                    Expanded(child: content[1]),
                  ],
                );
              },
            ),
            if (state.operationError != null) ...[
              const SizedBox(height: 16),
              _OperationError(
                message: state.operationError!,
                canRetry:
                    state.selectedFile != null &&
                    state.transferPhase == AudioTransferPhase.failed &&
                    state.existingUploadId == null,
                onRetry: () => _upload(context, notifier, retry: true),
                onDismiss: notifier.dismissOperationError,
                onViewExisting: state.existingReportId == null
                    ? null
                    : () => context.go(
                        Uri(
                          path: AppRoutes.reports,
                          queryParameters: {
                            'report_id': state.existingReportId!,
                          },
                        ).toString(),
                      ),
              ),
            ],
            if (state.lastProcessingResult case final result?) ...[
              const SizedBox(height: 20),
              _ProcessingResultCard(
                result: result,
                onViewDashboard: () => context.go(AppRoutes.dashboard),
                onViewReport: () => context.go(
                  Uri(
                    path: AppRoutes.reports,
                    queryParameters: {'report_id': result.reportId},
                  ).toString(),
                ),
                onProcessAnother: () async {
                  await notifier.processAnother();
                },
                onDownloadPdf: () =>
                    _downloadPdf(context, ref, result.reportId),
                loadAudio: () async {
                  final audio = await notifier.fetchStoredAudio(
                    result.upload.id,
                  );
                  return AudioBytesSource(
                    bytes: audio.bytes,
                    mediaType: audio.mediaType,
                  );
                },
              ),
            ],
            const SizedBox(height: 28),
            _UploadHistory(
              state: state,
              onRetry: notifier.refresh,
              onDelete: (upload) => _confirmDelete(context, notifier, upload),
              onRetryProcessing: notifier.retryStored,
              onViewReport: (reportId) => context.go(
                Uri(
                  path: AppRoutes.reports,
                  queryParameters: {'report_id': reportId},
                ).toString(),
              ),
              loadAudio: (uploadId) async {
                final audio = await notifier.fetchStoredAudio(uploadId);
                return AudioBytesSource(
                  bytes: audio.bytes,
                  mediaType: audio.mediaType,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _upload(
    BuildContext context,
    AudioUploadNotifier notifier, {
    bool retry = false,
  }) async {
    final uploaded = retry ? await notifier.retry() : await notifier.upload();
    if (!context.mounted || !uploaded) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Processing complete. Your report is ready.'),
      ),
    );
  }

  static Future<void> _confirmDelete(
    BuildContext context,
    AudioUploadNotifier notifier,
    AudioUpload upload,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete audio?'),
        content: Text(
          'Delete “${upload.originalFilename}”? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('audio-confirm-delete-button'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final deleted = await notifier.delete(upload.id);
    if (!context.mounted || !deleted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Audio upload deleted.')));
  }

  static Future<void> _downloadPdf(
    BuildContext context,
    WidgetRef ref,
    String reportId,
  ) async {
    try {
      final export = await ref
          .read(reportServiceProvider)
          .exportAudioPdf(reportId: reportId);
      await ref.read(pdfExportSaverProvider).save(export);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PDF report downloaded.')));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF download failed. Please try again.')),
      );
    }
  }
}

class _UploadCard extends StatelessWidget {
  const _UploadCard({
    required this.state,
    required this.onPick,
    required this.onRemove,
    required this.onUpload,
    required this.onLanguageChanged,
  });

  final AudioUploadState state;
  final Future<void> Function() onPick;
  final VoidCallback onRemove;
  final Future<void> Function() onUpload;
  final ValueChanged<String> onLanguageChanged;

  bool get _isBusy =>
      state.transferPhase == AudioTransferPhase.picking ||
      state.transferPhase == AudioTransferPhase.uploading ||
      state.transferPhase == AudioTransferPhase.transcribing ||
      state.transferPhase == AudioTransferPhase.analyzing ||
      state.transferPhase == AudioTransferPhase.savingReport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = state.selectedFile;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Recording',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            InkWell(
              key: const Key('audio-file-drop-zone'),
              onTap: _isBusy || file != null ? null : onPick,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                constraints: const BoxConstraints(minHeight: 270),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: scheme.primaryContainer.withValues(alpha: 0.13),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.45),
                    width: 1.5,
                  ),
                ),
                child: file == null
                    ? _EmptySelection(isPicking: _isBusy, onPick: onPick)
                    : _SelectedFile(
                        file: file,
                        canRemove: !_isBusy,
                        onRemove: onRemove,
                      ),
              ),
            ),
            const SizedBox(height: 18),
            DropdownButtonFormField<String>(
              key: const Key('audio-language-selector'),
              initialValue: state.languageCode,
              decoration: const InputDecoration(
                labelText: 'Source language',
                helperText:
                    'Choose Auto detect when the spoken language is unknown.',
              ),
              items: [
                for (final language in _audioLanguages)
                  DropdownMenuItem(
                    value: language.$1,
                    child: Text(language.$2),
                  ),
              ],
              onChanged: _isBusy
                  ? null
                  : (value) {
                      if (value != null) onLanguageChanged(value);
                    },
            ),
            if (_isBusy &&
                state.transferPhase != AudioTransferPhase.picking) ...[
              const SizedBox(height: 18),
              LinearProgressIndicator(
                key: const Key('audio-upload-progress'),
                value: state.transferPhase == AudioTransferPhase.uploading
                    ? state.uploadProgress
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                _processingMessage(state),
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('audio-upload-button'),
              onPressed: state.canUpload ? onUpload : null,
              icon: _isBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              label: Text(
                _isBusy
                    ? 'Processing audio…'
                    : state.transferPhase == AudioTransferPhase.failed &&
                          file != null
                    ? 'Retry upload'
                    : 'Process Audio',
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _processingMessage(AudioUploadState state) =>
      switch (state.transferPhase) {
        AudioTransferPhase.uploading =>
          'Uploading recording... ${(state.uploadProgress * 100).round()}%',
        AudioTransferPhase.transcribing => 'Converting speech to English...',
        AudioTransferPhase.analyzing => 'Generating AI operations report...',
        AudioTransferPhase.savingReport => 'Saving report...',
        _ => 'Preparing recording...',
      };
}

class _EmptySelection extends StatelessWidget {
  const _EmptySelection({required this.isPicking, required this.onPick});

  final bool isPicking;
  final Future<void> Function() onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 66,
          height: 66,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: isPicking
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  Icons.audio_file_outlined,
                  color: scheme.primary,
                  size: 32,
                ),
        ),
        const SizedBox(height: 18),
        Text(
          'Choose an audio file',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'MP3, WAV, M4A, AAC or OGG · 100 MB maximum',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          key: const Key('audio-pick-button'),
          onPressed: isPicking ? null : onPick,
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('Browse files'),
        ),
      ],
    );
  }
}

class _SelectedFile extends StatelessWidget {
  const _SelectedFile({
    required this.file,
    required this.canRemove,
    required this.onRemove,
  });

  final PickedAudioFile file;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.graphic_eq_rounded, color: scheme.primary, size: 54),
          const SizedBox(height: 18),
          Text(
            file.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            _formatBytes(file.sizeBytes),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          AudioBytesPlayer(
            key: Key('selected-audio-player-${file.name}'),
            sourceKey: '${file.name}:${file.sizeBytes}',
            load: () async => AudioBytesSource(
              bytes: await file.readBytes(),
              mediaType: file.effectiveMediaType,
            ),
          ),
          const SizedBox(height: 18),
          TextButton.icon(
            key: const Key('audio-remove-selection-button'),
            onPressed: canRemove ? onRemove : null,
            icon: const Icon(Icons.close_rounded),
            label: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

class _OperationError extends StatelessWidget {
  const _OperationError({
    required this.message,
    required this.canRetry,
    required this.onRetry,
    required this.onDismiss,
    this.onViewExisting,
  });

  final String message;
  final bool canRetry;
  final Future<void> Function() onRetry;
  final VoidCallback onDismiss;
  final VoidCallback? onViewExisting;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            if (canRetry)
              TextButton(
                key: const Key('audio-retry-button'),
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            if (onViewExisting != null)
              TextButton(
                key: const Key('audio-view-existing-report-button'),
                onPressed: onViewExisting,
                child: const Text('View Existing Report'),
              ),
            IconButton(
              tooltip: 'Dismiss error',
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessingResultCard extends StatelessWidget {
  const _ProcessingResultCard({
    required this.result,
    required this.onViewDashboard,
    required this.onViewReport,
    required this.onDownloadPdf,
    required this.onProcessAnother,
    required this.loadAudio,
  });

  final AudioUploadProcessingResult result;
  final VoidCallback onViewDashboard;
  final VoidCallback onViewReport;
  final Future<void> Function() onDownloadPdf;
  final Future<void> Function() onProcessAnother;
  final Future<AudioBytesSource> Function() loadAudio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final analysis = result.analysis;
    return Card(
      key: const Key('audio-processing-result'),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'PROCESSING COMPLETE',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Text(
              'Audio',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            AudioBytesPlayer(
              key: Key('completed-audio-player-${result.upload.id}'),
              sourceKey: result.upload.id,
              load: loadAudio,
            ),
            const Divider(height: 36),
            Text(
              'ENGLISH TRANSCRIPT',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SelectableText(result.transcript),
            const Divider(height: 36),
            Text(
              'AI OPERATIONS REPORT',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            _ResultField(label: 'Summary', value: analysis.summary),
            _ResultField(
              label: 'Category',
              value: _titleCase(analysis.category),
            ),
            _ResultField(
              label: 'Severity',
              value: _titleCase(analysis.severity.name),
            ),
            _ResultField(
              label: 'Requires attention',
              value: analysis.requiresAttention ? 'Yes' : 'No',
            ),
            _ResultField(
              label: 'Recommended action',
              value: analysis.recommendedAction,
            ),
            _ResultField(label: 'Location', value: result.locationName),
            _ResultField(
              label: 'Processed',
              value: _formatDateTime(result.processedAt),
            ),
            _ResultField(label: 'Source', value: result.source, isLast: true),
            const SizedBox(height: 22),
            ApiCostReportCard(
              key: const Key('audio-processing-api-cost-report'),
              cost: result.upload.apiCost,
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const Key('audio-download-pdf-button'),
                  onPressed: onDownloadPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Download PDF'),
                ),
                FilledButton.icon(
                  key: const Key('audio-view-dashboard-button'),
                  onPressed: onViewDashboard,
                  icon: const Icon(Icons.dashboard_outlined),
                  label: const Text('View Dashboard'),
                ),
                OutlinedButton.icon(
                  key: const Key('audio-view-report-button'),
                  onPressed: onViewReport,
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('View Full Report'),
                ),
                TextButton.icon(
                  key: const Key('audio-process-another-button'),
                  onPressed: () async {
                    await onProcessAnother();
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Process Another Audio'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultField extends StatelessWidget {
  const _ResultField({
    required this.label,
    required this.value,
    this.isLast = false,
  });

  final String label;
  final String value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _UploadHistory extends StatelessWidget {
  const _UploadHistory({
    required this.state,
    required this.onRetry,
    required this.onDelete,
    required this.onRetryProcessing,
    required this.onViewReport,
    required this.loadAudio,
  });

  final AudioUploadState state;
  final Future<void> Function() onRetry;
  final Future<void> Function(AudioUpload upload) onDelete;
  final Future<bool> Function(String uploadId) onRetryProcessing;
  final ValueChanged<String> onViewReport;
  final Future<AudioBytesSource> Function(String uploadId) loadAudio;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Upload history',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        if (state.isLoadingHistory)
          const _HistoryMessage(
            icon: Icons.cloud_sync_outlined,
            title: 'Loading upload history…',
            showProgress: true,
          )
        else if (state.historyError != null)
          _HistoryMessage(
            icon: Icons.cloud_off_outlined,
            title: 'Upload history is unavailable',
            description: 'Check your connection and try again.',
            action: FilledButton.icon(
              key: const Key('audio-history-retry-button'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          )
        else if (state.history.isEmpty)
          const _HistoryMessage(
            icon: Icons.library_music_outlined,
            title: 'No audio uploads yet',
            description: 'Your securely stored recordings will appear here.',
          )
        else
          for (final upload in state.history) ...[
            _HistoryItem(
              upload: upload,
              isDeleting: state.deletingIds.contains(upload.id),
              onDelete: () => onDelete(upload),
              onRetryProcessing: () => onRetryProcessing(upload.id),
              onViewReport: upload.reportId == null
                  ? null
                  : () => onViewReport(upload.reportId!),
              loadAudio: () => loadAudio(upload.id),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }
}

class _HistoryMessage extends StatelessWidget {
  const _HistoryMessage({
    required this.icon,
    required this.title,
    this.description,
    this.action,
    this.showProgress = false,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Center(
          child: Column(
            children: [
              if (showProgress)
                const SizedBox.square(
                  dimension: 34,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              else
                Icon(icon, size: 38, color: scheme.primary),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (description != null) ...[
                const SizedBox(height: 6),
                Text(
                  description!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({
    required this.upload,
    required this.isDeleting,
    required this.onDelete,
    required this.onRetryProcessing,
    required this.onViewReport,
    required this.loadAudio,
  });

  final AudioUpload upload;
  final bool isDeleting;
  final Future<void> Function() onDelete;
  final Future<bool> Function() onRetryProcessing;
  final VoidCallback? onViewReport;
  final Future<AudioBytesSource> Function() loadAudio;

  @override
  Widget build(BuildContext context) {
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          upload.originalFilename,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        Text(
          '${upload.extension.toUpperCase()} · ${_formatBytes(upload.sizeBytes)} · ${_formatDate(upload.createdAt)}',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          upload.status == AudioUploadStatus.ready
              ? 'Processed ${_formatDateTime(upload.processedAt ?? upload.updatedAt)} · '
                    '${upload.transcriptAvailable ? 'English transcript available' : 'Transcript unavailable'} · '
                    'Severity ${_titleCase(upload.severity?.name ?? 'unknown')}'
              : upload.status == AudioUploadStatus.failed
              ? '${upload.failureMessage ?? 'Processing failed.'}'
                    '${upload.failureStage == null ? '' : ' Stage: ${_titleCase(upload.failureStage!)}.'}'
              : 'Processing ${_titleCase(upload.processingStage.name)}',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _StatusChip(status: upload.status),
        if (upload.status == AudioUploadStatus.ready ||
            upload.status == AudioUploadStatus.failed)
          AudioBytesPlayer(
            key: Key('stored-audio-player-${upload.id}'),
            sourceKey: upload.id,
            load: loadAudio,
            compact: true,
          ),
        if (onViewReport != null)
          TextButton.icon(
            key: Key('audio-view-report-${upload.id}'),
            onPressed: onViewReport,
            icon: const Icon(Icons.description_outlined),
            label: const Text('View Report'),
          ),
        if (upload.status == AudioUploadStatus.failed && upload.retryable)
          TextButton.icon(
            key: Key('audio-retry-processing-${upload.id}'),
            onPressed: () async {
              await onRetryProcessing();
            },
            icon: const Icon(Icons.refresh_rounded),
            label: Text(
              upload.transcriptAvailable
                  ? 'Retry report generation'
                  : 'Retry processing',
            ),
          ),
        IconButton(
          key: Key('audio-delete-${upload.id}'),
          tooltip: 'Delete ${upload.originalFilename}',
          onPressed: isDeleting ? null : onDelete,
          icon: isDeleting
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_outline_rounded),
        ),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const _AudioIcon(),
                      const SizedBox(width: 12),
                      Expanded(child: details),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              );
            }
            return Row(
              children: [
                const _AudioIcon(),
                const SizedBox(width: 14),
                Expanded(child: details),
                const SizedBox(width: 12),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AudioIcon extends StatelessWidget {
  const _AudioIcon();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      backgroundColor: scheme.primaryContainer,
      child: Icon(Icons.graphic_eq_rounded, color: scheme.onPrimaryContainer),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final AudioUploadStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (status) {
      AudioUploadStatus.processing => ('Processing', scheme.tertiary),
      AudioUploadStatus.ready => ('Processed', scheme.primary),
      AudioUploadStatus.failed => ('Failed', scheme.error),
      AudioUploadStatus.quarantined => ('Quarantined', scheme.error),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _UploadGuidance extends StatelessWidget {
  const _UploadGuidance();

  @override
  Widget build(BuildContext context) {
    const items = [
      (
        Icons.mic_none_rounded,
        'Clear audio',
        'Use a close microphone and reduce background noise.',
      ),
      (
        Icons.folder_zip_outlined,
        'Supported files',
        'Choose MP3, WAV, M4A, AAC, or OGG up to 100 MB.',
      ),
      (
        Icons.shield_outlined,
        'Permission first',
        'Only upload recordings collected with appropriate consent.',
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Before you upload',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(radius: 20, child: Icon(item.$1, size: 20)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.$2,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.$3,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${_formatDate(local)} $hour:$minute $period';
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return '${value[0].toUpperCase()}${value.substring(1)}';
}
