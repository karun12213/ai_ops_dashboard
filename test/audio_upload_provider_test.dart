import 'dart:async';

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
      loadOnCreate: false,
    );

    await notifier.pickAudio();

    expect(notifier.state.selectedFile, isNull);
    expect(notifier.state.transferPhase, AudioTransferPhase.failed);
    expect(notifier.state.operationError, 'Audio files cannot exceed 100 MB.');
    expect(repository.uploadCalls, 0);
  });

  test('exposes uploading and processing progress then adds history', () async {
    final completion = Completer<AudioUpload>();
    final repository = _FakeRepository()..uploadCompletion = completion;
    final selection = _file();
    final notifier = AudioUploadNotifier(
      repository,
      _FakePicker(selection),
      loadOnCreate: false,
    );
    await notifier.pickAudio();

    final upload = notifier.upload();
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.transferPhase, AudioTransferPhase.processing);
    expect(notifier.state.uploadProgress, 1);
    expect(notifier.state.selectedFile, same(selection));

    completion.complete(_audio);
    expect(await upload, isTrue);
    expect(notifier.state.transferPhase, AudioTransferPhase.idle);
    expect(notifier.state.selectedFile, isNull);
    expect(notifier.state.history, [_audio]);
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
        loadOnCreate: false,
      );
      await notifier.pickAudio();

      expect(await notifier.upload(), isFalse);
      expect(notifier.state.selectedFile, same(selection));
      expect(notifier.state.transferPhase, AudioTransferPhase.failed);
      expect(notifier.state.operationError, 'Upload failed.');

      repository
        ..uploadError = null
        ..uploadResult = _audio;
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

class _FakePicker implements AudioFilePicker {
  _FakePicker(this.result);

  PickedAudioFile? result;

  @override
  Future<PickedAudioFile?> pickAudio() async => result;
}

class _FakeRepository implements AudioUploadRepository {
  List<AudioUpload> history = [];
  Object? historyError;
  AudioUpload uploadResult = _audio;
  Object? uploadError;
  Object? deleteError;
  Completer<AudioUpload>? uploadCompletion;
  int uploadCalls = 0;

  @override
  Future<List<AudioUpload>> fetchHistory({int limit = 50}) async {
    if (historyError case final error?) throw error;
    return history;
  }

  @override
  Future<AudioUpload> upload(
    PickedAudioFile file, {
    void Function(double progress)? onProgress,
  }) async {
    uploadCalls += 1;
    onProgress?.call(0.4);
    onProgress?.call(1);
    if (uploadError case final error?) throw error;
    final completion = uploadCompletion;
    return completion == null ? uploadResult : completion.future;
  }

  @override
  Future<void> delete(String uploadId) async {
    if (deleteError case final error?) throw error;
  }
}
