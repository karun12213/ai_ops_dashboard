import 'dart:async';
import 'dart:typed_data';

import 'package:ai_ops_dashboard/models/audio_api_cost.dart';
import 'package:ai_ops_dashboard/models/audio_upload.dart';
import 'package:ai_ops_dashboard/models/workspace_context.dart';
import 'package:ai_ops_dashboard/providers/audio_upload_provider.dart';
import 'package:ai_ops_dashboard/providers/workspace_provider.dart';
import 'package:ai_ops_dashboard/screens/audio_upload_screen.dart';
import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/audio_file_picker.dart';
import 'package:ai_ops_dashboard/services/audio_upload_service.dart';
import 'package:ai_ops_dashboard/services/workspace_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows loading then a genuine empty history state', (
    tester,
  ) async {
    final completion = Completer<List<AudioUpload>>();
    final repository = _FakeRepository(onFetch: () => completion.future);
    await _pumpAudio(tester, repository: repository);

    expect(find.text('Loading upload history…'), findsOneWidget);

    completion.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('No audio uploads yet'), findsOneWidget);
    expect(find.text('shift-note.mp3'), findsNothing);
  });

  testWidgets('shows a safe history error and retries', (tester) async {
    var requests = 0;
    final repository = _FakeRepository(
      onFetch: () async {
        requests += 1;
        if (requests == 1) throw StateError('sensitive database detail');
        return [];
      },
    );
    await _pumpAudio(tester, repository: repository);
    await tester.pumpAndSettle();

    expect(find.text('Upload history is unavailable'), findsOneWidget);
    expect(find.text('sensitive database detail'), findsNothing);

    await tester.tap(find.byKey(const Key('audio-history-retry-button')));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('No audio uploads yet'), findsOneWidget);
  });

  testWidgets('refresh button reloads upload history', (tester) async {
    var requests = 0;
    final repository = _FakeRepository(
      onFetch: () async {
        requests += 1;
        return [];
      },
    );
    await _pumpAudio(tester, repository: repository);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('audio-refresh-button')));
    await tester.pumpAndSettle();
    expect(requests, 2);
  });

  testWidgets('selects a file and renders upload progress and processing', (
    tester,
  ) async {
    final completion = Completer<AudioUploadProcessingResult>();
    final repository = _FakeRepository(
      onUpload: (file, onProgress) {
        onProgress?.call(0.5);
        onProgress?.call(1);
        return completion.future;
      },
    );
    await _pumpAudio(
      tester,
      repository: repository,
      picker: _FakePicker(_selectedFile),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('audio-pick-button')));
    await tester.pumpAndSettle();
    expect(find.text('shift-note.mp3'), findsOneWidget);
    expect(find.text('13 B'), findsOneWidget);
    expect(
      find.byKey(const Key('selected-audio-player-shift-note.mp3')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('audio-upload-button')));
    await tester.pump();
    expect(find.byKey(const Key('audio-upload-progress')), findsOneWidget);
    expect(find.text('Converting speech to English...'), findsOneWidget);
    expect(find.text('Processing audio…'), findsOneWidget);

    completion.complete(_result);
    await tester.pumpAndSettle();
    expect(
      find.text('Processing complete. Your report is ready.'),
      findsOneWidget,
    );
    expect(find.text('PROCESSING COMPLETE'), findsOneWidget);
    expect(
      find.byKey(Key('completed-audio-player-${_audio.id}')),
      findsOneWidget,
    );
    expect(find.text('ENGLISH TRANSCRIPT'), findsOneWidget);
    expect(find.text(_result.transcript), findsOneWidget);
    expect(find.text('AI OPERATIONS REPORT'), findsOneWidget);
    expect(find.text('Main Floor'), findsOneWidget);
    expect(find.text('View Dashboard'), findsOneWidget);
    expect(find.text('View Full Report'), findsOneWidget);
    expect(find.text('Processed'), findsOneWidget);
    expect(find.text('API Cost Report'), findsOneWidget);
    expect(find.text('Audio Duration:'), findsOneWidget);
    expect(find.text('22.1 seconds'), findsOneWidget);
    expect(find.text('Sarvam Model:'), findsOneWidget);
    expect(find.text('saaras:v3'), findsOneWidget);
    expect(find.text('Sarvam Estimated Cost (INR):'), findsOneWidget);
    expect(find.text('₹0.18'), findsOneWidget);
    expect(find.text('OpenAI Model:'), findsOneWidget);
    expect(find.text('gpt-4o-2024-11-20'), findsOneWidget);
    expect(find.text('Input Tokens:'), findsOneWidget);
    expect(find.text('1,250'), findsOneWidget);
    expect(find.text('Cached Input Tokens:'), findsOneWidget);
    expect(find.text('250'), findsOneWidget);
    expect(find.text('Output Tokens:'), findsOneWidget);
    expect(find.text('75'), findsOneWidget);
    expect(find.text('Total Tokens:'), findsOneWidget);
    expect(find.text('1,325'), findsOneWidget);
    expect(find.text('OpenAI Estimated Cost (USD):'), findsOneWidget);
    expect(find.text(r'$0.0017'), findsOneWidget);
    expect(find.text('Total Estimated Cost'), findsOneWidget);
    expect(find.text('Sarvam: ₹0.18'), findsOneWidget);
    expect(find.text(r'OpenAI: $0.0017'), findsOneWidget);
    expect(find.text('Cost per recorded minute:'), findsOneWidget);
    expect(find.text(r'Sarvam ₹0.50 · OpenAI $0.0047'), findsOneWidget);
    expect(find.text('Estimated cost per recorded hour:'), findsOneWidget);
    expect(find.text(r'Sarvam ₹29.97 · OpenAI $0.2807'), findsOneWidget);
    expect(find.text('No audio uploads yet'), findsNothing);
  });

  testWidgets('retains the selected file and retries a failed upload', (
    tester,
  ) async {
    var attempts = 0;
    final repository = _FakeRepository(
      onUpload: (file, onProgress) async {
        attempts += 1;
        if (attempts == 1) throw const ApiException('Upload failed.');
        return _result;
      },
    );
    await _pumpAudio(
      tester,
      repository: repository,
      picker: _FakePicker(_selectedFile),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('audio-pick-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('audio-upload-button')));
    await tester.pumpAndSettle();
    expect(find.text('Upload failed.'), findsOneWidget);
    expect(find.text('shift-note.mp3'), findsOneWidget);
    expect(find.text('Retry upload'), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio-retry-button')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Processed'), findsOneWidget);
  });

  testWidgets('requires confirmation before deleting history', (tester) async {
    String? deletedId;
    final repository = _FakeRepository(
      onFetch: () async => [_audio],
      onDelete: (uploadId) async => deletedId = uploadId,
    );
    await _pumpAudio(tester, repository: repository);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('audio-delete-${_audio.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Delete audio?'), findsOneWidget);
    expect(deletedId, isNull);

    await tester.tap(find.byKey(const Key('audio-confirm-delete-button')));
    await tester.pumpAndSettle();
    expect(deletedId, _audio.id);
    expect(find.text('No audio uploads yet'), findsOneWidget);
    expect(find.text('Audio upload deleted.'), findsOneWidget);
  });

  testWidgets('uses a narrow layout without overflow', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final longNameUpload = AudioUpload(
      id: _audio.id,
      originalFilename:
          'a-very-long-operational-recording-name-that-must-not-overflow.mp3',
      mediaType: _audio.mediaType,
      extension: _audio.extension,
      sizeBytes: _audio.sizeBytes,
      status: _audio.status,
      scanStatus: _audio.scanStatus,
      createdAt: _audio.createdAt,
      updatedAt: _audio.updatedAt,
    );

    await _pumpAudio(
      tester,
      repository: _FakeRepository(onFetch: () async => [longNameUpload]),
      setSurfaceSize: false,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Audio upload'), findsOneWidget);
  });
}

