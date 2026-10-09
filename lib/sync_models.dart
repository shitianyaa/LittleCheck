import 'dart:convert';

import 'package:crypto/crypto.dart';

const syncProtocolVersion = 1;

enum SyncSource { left, right }

String syncHash(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

String syncTombstoneHash(String kind, String id) =>
    syncHash({'kind': kind, 'id': id, 'deleted': true});

class SyncNoteVersion {
  const SyncNoteVersion({
    required this.id,
    required this.contentHash,
    required this.trashed,
    this.folderId,
  });

  final String id;
  final String contentHash;
  final String? folderId;
  final bool trashed;

  String get stateHash => syncHash({
    'contentHash': contentHash,
    'folderId': folderId,
    'trashed': trashed,
  });

  SyncNoteVersion copyWith({
    String? id,
    String? folderId,
    bool clearFolder = false,
  }) => SyncNoteVersion(
    id: id ?? this.id,
    contentHash: contentHash,
    folderId: clearFolder ? null : folderId ?? this.folderId,
    trashed: trashed,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'contentHash': contentHash,
    'folderId': folderId,
    'trashed': trashed,
    'stateHash': stateHash,
  };
}

class SyncFolderVersion {
  const SyncFolderVersion({required this.id, required this.name});

  final String id;
  final String name;

  String get stateHash => syncHash({'name': name});

  SyncFolderVersion copyWith({String? id}) =>
      SyncFolderVersion(id: id ?? this.id, name: name);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'stateHash': stateHash,
  };
}

class SyncEntityState {
  const SyncEntityState.live({required this.id, required this.stateHash})
    : deleted = false;

  SyncEntityState.tombstone({required String kind, required this.id})
    : deleted = true,
      stateHash = syncTombstoneHash(kind, id);

  final String id;
  final String stateHash;
  final bool deleted;
}

class SyncEntityResolution {
  const SyncEntityResolution({
    this.originalSource,
    this.originalDeleted = false,
    this.conflictSource,
    this.conflictId,
    this.invalidReason,
  });

  final SyncSource? originalSource;
  final bool originalDeleted;
  final SyncSource? conflictSource;
  final String? conflictId;
  final String? invalidReason;

  bool get isConflict => conflictSource != null;
  bool get isInvalid => invalidReason != null;
}

String deterministicConflictId({
  required String kind,
  required String originalId,
  required String? baselineHash,
  required String leftDeviceId,
  required String? leftStateHash,
  required String rightDeviceId,
  required String? rightStateHash,
}) {
  final sides =
      [
        {'deviceId': leftDeviceId, 'stateHash': leftStateHash},
        {'deviceId': rightDeviceId, 'stateHash': rightStateHash},
      ]..sort(
        (a, b) => (a['deviceId'] as String).compareTo(b['deviceId'] as String),
      );
  final digest = syncHash({
    'kind': kind,
    'originalId': originalId,
    'baselineHash': baselineHash,
    'sides': sides,
  });
  return 'conflict_${digest.substring(0, 40)}';
}

