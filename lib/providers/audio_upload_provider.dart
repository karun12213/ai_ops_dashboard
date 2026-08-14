import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio_upload.dart';
import '../services/audio_file_picker.dart';
import '../services/audio_upload_service.dart';
import '../services/api_client.dart';
import 'auth_provider.dart';
import 'dashboard_provider.dart';
import 'report_provider.dart';
import 'workspace_provider.dart';

const defaultAudioLanguageCode = 'unknown';

enum AudioTransferPhase {
  idle,
  picking,
  selected,
  uploading,
  transcribing,
  analyzing,
  savingReport,
  completed,
  failed,
}

class AudioUploadState {
  const AudioUploadState({
    this.history = const [],
    this.isLoadingHistory = true,
    this.historyError,
    this.selectedFile,
    this.transferPhase = AudioTransferPhase.idle,
    this.uploadProgress = 0,
    this.operationError,
    this.deletingIds = const {},
    this.lastProcessingResult,
    this.languageCode = defaultAudioLanguageCode,
    this.existingUploadId,
    this.existingReportId,
  });

  final List<AudioUpload> history;
  final bool isLoadingHistory;
  final String? historyError;
  final PickedAudioFile? selectedFile;
  final AudioTransferPhase transferPhase;
  final double uploadProgress;
  final String? operationError;
  final Set<String> deletingIds;
  final AudioUploadProcessingResult? lastProcessingResult;
  final String languageCode;
  final String? existingUploadId;
  final String? existingReportId;

  bool get canUpload =>
      selectedFile != null &&
      transferPhase != AudioTransferPhase.picking &&
      transferPhase != AudioTransferPhase.uploading &&
      transferPhase != AudioTransferPhase.transcribing &&
      transferPhase != AudioTransferPhase.analyzing &&
      transferPhase != AudioTransferPhase.savingReport;

  AudioUploadState copyWith({
    List<AudioUpload>? history,
    bool? isLoadingHistory,
    Object? historyError = _unchanged,
    Object? selectedFile = _unchanged,
    AudioTransferPhase? transferPhase,
    double? uploadProgress,
    Object? operationError = _unchanged,
    Set<String>? deletingIds,
    Object? lastProcessingResult = _unchanged,
    String? languageCode,
    Object? existingUploadId = _unchanged,
    Object? existingReportId = _unchanged,
  }) {
    return AudioUploadState(
      history: history ?? this.history,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
      historyError: identical(historyError, _unchanged)
          ? this.historyError
          : historyError as String?,
      selectedFile: identical(selectedFile, _unchanged)
          ? this.selectedFile
          : selectedFile as PickedAudioFile?,
      transferPhase: transferPhase ?? this.transferPhase,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      operationError: identical(operationError, _unchanged)
          ? this.operationError
          : operationError as String?,
      deletingIds: deletingIds ?? this.deletingIds,
      lastProcessingResult: identical(lastProcessingResult, _unchanged)
          ? this.lastProcessingResult
          : lastProcessingResult as AudioUploadProcessingResult?,
      languageCode: languageCode ?? this.languageCode,
      existingUploadId: identical(existingUploadId, _unchanged)
          ? this.existingUploadId
          : existingUploadId as String?,
      existingReportId: identical(existingReportId, _unchanged)
          ? this.existingReportId
          : existingReportId as String?,
    );
  }
}

const _unchanged = Object();

final audioFilePickerProvider = Provider<AudioFilePicker>((ref) {
  return const PlatformAudioFilePicker();
});

final audioUploadServiceProvider = Provider<AudioUploadRepository>((ref) {
  return AudioUploadService(ref.watch(apiClientProvider));
});

final audioUploadProvider =
    StateNotifierProvider.autoDispose<AudioUploadNotifier, AudioUploadState>((
      ref,
    ) {
      return AudioUploadNotifier(
        ref.watch(audioUploadServiceProvider),
        ref.watch(audioFilePickerProvider),
        activeWorkspaceId: ref.watch(
          workspaceProvider.select((state) => state.activeWorkspaceId),
        ),
        activeLocationId: ref.watch(
          workspaceProvider.select((state) => state.activeLocationId),
        ),
        onProcessed: () {
          ref.invalidate(dashboardProvider);
          ref.invalidate(reportProvider);
        },
      );
    });

class AudioUploadNotifier extends StateNotifier<AudioUploadState> {
  AudioUploadNotifier(
    this._repository,
    this._picker, {
    required this.activeWorkspaceId,
    required this.activeLocationId,
    String languageCode = defaultAudioLanguageCode,
    this.onProcessed,
    bool loadOnCreate = true,
  }) : super(
         AudioUploadState(
           isLoadingHistory: loadOnCreate,
           languageCode: languageCode,
         ),
       ) {
    if (loadOnCreate) loadHistory();
  }

  final AudioUploadRepository _repository;
  final AudioFilePicker _picker;
  final String? activeWorkspaceId;
  final String? activeLocationId;
  final void Function()? onProcessed;
  Timer? _analysisStageTimer;
  Timer? _savingStageTimer;
  int _operationId = 0;

