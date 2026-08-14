import 'dart:async';
import 'dart:typed_data';

import 'package:ai_ops_dashboard/models/audio_upload.dart';
import 'package:ai_ops_dashboard/providers/audio_upload_provider.dart';
import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/audio_file_picker.dart';
import 'package:ai_ops_dashboard/services/audio_upload_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads history and can recover from a history error', () async {
    final repository = _FakeRepository()..historyError = Exception('offline');
    final notifier = AudioUploadNotifier(
      repository,
      _FakePicker(null),
      activeWorkspaceId: 'workspace-1',
      activeLocationId: 'location-1',
      loadOnCreate: false,
    );

    await notifier.loadHistory();
    expect(notifier.state.historyError, 'Upload history could not be loaded.');
    expect(notifier.state.isLoadingHistory, isFalse);

    repository
      ..historyError = null
      ..history = [_audio];
    await notifier.refresh();
    expect(notifier.state.history, [_audio]);
    expect(notifier.state.historyError, isNull);
  });

  test('validates selected format and size before calling the API', () async {
    final repository = _FakeRepository();
    final oversized = PickedAudioFile(
      name: 'large.mp3',
      sizeBytes: maxAudioUploadBytes + 1,
      openRead: () => const Stream.empty(),
    );
    final notifier = AudioUploadNotifier(
      repository,
      _FakePicker(oversized),
      activeWorkspaceId: 'workspace-1',
      activeLocationId: 'location-1',
      loadOnCreate: false,
    );

    await notifier.pickAudio();

    expect(notifier.state.selectedFile, isNull);
    expect(notifier.state.transferPhase, AudioTransferPhase.failed);
    expect(notifier.state.operationError, 'Audio files cannot exceed 100 MB.');
    expect(repository.uploadCalls, 0);
  });

  test('exposes uploading and processing progress then adds history', () async {
    final completion = Completer<AudioUploadProcessingResult>();
    final repository = _FakeRepository()..uploadCompletion = completion;
    final selection = _file();
    var dashboardRefreshes = 0;
    final notifier = AudioUploadNotifier(
      repository,
      _FakePicker(selection),
      activeWorkspaceId: 'workspace-1',
      activeLocationId: 'location-1',
      onProcessed: () => dashboardRefreshes += 1,
      loadOnCreate: false,
    );
    await notifier.pickAudio();

    final upload = notifier.upload();
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.transferPhase, AudioTransferPhase.transcribing);
    expect(notifier.state.uploadProgress, 1);
    expect(notifier.state.selectedFile, same(selection));

    completion.complete(_result);
    expect(await upload, isTrue);
    expect(notifier.state.transferPhase, AudioTransferPhase.completed);
    expect(notifier.state.selectedFile, isNull);
    expect(notifier.state.history, [_audio]);
    expect(notifier.state.lastProcessingResult?.activityId, _result.activityId);
    expect(repository.locationIds, ['location-1']);
    expect(repository.languageCodes, [defaultAudioLanguageCode]);
    expect(dashboardRefreshes, 1);
  });

  test(
    'retains selection for retry and handles delete success and failure',
    () async {
      final repository = _FakeRepository()
        ..uploadError = const ApiException('Upload failed.');
      final selection = _file();
      final notifier = AudioUploadNotifier(
        repository,
        _FakePicker(selection),
        activeWorkspaceId: 'workspace-1',
        activeLocationId: 'location-1',
        loadOnCreate: false,
      );
      await notifier.pickAudio();

      expect(await notifier.upload(), isFalse);
      expect(notifier.state.selectedFile, same(selection));
      expect(notifier.state.transferPhase, AudioTransferPhase.failed);
      expect(notifier.state.operationError, 'Upload failed.');

      repository
        ..uploadError = null
        ..uploadResult = _result;
      expect(await notifier.retry(), isTrue);
      expect(repository.uploadCalls, 2);

      repository.deleteError = const ApiException('Delete failed.');
      expect(await notifier.delete(_audio.id), isFalse);
      expect(notifier.state.history, [_audio]);
      expect(notifier.state.deletingIds, isEmpty);

      repository.deleteError = null;
      expect(await notifier.delete(_audio.id), isTrue);
      expect(notifier.state.history, isEmpty);
    },
  );

  test(
    'dashboard refresh failure does not overturn a completed upload',
    () async {
      final repository = _FakeRepository()..uploadResult = _result;
      final notifier = AudioUploadNotifier(
        repository,
        _FakePicker(_file()),
        activeWorkspaceId: 'workspace-1',
        activeLocationId: 'location-1',
        onProcessed: () => throw StateError('dashboard refresh failed'),
        loadOnCreate: false,
      );
      await notifier.pickAudio();

      expect(await notifier.upload(), isTrue);
      expect(notifier.state.transferPhase, AudioTransferPhase.completed);
      expect(notifier.state.operationError, isNull);
      expect(notifier.state.selectedFile, isNull);
      expect(notifier.state.history, [_audio]);
      expect(notifier.state.lastProcessingResult, same(_result));
    },
  );

  test('blocks upload when no active location is available', () async {
    final repository = _FakeRepository();
    final notifier = AudioUploadNotifier(
      repository,
      _FakePicker(_file()),
      activeWorkspaceId: 'workspace-1',
      activeLocationId: null,
      loadOnCreate: false,
    );
    await notifier.pickAudio();

    expect(await notifier.upload(), isFalse);
    expect(repository.uploadCalls, 0);
    expect(
      notifier.state.operationError,
      'A workspace location is required before uploading.',
    );
  });

  test(
    'duplicate completion exposes the existing report without retrying providers',
    () async {
      final repository = _FakeRepository()
        ..uploadError = const ApiException(
          'This recording has already been processed. Open the existing report.',
          statusCode: 409,
          code: 'duplicate_completed',
          existingUploadId: 'existing-upload',
          existingReportId: 'existing-report',
        );
      final notifier = AudioUploadNotifier(
        repository,
        _FakePicker(_file()),
        activeWorkspaceId: 'workspace-1',
        activeLocationId: 'location-1',
        loadOnCreate: false,
      );
      await notifier.pickAudio();

      expect(await notifier.upload(), isFalse);
      expect(notifier.state.existingUploadId, 'existing-upload');
      expect(notifier.state.existingReportId, 'existing-report');
      expect(notifier.state.transferPhase, AudioTransferPhase.failed);
      expect(repository.uploadCalls, 1);
    },
  );

  test('uses the selected Sarvam language code', () async {
    final repository = _FakeRepository();
    final notifier = AudioUploadNotifier(
      repository,
      _FakePicker(_file()),
      activeWorkspaceId: 'workspace-1',
      activeLocationId: 'location-1',
      loadOnCreate: false,
    );
    notifier.selectLanguage('hi-IN');
    await notifier.pickAudio();

    expect(await notifier.upload(), isTrue);
    expect(repository.languageCodes, ['hi-IN']);
  });
}