SyncEntityResolution resolveSyncEntity({
  required String kind,
  required String entityId,
  required String leftDeviceId,
  required String rightDeviceId,
  required SyncEntityState? left,
  required SyncEntityState? right,
  String? baselineHash,
}) {
  if (left == null && right == null) {
    if (baselineHash != null) {
      return const SyncEntityResolution(invalidReason: '已存在同步基线的条目不能无墓碑消失');
    }
    return const SyncEntityResolution();
  }

  if ((left != null && left.id != entityId) ||
      (right != null && right.id != entityId)) {
    return const SyncEntityResolution(invalidReason: '同步条目 ID 不一致');
  }

  if (baselineHash != null && (left == null || right == null)) {
    return const SyncEntityResolution(invalidReason: '已存在同步基线的条目不能无墓碑消失');
  }

  if (left?.stateHash == right?.stateHash) {
    if (left == null) return const SyncEntityResolution();
    return SyncEntityResolution(
      originalSource: SyncSource.left,
      originalDeleted: left.deleted,
    );
  }

  if (baselineHash == null) {
    if (left == null) {
      return SyncEntityResolution(
        originalSource: SyncSource.right,
        originalDeleted: right!.deleted,
      );
    }
    if (right == null) {
      return SyncEntityResolution(
        originalSource: SyncSource.left,
        originalDeleted: left.deleted,
      );
    }
    return _conflict(
      kind: kind,
      entityId: entityId,
      baselineHash: null,
      leftDeviceId: leftDeviceId,
      rightDeviceId: rightDeviceId,
      left: left,
      right: right,
    );
  }

  final leftChanged = left!.stateHash != baselineHash;
  final rightChanged = right!.stateHash != baselineHash;
  if (!leftChanged && !rightChanged) {
    return SyncEntityResolution(
      originalSource: SyncSource.left,
      originalDeleted: left.deleted,
    );
  }
  if (leftChanged && !rightChanged) {
    return SyncEntityResolution(
      originalSource: SyncSource.left,
      originalDeleted: left.deleted,
    );
  }
  if (!leftChanged && rightChanged) {
    return SyncEntityResolution(
      originalSource: SyncSource.right,
      originalDeleted: right.deleted,
    );
  }
  if (left.stateHash == right.stateHash) {
    return SyncEntityResolution(
      originalSource: SyncSource.left,
      originalDeleted: left.deleted,
    );
  }
  return _conflict(
    kind: kind,
    entityId: entityId,
    baselineHash: baselineHash,
    leftDeviceId: leftDeviceId,
    rightDeviceId: rightDeviceId,
    left: left,
    right: right,
  );
}

SyncEntityResolution _conflict({
  required String kind,
  required String entityId,
  required String? baselineHash,
  required String leftDeviceId,
  required String rightDeviceId,
  required SyncEntityState left,
  required SyncEntityState right,
}) {
  final conflictId = deterministicConflictId(
    kind: kind,
    originalId: entityId,
    baselineHash: baselineHash,
    leftDeviceId: leftDeviceId,
    leftStateHash: left.stateHash,
    rightDeviceId: rightDeviceId,
    rightStateHash: right.stateHash,
  );

  if (left.deleted != right.deleted) {
    return SyncEntityResolution(
      originalSource: left.deleted ? SyncSource.left : SyncSource.right,
      originalDeleted: true,
      conflictSource: left.deleted ? SyncSource.right : SyncSource.left,
      conflictId: conflictId,
    );
  }

  final leftWins = leftDeviceId.compareTo(rightDeviceId) <= 0;
  return SyncEntityResolution(
    originalSource: leftWins ? SyncSource.left : SyncSource.right,
    originalDeleted: false,
    conflictSource: leftWins ? SyncSource.right : SyncSource.left,
    conflictId: conflictId,
  );
}

class SyncManifest {
  const SyncManifest({
    required this.notes,
    required this.folders,
    required this.noteTombstones,
    required this.folderTombstones,
  });

  final Map<String, SyncNoteVersion> notes;
  final Map<String, SyncFolderVersion> folders;
  final Set<String> noteTombstones;
  final Set<String> folderTombstones;

  String get fingerprint => syncHash({
    'notes': {
      for (final id in (notes.keys.toList()..sort())) id: notes[id]!.stateHash,
    },
    'folders': {
      for (final id in (folders.keys.toList()..sort()))
        id: folders[id]!.stateHash,
    },
    'noteTombstones': noteTombstones.toList()..sort(),
    'folderTombstones': folderTombstones.toList()..sort(),
  });

