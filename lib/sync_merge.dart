import 'sync_models.dart';
import 'sync_planner.dart';

class SyncMerge {
  const SyncMerge(this.snapshot, this.conflicts);
  final SyncSnapshot snapshot;
  final int conflicts;
}

// Keep only baselines both devices confirmed. A lost acknowledgement must never
// make a newer edit look like an unchanged copy.
Map<String, String> commonSyncBaseline(
  Map<String, String> left,
  Map<String, String> right,
) => {
  for (final entry in left.entries)
    if (right[entry.key] == entry.value) entry.key: entry.value,
};

String _reserveConflictId({
  required String kind,
  required String baseId,
  required Set<String> reserved,
  required Set<String> generated,
  required bool canReuseExisting,
}) {
  if (!reserved.contains(baseId) ||
      (canReuseExisting && !generated.contains(baseId))) {
    reserved.add(baseId);
    generated.add(baseId);
    return baseId;
  }
  for (var attempt = 1; attempt <= 10000; attempt++) {
    final id =
        'conflict_${syncHash({'kind': kind, 'baseId': baseId, 'attempt': attempt}).substring(0, 40)}';
    if (reserved.add(id)) {
      generated.add(id);
      return id;
    }
  }
  throw const FormatException('无法为同步冲突分配安全的副本 ID');
}

bool _matchesGeneratedFolderName(String current, String original, String id) {
  if (current == original) return true;
  final marker = ' · ${syncHash(id).substring(0, 10)}';
  final markerIndex = current.lastIndexOf(marker);
  if (markerIndex < 0) return false;
  final suffix = current.substring(markerIndex);
  if (!RegExp('^${RegExp.escape(marker)}(?:-[2-9][0-9]*)?\$')
      .hasMatch(suffix)) {
    return false;
  }
  final maxPrefix = 80 - suffix.length;
  final prefix = original.substring(
    0,
    original.length > maxPrefix ? maxPrefix : original.length,
  );
  return current == '$prefix$suffix';
}

