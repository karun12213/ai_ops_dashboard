import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

class AudioBytesSource {
  const AudioBytesSource({required this.bytes, required this.mediaType});

  final Uint8List bytes;
  final String mediaType;
}

class AudioBytesPlayer extends StatefulWidget {
  const AudioBytesPlayer({
    required this.sourceKey,
    required this.load,
    this.compact = false,
    super.key,
  });

  final Object sourceKey;
  final Future<AudioBytesSource> Function() load;
  final bool compact;

  @override
  State<AudioBytesPlayer> createState() => _AudioBytesPlayerState();
}

class _AudioBytesPlayerState extends State<AudioBytesPlayer> {
  late final AudioPlayer _player;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _isLoading = false;
  bool _hasSource = false;
  String? _error;

  bool get _isPlaying => _playerState == PlayerState.playing;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _subscriptions.add(
      _player.onPlayerStateChanged.listen((value) {
        if (mounted) setState(() => _playerState = value);
      }),
    );
    _subscriptions.add(
      _player.onDurationChanged.listen((value) {
        if (mounted) setState(() => _duration = value);
      }),
    );
    _subscriptions.add(
      _player.onPositionChanged.listen((value) {
        if (mounted) setState(() => _position = value);
      }),
    );
    _subscriptions.add(
      _player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _position = Duration.zero);
      }),
    );
  }

  @override
  void didUpdateWidget(covariant AudioBytesPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey == widget.sourceKey) return;
    unawaited(_player.stop());
    _hasSource = false;
    _duration = Duration.zero;
    _position = Duration.zero;
    _error = null;
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_isLoading) return;
    if (_isPlaying) {
      await _player.pause();
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      if (!_hasSource) {
        final source = await widget.load();
        await _player.setSourceBytes(source.bytes, mimeType: source.mediaType);
        _hasSource = true;
      }
      await _player.resume();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Audio playback is unavailable.';
          _hasSource = false;
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _seek(double milliseconds) async {
    await _player.seek(Duration(milliseconds: milliseconds.round()));
  }

  @override
  Widget build(BuildContext context) {
    final maxMilliseconds = _duration.inMilliseconds.toDouble();
    final currentMilliseconds = _position.inMilliseconds
        .clamp(0, _duration.inMilliseconds)
        .toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: widget.compact ? MainAxisSize.min : MainAxisSize.max,
          children: [
            OutlinedButton.icon(
              onPressed: _isLoading ? null : _toggle,
              icon: _isLoading
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
              label: Text(_isPlaying ? 'Pause' : 'Play'),
            ),
            if (!widget.compact) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Slider(
                  value: maxMilliseconds > 0 ? currentMilliseconds : 0,
                  max: maxMilliseconds > 0 ? maxMilliseconds : 1,
                  onChanged: maxMilliseconds > 0 ? _seek : null,
                ),
              ),
              SizedBox(
                width: 86,
                child: Text(
                  '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  static String _formatDuration(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