  factory SyncManifest.fromJson(Map<String, dynamic> json) {
    if (json['protocolVersion'] != syncProtocolVersion ||
        json['notes'] is! Map ||
        json['folders'] is! Map ||
        json['noteTombstones'] is! List ||
        json['folderTombstones'] is! List) {
      throw const FormatException('同步协议版本或清单格式不兼容');
    }
    final notes = <String, SyncNoteVersion>{};
    final folders = <String, SyncFolderVersion>{};
    for (final entry in (json['folders'] as Map).entries) {
      validateSyncId(entry.key);
      final data = entry.value;
      if (data is! Map ||
          data['id'] != entry.key ||
          data['name'] is! String ||
          (data['name'] as String).trim().isEmpty ||
          (data['name'] as String).length > 80) {
        throw const FormatException('同步文件夹无效');
      }
      final folder = SyncFolderVersion(
        id: entry.key as String,
        name: data['name'] as String,
      );
      if (folder.stateHash != data['stateHash']) {
        throw const FormatException('文件夹哈希无效');
      }
      folders[folder.id] = folder;
    }
    for (final entry in (json['notes'] as Map).entries) {
      validateSyncId(entry.key);
      final data = entry.value;
      if (data is! Map ||
          data['id'] != entry.key ||
          data['trashed'] is! bool ||
          data['contentHash'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['contentHash'] as String)) {
        throw const FormatException('同步笔记无效');
      }
      if (data['folderId'] != null) {
        validateSyncId(data['folderId']);
        if (!folders.containsKey(data['folderId'])) {
          throw const FormatException('笔记引用的文件夹不存在');
        }
      }
      final note = SyncNoteVersion(
        id: entry.key as String,
        contentHash: data['contentHash'] as String,
        trashed: data['trashed'] as bool,
        folderId: data['folderId'] as String?,
      );
      if (note.stateHash != data['stateHash']) {
        throw const FormatException('笔记状态哈希无效');
      }
      notes[note.id] = note;
    }
    Set<String> tombstones(String key, Set<String> live) {
      final list = json[key] as List;
      for (final id in list) {
        validateSyncId(id);
      }
      final result = list.cast<String>().toSet();
      if (result.length != list.length || result.any(live.contains)) {
        throw const FormatException('同步删除标记重复或与内容冲突');
      }
      return result;
    }

    final noteTombstones = tombstones('noteTombstones', notes.keys.toSet());
    final folderTombstones = tombstones(
      'folderTombstones',
      folders.keys.toSet(),
    );
    if (notes.length +
            folders.length +
            noteTombstones.length +
            folderTombstones.length >
        10000) {
      throw const FormatException('同步清单超过 10000 个条目');
    }
    return SyncManifest(
      notes: notes,
      folders: folders,
      noteTombstones: noteTombstones,
      folderTombstones: folderTombstones,
    );
  }

  Map<String, dynamic> toJson() => {
    'protocolVersion': syncProtocolVersion,
    'notes': notes.map((id, note) => MapEntry(id, note.toJson())),
    'folders': folders.map((id, folder) => MapEntry(id, folder.toJson())),
    'noteTombstones': noteTombstones.toList()..sort(),
    'folderTombstones': folderTombstones.toList()..sort(),
  };
}

void validateSyncId(Object? id) {
  if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id)) {
    throw const FormatException('同步条目 ID 无效');
  }
}

class SyncSnapshot {
  const SyncSnapshot(this.manifest, this.contents);
  final SyncManifest manifest;
  final Map<String, String> contents;

  void validate() {
    SyncManifest.fromJson(manifest.toJson());
    var size = 0;
    for (final note in manifest.notes.values) {
      final content = contents[note.id];
      if (content == null) throw const FormatException('缺少同步笔记正文');
      final bytes = utf8.encode(content);
      size += bytes.length;
      if (bytes.length > 2 * 1024 * 1024 || size > 32 * 1024 * 1024) {
        throw const FormatException('单篇笔记超过 2 MiB 或笔记总量超过 32 MiB，未截断内容');
      }
      if (sha256.convert(bytes).toString() != note.contentHash) {
        throw const FormatException('同步正文哈希不一致');
      }
    }
    if (contents.length != manifest.notes.length) {
      throw const FormatException('正文与同步清单不一致');
    }
  }
}

class SyncNoteMutation {
  const SyncNoteMutation.live({
    required this.id,
    required this.operationId,
    required this.content,
    required this.trashed,
    this.folderId,
    this.deletedAt,
  }) : permanentDelete = false;

  const SyncNoteMutation.delete({required this.id, required this.operationId})
    : permanentDelete = true,
      content = null,
      folderId = null,
      trashed = false,
      deletedAt = null;

  final String id;
  final String operationId;
  final String? content;
  final String? folderId;
  final bool trashed;
  final DateTime? deletedAt;
  final bool permanentDelete;
}

class SyncFolderMutation {
  const SyncFolderMutation.live({
    required this.id,
    required this.operationId,
    required this.name,
  }) : permanentDelete = false;

  const SyncFolderMutation.delete({required this.id, required this.operationId})
    : permanentDelete = true,
      name = null;

  final String id;
  final String operationId;
  final String? name;
  final bool permanentDelete;
}
