import 'sync_models.dart';

class SyncPlan {
  const SyncPlan({required this.notes, required this.folders});

  final Map<String, SyncEntityResolution> notes;
  final Map<String, SyncEntityResolution> folders;

  bool get hasInvalidEntries =>
      notes.values.any((entry) => entry.isInvalid) ||
      folders.values.any((entry) => entry.isInvalid);

  int get conflictCount =>
      notes.values.where((entry) => entry.isConflict).length +
      folders.values.where((entry) => entry.isConflict).length;
}

SyncPlan buildSyncPlan({
  required String leftDeviceId,
  required String rightDeviceId,
  required SyncManifest left,
  required SyncManifest right,
  Map<String, String> noteBaseline = const {},
  Map<String, String> folderBaseline = const {},
}) {
  return SyncPlan(
    notes: _resolveGroup(
      kind: 'note',
      leftDeviceId: leftDeviceId,
      rightDeviceId: rightDeviceId,
      leftLive: left.notes.map(
        (id, note) => MapEntry(
          id,
          SyncEntityState.live(id: id, stateHash: note.stateHash),
        ),
      ),
      rightLive: right.notes.map(
        (id, note) => MapEntry(
          id,
          SyncEntityState.live(id: id, stateHash: note.stateHash),
        ),
      ),
      leftTombstones: left.noteTombstones,
      rightTombstones: right.noteTombstones,
      baseline: noteBaseline,
    ),
    folders: _resolveGroup(
      kind: 'folder',
      leftDeviceId: leftDeviceId,
      rightDeviceId: rightDeviceId,
      leftLive: left.folders.map(
        (id, folder) => MapEntry(
          id,
          SyncEntityState.live(id: id, stateHash: folder.stateHash),
        ),
      ),
      rightLive: right.folders.map(
        (id, folder) => MapEntry(
          id,
          SyncEntityState.live(id: id, stateHash: folder.stateHash),
        ),
      ),
      leftTombstones: left.folderTombstones,
      rightTombstones: right.folderTombstones,
      baseline: folderBaseline,
    ),
  );
}

Map<String, SyncEntityResolution> _resolveGroup({
  required String kind,
  required String leftDeviceId,
  required String rightDeviceId,
  required Map<String, SyncEntityState> leftLive,
  required Map<String, SyncEntityState> rightLive,
  required Set<String> leftTombstones,
  required Set<String> rightTombstones,
  required Map<String, String> baseline,
}) {
  final ids = <String>{
    ...leftLive.keys,
    ...rightLive.keys,
    ...leftTombstones,
    ...rightTombstones,
    ...baseline.keys,
  }.toList()..sort();

  return {
    for (final id in ids)
      id: _resolveOne(
        kind: kind,
        id: id,
        leftDeviceId: leftDeviceId,
        rightDeviceId: rightDeviceId,
        leftLive: leftLive,
        rightLive: rightLive,
        leftTombstones: leftTombstones,
        rightTombstones: rightTombstones,
        baseline: baseline[id],
      ),
  };
}

SyncEntityResolution _resolveOne({
  required String kind,
  required String id,
  required String leftDeviceId,
  required String rightDeviceId,
  required Map<String, SyncEntityState> leftLive,
  required Map<String, SyncEntityState> rightLive,
  required Set<String> leftTombstones,
  required Set<String> rightTombstones,
  String? baseline,
}) {
  if (leftLive.containsKey(id) && leftTombstones.contains(id)) {
    return const SyncEntityResolution(invalidReason: '左侧条目同时存在内容和删除标记');
  }
  if (rightLive.containsKey(id) && rightTombstones.contains(id)) {
    return const SyncEntityResolution(invalidReason: '右侧条目同时存在内容和删除标记');
  }

  final left = leftTombstones.contains(id)
      ? SyncEntityState.tombstone(kind: kind, id: id)
      : leftLive[id];
  final right = rightTombstones.contains(id)
      ? SyncEntityState.tombstone(kind: kind, id: id)
      : rightLive[id];

  return resolveSyncEntity(
    kind: kind,
    entityId: id,
    leftDeviceId: leftDeviceId,
    rightDeviceId: rightDeviceId,
    left: left,
    right: right,
    baselineHash: baseline,
  );
}
