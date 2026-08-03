import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio_upload.dart';
import '../providers/audio_upload_provider.dart';
import '../services/audio_file_picker.dart';
import '../widgets/page_header.dart';

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
                  'Securely store operational recordings for your account.',
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
                    state.transferPhase == AudioTransferPhase.failed,
                onRetry: () => _upload(context, notifier, retry: true),
                onDismiss: notifier.dismissOperationError,
              ),
            ],
            const SizedBox(height: 28),
            _UploadHistory(
              state: state,
              onRetry: notifier.refresh,
              onDelete: (upload) => _confirmDelete(context, notifier, upload),
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Audio upload completed.')));
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
}

class _UploadCard extends StatelessWidget {
  const _UploadCard({
    required this.state,
    required this.onPick,
    required this.onRemove,
    required this.onUpload,
  });

  final AudioUploadState state;
  final Future<void> Function() onPick;
  final VoidCallback onRemove;
  final Future<void> Function() onUpload;

  bool get _isBusy =>
      state.transferPhase == AudioTransferPhase.picking ||
      state.transferPhase == AudioTransferPhase.uploading ||
      state.transferPhase == AudioTransferPhase.processing;

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
              onTap: _isBusy ? null : onPick,
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
            if (state.transferPhase == AudioTransferPhase.uploading ||
                state.transferPhase == AudioTransferPhase.processing) ...[
              const SizedBox(height: 18),
              LinearProgressIndicator(
                key: const Key('audio-upload-progress'),
                value: state.transferPhase == AudioTransferPhase.uploading
                    ? state.uploadProgress
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                state.transferPhase == AudioTransferPhase.uploading
                    ? 'Uploading ${(state.uploadProgress * 100).round()}%'
                    : 'Finishing secure upload…',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('audio-upload-button'),
              onPressed: state.canUpload ? onUpload : null,
              icon:
                  state.transferPhase == AudioTransferPhase.uploading ||
                      state.transferPhase == AudioTransferPhase.processing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              label: Text(
                state.transferPhase == AudioTransferPhase.processing
                    ? 'Processing…'
                    : state.transferPhase == AudioTransferPhase.uploading
                    ? 'Uploading…'
                    : state.transferPhase == AudioTransferPhase.failed &&
                          file != null
                    ? 'Retry upload'
                    : 'Upload audio',
              ),
            ),
          ],
        ),
      ),
    );
  }
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
  });

  final String message;
  final bool canRetry;
  final Future<void> Function() onRetry;
  final VoidCallback onDismiss;

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

class _UploadHistory extends StatelessWidget {
  const _UploadHistory({
    required this.state,
    required this.onRetry,
    required this.onDelete,
  });

  final AudioUploadState state;
  final Future<void> Function() onRetry;
  final Future<void> Function(AudioUpload upload) onDelete;

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
  });

  final AudioUpload upload;
  final bool isDeleting;
  final Future<void> Function() onDelete;

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
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusChip(status: upload.status),
        const SizedBox(width: 8),
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
      AudioUploadStatus.ready => ('Ready', scheme.primary),
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