  @override
  void dispose() {
    _cancelStageTimers();
    super.dispose();
  }

  Future<void> loadHistory() async {
    state = state.copyWith(isLoadingHistory: true, historyError: null);
    final workspaceId = activeWorkspaceId;
    final locationId = activeLocationId;
    if (workspaceId == null || locationId == null) {
      state = state.copyWith(
        isLoadingHistory: false,
        historyError:
            'A workspace location is required before loading history.',
      );
      return;
    }
    try {
      final history = await _repository.fetchHistory(
        workspaceId: workspaceId,
        locationId: locationId,
      );
      if (!mounted) return;
      state = state.copyWith(
        history: history,
        isLoadingHistory: false,
        historyError: null,
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        isLoadingHistory: false,
        historyError: error.message,
      );
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(
        isLoadingHistory: false,
        historyError: 'Upload history could not be loaded.',
      );
    }
  }

  Future<void> refresh() => loadHistory();

  Future<void> pickAudio() async {
    state = state.copyWith(
      transferPhase: AudioTransferPhase.picking,
      operationError: null,
      lastProcessingResult: null,
      existingUploadId: null,
      existingReportId: null,
    );
    try {
      final selected = await _picker.pickAudio();
      if (!mounted) return;
      if (selected == null) {
        state = state.copyWith(transferPhase: AudioTransferPhase.idle);
        return;
      }
      final validationError = _selectionError(selected);
      state = state.copyWith(
        selectedFile: validationError == null ? selected : null,
        transferPhase: validationError == null
            ? AudioTransferPhase.selected
            : AudioTransferPhase.failed,
        operationError: validationError,
        uploadProgress: 0,
      );
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(
        transferPhase: AudioTransferPhase.failed,
        operationError: 'The audio file could not be opened.',
      );
    }
  }

  void clearSelection() {
    if (state.transferPhase == AudioTransferPhase.uploading ||
        state.transferPhase == AudioTransferPhase.transcribing ||
        state.transferPhase == AudioTransferPhase.analyzing ||
        state.transferPhase == AudioTransferPhase.savingReport) {
      return;
    }
    state = state.copyWith(
      selectedFile: null,
      transferPhase: AudioTransferPhase.idle,
      uploadProgress: 0,
      operationError: null,
      lastProcessingResult: null,
      existingUploadId: null,
      existingReportId: null,
    );
  }

  Future<void> processAnother() async {
    _cancelStageTimers();
    state = state.copyWith(
      selectedFile: null,
      transferPhase: AudioTransferPhase.idle,
      uploadProgress: 0,
      operationError: null,
      lastProcessingResult: null,
      existingUploadId: null,
      existingReportId: null,
    );
    await pickAudio();
  }

  void selectLanguage(String languageCode) {
    if (_isBusy(state.transferPhase)) return;
    state = state.copyWith(languageCode: languageCode, operationError: null);
  }

  Future<bool> upload() async {
    final selected = state.selectedFile;
    if (selected == null || !state.canUpload) return false;
    final workspaceId = activeWorkspaceId;
    final locationId = activeLocationId;
    if (workspaceId == null ||
        workspaceId.isEmpty ||
        locationId == null ||
        locationId.isEmpty) {
      state = state.copyWith(
        transferPhase: AudioTransferPhase.failed,
        operationError: 'A workspace location is required before uploading.',
      );
      return false;
    }
    state = state.copyWith(
      transferPhase: AudioTransferPhase.uploading,
      uploadProgress: 0,
      operationError: null,
      existingUploadId: null,
      existingReportId: null,
    );
    final operationId = ++_operationId;
    try {
      final result = await _repository.upload(
        selected,
        locationId: locationId,
        languageCode: state.languageCode,
        onProgress: (progress) {
          if (!mounted || operationId != _operationId) return;
          state = state.copyWith(
            transferPhase: progress >= 1
                ? AudioTransferPhase.transcribing
                : AudioTransferPhase.uploading,
            uploadProgress: progress,
          );
          if (progress >= 1) _scheduleServerStages(operationId);
        },
      );
      if (!mounted) return false;
      _cancelStageTimers();
      state = state.copyWith(
        selectedFile: null,
        transferPhase: AudioTransferPhase.completed,
        uploadProgress: 0,
        operationError: null,
        lastProcessingResult: result,
        existingUploadId: null,
        existingReportId: null,
      );
      // The upload and server-side processing have already completed. A
      // best-effort Dashboard refresh must not turn that success into a
      // retryable upload failure (which would duplicate the report).
      try {
        onProcessed?.call();
      } catch (_) {
        // The Dashboard can refresh normally the next time it is opened.
      }
      await loadHistory();
      return true;
    } on ApiException catch (error) {
      if (!mounted) return false;
      _cancelStageTimers();
      state = state.copyWith(
        transferPhase: AudioTransferPhase.failed,
        operationError: error.message,
        existingUploadId: error.existingUploadId,
        existingReportId: error.existingReportId,
      );
      await loadHistory();
      return false;
    } catch (error, stackTrace) {
      if (!mounted) return false;
      _cancelStageTimers();
      if (kDebugMode) {
        debugPrint(
          'Unexpected audio upload state failure: ${error.runtimeType}\n'
          '$stackTrace',
        );
      }
      state = state.copyWith(
        transferPhase: AudioTransferPhase.failed,
        operationError: 'The recording could not be processed.',
      );
      await loadHistory();
      return false;
    }
  }