SyncMerge mergeSyncSnapshots({
  required String leftDeviceId,
  required String rightDeviceId,
  required SyncSnapshot left,
  required SyncSnapshot right,
  required Map<String, String> noteBaseline,
  required Map<String, String> folderBaseline,
}) {
  left.validate();
  right.validate();
  final plan = buildSyncPlan(
    leftDeviceId: leftDeviceId,
    rightDeviceId: rightDeviceId,
    left: left.manifest,
    right: right.manifest,
    noteBaseline: noteBaseline,
    folderBaseline: folderBaseline,
  );
  if (plan.hasInvalidEntries) throw const FormatException('同步条目与基线不一致，未覆盖任何内容');
  final folders = <String, SyncFolderVersion>{};
  final notes = <String, SyncNoteVersion>{};
  final contents = <String, String>{};
  final folderTombstones = <String>{};
  final noteTombstones = <String>{};
  final leftFolderIds = <String, String>{};
  final rightFolderIds = <String, String>{};
  final reservedFolderIds = <String>{
    ...left.manifest.folders.keys,
    ...right.manifest.folders.keys,
    ...left.manifest.folderTombstones,
    ...right.manifest.folderTombstones,
  };
  final generatedFolderIds = <String>{};
  final reservedNoteIds = <String>{
    ...left.manifest.notes.keys,
    ...right.manifest.notes.keys,
    ...left.manifest.noteTombstones,
    ...right.manifest.noteTombstones,
  };
  final generatedNoteIds = <String>{};
  SyncSnapshot source(SyncSource side) =>
      side == SyncSource.left ? left : right;
  Map<String, String> folderIds(SyncSource side) =>
      side == SyncSource.left ? leftFolderIds : rightFolderIds;

  bool folderConflictIsReplay(String id, String originalName) {
    if (left.manifest.folderTombstones.contains(id) ||
        right.manifest.folderTombstones.contains(id)) {
      return false;
    }
    final existing = <SyncFolderVersion>[
      ?left.manifest.folders[id],
      ?right.manifest.folders[id],
    ];
    return existing.isNotEmpty &&
        existing.every(
          (folder) =>
              _matchesGeneratedFolderName(folder.name, originalName, id),
        );
  }

  for (final entry in plan.folders.entries) {
    final result = entry.value;
    final side = result.originalSource;
    if (side == null) continue;
    if (result.originalDeleted) {
      folderTombstones.add(entry.key);
    } else {
      folders[entry.key] = source(side).manifest.folders[entry.key]!;
      leftFolderIds[entry.key] = entry.key;
      rightFolderIds[entry.key] = entry.key;
    }
    final conflict = result.conflictSource;
    if (conflict != null) {
      final original = source(conflict).manifest.folders[entry.key]!;
      final baseId = result.conflictId!;
      final id = _reserveConflictId(
        kind: 'folder',
        baseId: baseId,
        reserved: reservedFolderIds,
        generated: generatedFolderIds,
        canReuseExisting: folderConflictIsReplay(baseId, original.name),
      );
      folders[id] = SyncFolderVersion(id: id, name: original.name);
      folderIds(conflict)[entry.key] = id;
    }
  }
  // Distinct folder IDs with equal names stay distinct and get a stable suffix.
  final usedNames = <String>{};
  for (final id in folders.keys.toList()..sort()) {
    final folder = folders[id]!;
    var name = folder.name;
    if (usedNames.contains(name)) {
      final suffix = ' · ${syncHash(id).substring(0, 10)}';
      name =
          '${name.substring(0, name.length > 80 - suffix.length ? 80 - suffix.length : name.length)}$suffix';
      var index = 2;
      while (usedNames.contains(name)) {
        final suffix = ' · ${syncHash(id).substring(0, 10)}-$index';
        name =
            '${folder.name.substring(0, folder.name.length > 80 - suffix.length ? 80 - suffix.length : folder.name.length)}$suffix';
        index++;
      }
    }
    usedNames.add(name);
    folders[id] = SyncFolderVersion(id: id, name: name);
  }
  SyncNoteVersion noteVersion(String oldId, String id, SyncSource side) {
    final snapshot = source(side);
    final original = snapshot.manifest.notes[oldId]!;
    final folderId = folderIds(side)[original.folderId];
    return SyncNoteVersion(
      id: id,
      contentHash: original.contentHash,
      trashed: original.trashed,
      folderId: folderId,
    );
  }

  void addNote(String oldId, String id, SyncSource side) {
    final snapshot = source(side);
    final next = noteVersion(oldId, id, side);
    final content = snapshot.contents[oldId]!;
    final previous = notes[id];
    if (previous != null &&
        (previous.contentHash != next.contentHash ||
            previous.trashed != next.trashed ||
            previous.folderId != next.folderId ||
            contents[id] != content)) {
      throw const FormatException('同步冲突副本 ID 与现有笔记冲突，未覆盖任何内容');
    }
    notes[id] = next;
    // Preserve exact Markdown, including task positions. Conflict IDs remain
    // stable across retries; the UI can identify copies by their ID.
    contents[id] = content;
  }

  bool noteConflictIsReplay(
    String id,
    SyncNoteVersion desired,
    String desiredContent,
  ) {
    if (left.manifest.noteTombstones.contains(id) ||
        right.manifest.noteTombstones.contains(id)) {
      return false;
    }
    var found = false;
    for (final pair in [
      (snapshot: left, folderMap: leftFolderIds),
      (snapshot: right, folderMap: rightFolderIds),
    ]) {
      final existing = pair.snapshot.manifest.notes[id];
      if (existing == null) continue;
      found = true;
      final mappedFolder = pair.folderMap[existing.folderId];
      if (existing.contentHash != desired.contentHash ||
          existing.trashed != desired.trashed ||
          mappedFolder != desired.folderId ||
          pair.snapshot.contents[id] != desiredContent) {
        return false;
      }
    }
    return found;
  }

  for (final entry in plan.notes.entries) {
    final result = entry.value;
    final side = result.originalSource;
    if (side == null) continue;
    if (result.originalDeleted) {
      noteTombstones.add(entry.key);
    } else {
      addNote(entry.key, entry.key, side);
    }
    final conflict = result.conflictSource;
    if (conflict != null) {
      final baseId = result.conflictId!;
      final desired = noteVersion(entry.key, baseId, conflict);
      final desiredContent = source(conflict).contents[entry.key]!;
      final id = _reserveConflictId(
        kind: 'note',
        baseId: baseId,
        reserved: reservedNoteIds,
        generated: generatedNoteIds,
        canReuseExisting: noteConflictIsReplay(baseId, desired, desiredContent),
      );
      addNote(entry.key, id, conflict);
    }
  }
  final target = SyncSnapshot(
    SyncManifest(
      notes: notes,
      folders: folders,
      noteTombstones: noteTombstones,
      folderTombstones: folderTombstones,
    ),
    contents,
  );
  target.validate();
  return SyncMerge(target, plan.conflictCount);
}

Map<String, String> syncBaselineHashes(SyncManifest manifest, String kind) =>
    kind == 'notes'
    ? {
        for (final entry in manifest.notes.entries)
          entry.key: entry.value.stateHash,
        for (final id in manifest.noteTombstones)
          id: syncTombstoneHash('note', id),
      }
    : {
        for (final entry in manifest.folders.entries)
          entry.key: entry.value.stateHash,
        for (final id in manifest.folderTombstones)
          id: syncTombstoneHash('folder', id),
      };
