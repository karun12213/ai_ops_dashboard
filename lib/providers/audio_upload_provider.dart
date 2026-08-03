import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio_upload.dart';
import '../services/audio_file_picker.dart';
import '../services/audio_upload_service.dart';
import '../services/api_client.dart';
import 'auth_provider.dart';

enum AudioTransferPhase { idle, picking, uploading, processing, failed }

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
  });

  final List<AudioUpload> history;
  final bool isLoadingHistory;
  final String? historyError;
  final PickedAudioFile? selectedFile;
  final AudioTransferPhase transferPhase;
  final double uploadProgress;
  final String? operationError;
  final Set<String> deletingIds;

  bool get canUpload =>
      selectedFile != null &&
      transferPhase != AudioTransferPhase.picking &&
      transferPhase != AudioTransferPhase.uploading &&
      transferPhase != AudioTransferPhase.processing;

  AudioUploadState copyWith({
    List<AudioUpload>? history,
    bool? isLoadingHistory,
    Object? historyError = _unchanged,
    Object? selectedFile = _unchanged,
    AudioTransferPhase? transferPhase,
    double? uploadProgress,
    Object? operationError = _unchanged,
    Set<String>? deletingIds,
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
      );
    });

class AudioUploadNotifier extends StateNotifier<AudioUploadState> {
  AudioUploadNotifier(
    this._repository,
    this._picker, {
    bool loadOnCreate = true,
  }) : super(AudioUploadState(isLoadingHistory: loadOnCreate)) {
    if (loadOnCreate) loadHistory();
  }

  final AudioUploadRepository _repository;
  final AudioFilePicker _picker;

  Future<void> loadHistory() async {
    state = state.copyWith(isLoadingHistory: true, historyError: null);
    try {
      final history = await _repository.fetchHistory();
      if (!mounted) return;
      state = state.copyWith(
        history: history,
        isLoadingHistory: false,
        historyError: null,
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
            ? AudioTransferPhase.idle
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
        state.transferPhase == AudioTransferPhase.processing) {
      return;
    }
    state = state.copyWith(
      selectedFile: null,
      transferPhase: AudioTransferPhase.idle,
      uploadProgress: 0,
      operationError: null,
    );
  }

  Future<bool> upload() async {
    final selected = state.selectedFile;
    if (selected == null || !state.canUpload) return false;
    state = state.copyWith(
      transferPhase: AudioTransferPhase.uploading,
      uploadProgress: 0,
      operationError: null,
    );
    try {
      final uploaded = await _repository.upload(
        selected,
        onProgress: (progress) {
          if (!mounted) return;
          state = state.copyWith(
            transferPhase: progress >= 1
                ? AudioTransferPhase.processing
                : AudioTransferPhase.uploading,
            uploadProgress: progress,
          );
        },
      );
      if (!mounted) return false;
      state = state.copyWith(
        history: [
          uploaded,
          ...state.history.where((item) => item.id != uploaded.id),
        ],
        selectedFile: null,
        transferPhase: AudioTransferPhase.idle,
        uploadProgress: 0,
        operationError: null,
      );
      return true;
    } on ApiException catch (error) {
      if (!mounted) return false;
      state = state.copyWith(
        transferPhase: AudioTransferPhase.failed,
        operationError: error.message,
      );
      return false;
    } catch (_) {
      if (!mounted) return false;
      state = state.copyWith(
        transferPhase: AudioTransferPhase.failed,
        operationError: 'The upload could not be completed.',
      );
      return false;
    }
  }

  Future<bool> retry() => upload();

  Future<bool> delete(String uploadId) async {
    if (state.deletingIds.contains(uploadId)) return false;
    state = state.copyWith(
      deletingIds: {...state.deletingIds, uploadId},
      operationError: null,
    );
    try {
      await _repository.delete(uploadId);
      if (!mounted) return false;
      state = state.copyWith(
        history: state.history.where((item) => item.id != uploadId).toList(),
        deletingIds: {...state.deletingIds}..remove(uploadId),
      );
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
    state = state.copyWith(operationError: null);
  }

  static String? _selectionError(PickedAudioFile file) {
    if (!supportedAudioExtensions.contains(file.extension)) {
      return 'Choose an MP3, WAV, M4A, AAC, or OGG file.';
    }
    if (file.sizeBytes <= 0) return 'The selected file is empty.';
    if (file.sizeBytes > maxAudioUploadBytes) {
      return 'Audio files cannot exceed 100 MB.';
    }
    return null;
  }
}