Future<void> _pumpAudio(
  WidgetTester tester, {
  required AudioUploadRepository repository,
  AudioFilePicker? picker,
  bool setSurfaceSize = true,
}) async {
  if (setSurfaceSize) {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        workspaceProvider.overrideWith(
          (ref) => WorkspaceNotifier(
            _UnusedWorkspaceRepository(),
            loadOnCreate: false,
            initialState: _workspaceState,
          ),
        ),
        audioUploadServiceProvider.overrideWith((ref) => repository),
        audioFilePickerProvider.overrideWith(
          (ref) => picker ?? _FakePicker(null),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: AudioUploadScreen())),
    ),
  );
  await tester.pump();
}

final _selectedFile = PickedAudioFile(
  name: 'shift-note.mp3',
  sizeBytes: 13,
  openRead: () => Stream.value([73, 68, 51]),
);

final _audio = AudioUpload(
  id: 'b4754746-c6b4-4ca7-b8aa-c00dcac9ea4d',
  originalFilename: 'shift-note.mp3',
  mediaType: 'audio/mpeg',
  extension: 'mp3',
  sizeBytes: 13,
  status: AudioUploadStatus.ready,
  scanStatus: AudioScanStatus.clean,
  createdAt: DateTime.utc(2026, 8, 3, 10),
  updatedAt: DateTime.utc(2026, 8, 3, 10, 0, 1),
  audioDurationSeconds: 22.1234,
  apiCost: AudioApiCost(
    audioDurationSeconds: 22.1234,
    sarvamModel: 'saaras:v3',
    sarvamEstimatedCostInr: 0.18415306,
    openaiModel: 'gpt-4o-2024-11-20',
    openaiInputTokens: 1250,
    openaiCachedInputTokens: 250,
    openaiOutputTokens: 75,
    openaiTotalTokens: 1325,
    openaiEstimatedCostUsd: 0.001725,
    totalEstimatedCost: {'INR': 0.18415306, 'USD': 0.001725},
  ),
);

