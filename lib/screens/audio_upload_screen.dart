import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../widgets/page_header.dart';

class AudioUploadScreen extends StatefulWidget {
  const AudioUploadScreen({super.key});

  @override
  State<AudioUploadScreen> createState() => _AudioUploadScreenState();
}

class _AudioUploadScreenState extends State<AudioUploadScreen> {
  PlatformFile? _selectedFile;
  bool _isPicking = false;

  Future<void> _pickAudio() async {
    setState(() => _isPicking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'ogg'],
        allowMultiple: false,
      );
      if (result != null && mounted) {
        setState(() => _selectedFile = result.files.single);
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(
            title: 'Audio upload',
            description:
                'Prepare operational recordings for a future processing workflow.',
          ),
          const SizedBox(height: 28),
          LayoutBuilder(
            builder: (context, constraints) {
              final content = [
                _UploadCard(
                  file: _selectedFile,
                  isPicking: _isPicking,
                  onPick: _pickAudio,
                  onRemove: () => setState(() => _selectedFile = null),
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
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Audio processing and AI analysis are intentionally not connected in this foundation release.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UploadCard extends StatelessWidget {
  const _UploadCard({
    required this.file,
    required this.isPicking,
    required this.onPick,
    required this.onRemove,
  });

  final PlatformFile? file;
  final bool isPicking;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              onTap: isPicking ? null : onPick,
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
                    ? Column(
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
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
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
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'MP3, WAV, M4A, AAC or OGG',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 18),
                          OutlinedButton.icon(
                            onPressed: isPicking ? null : onPick,
                            icon: const Icon(Icons.folder_open_outlined),
                            label: const Text('Browse files'),
                          ),
                        ],
                      )
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.graphic_eq_rounded,
                              color: scheme.primary,
                              size: 54,
                            ),
                            const SizedBox(height: 18),
                            Text(
                              file!.name,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _formatBytes(file!.size),
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 18),
                            TextButton.icon(
                              onPressed: onRemove,
                              icon: const Icon(Icons.close_rounded),
                              label: const Text('Remove'),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: null,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Processing pipeline not configured'),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
        Icons.schedule_rounded,
        'Reasonable length',
        'Keep each operational recording under 60 minutes.',
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
