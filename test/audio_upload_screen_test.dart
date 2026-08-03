import 'dart:async';

import 'package:ai_ops_dashboard/models/audio_upload.dart';
import 'package:ai_ops_dashboard/providers/audio_upload_provider.dart';
import 'package:ai_ops_dashboard/screens/audio_upload_screen.dart';
import 'package:ai_ops_dashboard/services/api_client.dart';
import 'package:ai_ops_dashboard/services/audio_file_picker.dart';
import 'package:ai_ops_dashboard/services/audio_upload_service.dart';
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
    final completion = Completer<AudioUpload>();
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

    await tester.tap(find.byKey(const Key('audio-upload-button')));
    await tester.pump();
    expect(find.byKey(const Key('audio-upload-progress')), findsOneWidget);
    expect(find.text('Finishing secure upload…'), findsOneWidget);
    expect(find.text('Processing…'), findsOneWidget);

    completion.complete(_audio);
    await tester.pumpAndSettle();
    expect(find.text('Audio upload completed.'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
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
        return _audio;
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
    expect(find.text('Ready'), findsOneWidget);
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
);

class _FakePicker implements AudioFilePicker {
  _FakePicker(this.result);

  final PickedAudioFile? result;

  @override
  Future<PickedAudioFile?> pickAudio() async => result;
}

typedef _Fetch = Future<List<AudioUpload>> Function();
typedef _Upload =
    Future<AudioUpload> Function(
      PickedAudioFile file,
      void Function(double progress)? onProgress,
    );
typedef _Delete = Future<void> Function(String uploadId);

class _FakeRepository implements AudioUploadRepository {
  _FakeRepository({this.onFetch, this.onUpload, this.onDelete});

  final _Fetch? onFetch;
  final _Upload? onUpload;
  final _Delete? onDelete;

  @override
  Future<List<AudioUpload>> fetchHistory({int limit = 50}) async {
    return onFetch?.call() ?? [];
  }

  @override
  Future<AudioUpload> upload(
    PickedAudioFile file, {
    void Function(double progress)? onProgress,
  }) {
    final callback = onUpload;
    if (callback == null) throw StateError('Upload was not expected.');
    return callback(file, onProgress);
  }

  @override
  Future<void> delete(String uploadId) async {
    final callback = onDelete;
    if (callback == null) throw StateError('Delete was not expected.');
    await callback(uploadId);
  }
}