final _result = AudioUploadProcessingResult(
  upload: _audio,
  transcript: 'The dinner station is running low on plates.',
  analysis: const AudioAnalysis(
    summary: 'Restock plates at the dinner station',
    category: 'inventory',
    severity: AudioAnalysisSeverity.high,
    requiresAttention: true,
    recommendedAction: 'Move clean plates to the station.',
  ),
  activityId: 'fe67a667-135d-46e6-9c1a-04ba3fc7d258',
  reportId: '9ec4682a-cd7c-4d2f-b462-f8280638a29d',
  workspaceId: 'workspace-1',
  locationId: 'location-1',
  locationName: 'Main Floor',
  processedAt: DateTime.utc(2026, 8, 3, 10, 0, 2),
  source: 'AI Audio Monitor',
);

const _workspaceState = WorkspaceState(
  workspaces: [
    WorkspaceAccess(
      id: 'workspace-1',
      name: 'Restaurant',
      role: WorkspaceRole.owner,
      locations: [
        WorkspaceLocation(
          id: 'location-1',
          name: 'Main Floor',
          currencyCode: 'INR',
        ),
      ],
    ),
  ],
  activeWorkspaceId: 'workspace-1',
  activeLocationId: 'location-1',
  isLoading: false,
);

class _FakePicker implements AudioFilePicker {
  _FakePicker(this.result);

  final PickedAudioFile? result;

  @override
  Future<PickedAudioFile?> pickAudio() async => result;
}

typedef _Fetch = Future<List<AudioUpload>> Function();
typedef _Upload =
    Future<AudioUploadProcessingResult> Function(
      PickedAudioFile file,
      void Function(double progress)? onProgress,
    );
typedef _Delete = Future<void> Function(String uploadId);

class _FakeRepository implements AudioUploadRepository {
  _FakeRepository({this.onFetch, this.onUpload, this.onDelete});

  final _Fetch? onFetch;
  final _Upload? onUpload;
  final _Delete? onDelete;
  final List<AudioUpload> _persisted = [];

  @override
  Future<List<AudioUpload>> fetchHistory({
    required String workspaceId,
    required String locationId,
    int limit = 50,
  }) async {
    expect(workspaceId, 'workspace-1');
    expect(locationId, 'location-1');
    return onFetch?.call() ?? List.unmodifiable(_persisted);
  }

  @override
  Future<AudioUploadProcessingResult> upload(
    PickedAudioFile file, {
    required String locationId,
    required String languageCode,
    void Function(double progress)? onProgress,
  }) async {
    expect(locationId, 'location-1');
    expect(languageCode, defaultAudioLanguageCode);
    final callback = onUpload;
    if (callback == null) throw StateError('Upload was not expected.');
    final result = await callback(file, onProgress);
    _persisted
      ..clear()
      ..add(result.upload);
    return result;
  }

  @override
  Future<AudioUploadProcessingResult> retryProcessing(
    String uploadId, {
    required String workspaceId,
    required String locationId,
  }) async => _result;

  @override
  Future<StoredAudioData> fetchAudio(
    String uploadId, {
    required String workspaceId,
    required String locationId,
  }) async => StoredAudioData(
    bytes: Uint8List.fromList([73, 68, 51]),
    mediaType: 'audio/mpeg',
  );

  @override
  Future<void> delete(
    String uploadId, {
    required String workspaceId,
    required String locationId,
  }) async {
    expect(workspaceId, 'workspace-1');
    expect(locationId, 'location-1');
    final callback = onDelete;
    if (callback == null) throw StateError('Delete was not expected.');
    await callback(uploadId);
  }
}

class _UnusedWorkspaceRepository implements WorkspaceRepository {
  @override
  Future<WorkspaceContext> fetchContext() => throw UnimplementedError();

  @override
  Future<WorkspaceAccess> createWorkspace({
    required String name,
    required String locationName,
    required String currencyCode,
  }) => throw UnimplementedError();

  @override
  Future<WorkspaceLocation> createLocation({
    required String workspaceId,
    required String name,
    required String currencyCode,
  }) => throw UnimplementedError();
}