  Future<bool> retry() => upload();

  Future<bool> retryStored(String uploadId) async {
    final workspaceId = activeWorkspaceId;
    final locationId = activeLocationId;
    if (workspaceId == null ||
        locationId == null ||
        _isBusy(state.transferPhase)) {
      return false;
    }
    state = state.copyWith(
      transferPhase: AudioTransferPhase.transcribing,
      operationError: null,
    );
    final operationId = ++_operationId;
    _scheduleServerStages(operationId);
    try {
      final result = await _repository.retryProcessing(
        uploadId,
        workspaceId: workspaceId,
        locationId: locationId,
      );
      if (!mounted || operationId != _operationId) return false;
      _cancelStageTimers();
      state = state.copyWith(
        transferPhase: AudioTransferPhase.completed,
        lastProcessingResult: result,
        operationError: null,
      );
      onProcessed?.call();
      await loadHistory();
      return true;
    } on ApiException catch (error) {
      if (!mounted) return false;
      _cancelStageTimers();
      state = state.copyWith(
        transferPhase: AudioTransferPhase.failed,
        operationError: error.message,
      );
      await loadHistory();
      return false;
    }
  }

  Future<StoredAudioData> fetchStoredAudio(String uploadId) {
    final workspaceId = activeWorkspaceId;
    final locationId = activeLocationId;
    if (workspaceId == null || locationId == null) {
      throw const ApiException(
        'The selected restaurant location could not be found.',
        statusCode: 404,
      );
    }
    return _repository.fetchAudio(
      uploadId,
      workspaceId: workspaceId,
      locationId: locationId,
    );
  }

  Future<bool> delete(String uploadId) async {
    if (state.deletingIds.contains(uploadId)) return false;
    final workspaceId = activeWorkspaceId;
    final locationId = activeLocationId;
    if (workspaceId == null || locationId == null) return false;
    state = state.copyWith(
      deletingIds: {...state.deletingIds, uploadId},
      operationError: null,
    );
    try {
      await _repository.delete(
        uploadId,
        workspaceId: workspaceId,
        locationId: locationId,
      );
      if (!mounted) return false;
      state = state.copyWith(
        history: state.history.where((item) => item.id != uploadId).toList(),
        deletingIds: {...state.deletingIds}..remove(uploadId),
      );
      try {
        onProcessed?.call();
      } catch (_) {}
      return true;
    } on ApiException catch (error) {
      if (!mounted) return false;
      state = state.copyWith(
        deletingIds: {...state.deletingIds}..remove(uploadId),
        operationError: error.message,
      );
      return false;
    } catch (_) {
      if (!mounted) return false;
      state = state.copyWith(
        deletingIds: {...state.deletingIds}..remove(uploadId),
        operationError: 'The audio upload could not be deleted.',
      );
      return false;
    }
  }

  void dismissOperationError() {
    state = state.copyWith(
      operationError: null,
      existingUploadId: null,
      existingReportId: null,
    );
  }

  void _scheduleServerStages(int operationId) {
    _cancelStageTimers();
    _analysisStageTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || operationId != _operationId) return;
      if (state.transferPhase == AudioTransferPhase.transcribing) {
        state = state.copyWith(transferPhase: AudioTransferPhase.analyzing);
      }
    });
    _savingStageTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || operationId != _operationId) return;
      if (state.transferPhase == AudioTransferPhase.transcribing ||
          state.transferPhase == AudioTransferPhase.analyzing) {
        state = state.copyWith(transferPhase: AudioTransferPhase.savingReport);
      }
    });
  }

  void _cancelStageTimers() {
    _analysisStageTimer?.cancel();
    _savingStageTimer?.cancel();
    _analysisStageTimer = null;
    _savingStageTimer = null;
  }

  static bool _isBusy(AudioTransferPhase phase) =>
      phase == AudioTransferPhase.picking ||
      phase == AudioTransferPhase.uploading ||
      phase == AudioTransferPhase.transcribing ||
      phase == AudioTransferPhase.analyzing ||
      phase == AudioTransferPhase.savingReport;

  static String? _selectionError(PickedAudioFile file) {
    if (!supportedAudioExtensions.contains(file.extension)) {
      return 'Choose an MP3, WAV, M4A, AAC, OGG, Opus, or MP4 audio file.';
    }
    if (file.sizeBytes <= 0) return 'The selected file is empty.';
    if (file.sizeBytes > maxAudioUploadBytes) {
      return 'Audio files cannot exceed 100 MB.';
    }
    return null;
  }
}