PickedAudioFile _file() => PickedAudioFile(
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

class _FakePicker implements AudioFilePicker {
  _FakePicker(this.result);

  PickedAudioFile? result;

  @override
  Future<PickedAudioFile?> pickAudio() async => result;
}

class _FakeRepository implements AudioUploadRepository {
  List<AudioUpload> history = [];
  Object? historyError;
  AudioUploadProcessingResult uploadResult = _result;
  Object? uploadError;
  Object? deleteError;
  Completer<AudioUploadProcessingResult>? uploadCompletion;
  int uploadCalls = 0;
  final locationIds = <String>[];
  final languageCodes = <String>[];

  @override
  Future<List<AudioUpload>> fetchHistory({
    required String workspaceId,
    required String locationId,
    int limit = 50,
  }) async {
    expect(workspaceId, 'workspace-1');
    expect(locationId, 'location-1');
    if (historyError case final error?) throw error;
    return history;
  }

  @override
  Future<AudioUploadProcessingResult> upload(
    PickedAudioFile file, {
    required String locationId,
    required String languageCode,
    void Function(double progress)? onProgress,
  }) async {
    uploadCalls += 1;
    locationIds.add(locationId);
    languageCodes.add(languageCode);
    onProgress?.call(0.4);
    onProgress?.call(1);
    if (uploadError case final error?) throw error;
    final completion = uploadCompletion;
    final result = completion == null ? uploadResult : await completion.future;
    history = [result.upload];
    return result;
  }

  @override
  Future<AudioUploadProcessingResult> retryProcessing(
    String uploadId, {
    required String workspaceId,
    required String locationId,
  }) async => uploadResult;

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
    if (deleteError case final error?) throw error;
  }
}
