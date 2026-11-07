import 'dart:convert';
import '../../../../core/domain/models/media_item.dart';
import 'connect_playback_sync.dart';

enum ConnectCommandAction {
  play,
  pause,
  togglePlayPause,
  seek,
  next,
  previous,
  setVolume,
  setSpeed,
  setPitch,
  toggleShuffle,
  cycleLoopMode,
  jumpToQueueIndex,
  removeTrackFromQueue,
  reorderQueue,
  clearUpcomingQueue,
  playTrack,
  addToQueue,
  playNext,
  requestSync,
}

class ConnectCommand {
  final ConnectCommandAction action;
  final int? positionMs;
  final double? volume;
  final double? speed;
  final double? pitch;
  final int? index;
  final int? oldIndex;
  final int? newIndex;
  final MediaItem? track;

  const ConnectCommand({
    required this.action,
    this.positionMs,
    this.volume,
    this.speed,
    this.pitch,
    this.index,
    this.oldIndex,
    this.newIndex,
    this.track,
  });

  Map<String, dynamic> toJson() {
    return {
      'action': action.name,
      if (positionMs != null) 'positionMs': positionMs,
      if (volume != null) 'volume': volume,
      if (speed != null) 'speed': speed,
      if (pitch != null) 'pitch': pitch,
      if (index != null) 'index': index,
      if (oldIndex != null) 'oldIndex': oldIndex,
      if (newIndex != null) 'newIndex': newIndex,
      if (track != null) 'track': track!.toJson(includeArt: false),
    };
  }

  factory ConnectCommand.fromJson(Map<String, dynamic> json) {
    final actionStr = json['action'] as String? ?? '';
    final action = ConnectCommandAction.values.firstWhere(
      (a) => a.name == actionStr,
      orElse: () => ConnectCommandAction.requestSync,
    );
    return ConnectCommand(
      action: action,
      positionMs: (json['positionMs'] as num?)?.toInt(),
      volume: (json['volume'] as num?)?.toDouble(),
      speed: (json['speed'] as num?)?.toDouble(),
      pitch: (json['pitch'] as num?)?.toDouble(),
      index: (json['index'] as num?)?.toInt(),
      oldIndex: (json['oldIndex'] as num?)?.toInt(),
      newIndex: (json['newIndex'] as num?)?.toInt(),
      track: json['track'] != null
          ? MediaItem.fromJson(
              Map<String, dynamic>.from(json['track'] as Map),
            )
          : null,
    );
  }
}

enum ConnectPayloadType {
  playbackSync,
  command,
  ping,
  pong,
  error,
  disconnect,
}

class ConnectPayload {
  final ConnectPayloadType type;
  final ConnectPlaybackSync? sync;
  final ConnectCommand? command;
  final String? message;
  final int timestampMs;

  ConnectPayload({
    required this.type,
    this.sync,
    this.command,
    this.message,
    int? timestampMs,
  }) : timestampMs = timestampMs ?? DateTime.now().millisecondsSinceEpoch;

  factory ConnectPayload.sync(ConnectPlaybackSync sync) => ConnectPayload(
        type: ConnectPayloadType.playbackSync,
        sync: sync,
      );

  factory ConnectPayload.command(ConnectCommand command) => ConnectPayload(
        type: ConnectPayloadType.command,
        command: command,
      );

  factory ConnectPayload.ping() => ConnectPayload(
        type: ConnectPayloadType.ping,
      );

  factory ConnectPayload.pong() => ConnectPayload(
        type: ConnectPayloadType.pong,
      );

  factory ConnectPayload.error(String message) => ConnectPayload(
        type: ConnectPayloadType.error,
        message: message,
      );

  factory ConnectPayload.disconnect([String? reason]) => ConnectPayload(
        type: ConnectPayloadType.disconnect,
        message: reason,
      );

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'timestampMs': timestampMs,
      if (sync != null) 'sync': sync!.toJson(),
      if (command != null) 'command': command!.toJson(),
      if (message != null) 'message': message,
    };
  }

  String encode() => jsonEncode(toJson());

  factory ConnectPayload.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? '';
    final type = ConnectPayloadType.values.firstWhere(
      (t) => t.name == typeStr,
      orElse: () => ConnectPayloadType.ping,
    );
    return ConnectPayload(
      type: type,
      timestampMs: (json['timestampMs'] as num?)?.toInt(),
      sync: json['sync'] != null
          ? ConnectPlaybackSync.fromJson(
              Map<String, dynamic>.from(json['sync'] as Map),
            )
          : null,
      command: json['command'] != null
          ? ConnectCommand.fromJson(
              Map<String, dynamic>.from(json['command'] as Map),
            )
          : null,
      message: json['message'] as String?,
    );
  }

  static ConnectPayload? tryDecode(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is Map<String, dynamic>) {
        return ConnectPayload.fromJson(map);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

