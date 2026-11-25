import 'dart:io';

import 'package:flutter/foundation.dart';

import 'library_state.dart';
import 'network_status.dart';

/// Stable page identities: changing dock membership never renumbers the pages
/// or disposes their reading/search/scroll state.
class HomeNavigation extends ChangeNotifier {
  HomeNavigation(this.preferences, this.network) {
    preferences.navigationChanges.addListener(_changed);
    network?.addListener(_changed);
    _value = _read();
  }

  final LibraryState preferences;
  final NetworkStatus? network;
  late ({bool localReader, bool cachedShelf, bool combinedShelf}) _value;

  ({bool localReader, bool cachedShelf, bool combinedShelf}) _read() => (
    localReader: preferences.localReaderMode,
    cachedShelf: preferences.adaptWhenOffline && (network?.offline ?? false),
    combinedShelf: preferences.combinedShelf,
  );

  bool get cachedShelf => _value.cachedShelf;
  bool get localReader => _value.localReader;
  bool get combinedShelf => _value.combinedShelf;
  bool get readableShelfOnly => cachedShelf || localReader;
  /// iPhone 定制版：只保留两页——本地书库（显示为「书架」）与「我的」。
  /// 在线书架和发现页都不出现；本地书库页面编号仍是 2，避免改动页面身份。
  static const _iphoneTabs = [2, 3];

  List<int> get tabs {
    if (Platform.isIOS) return _iphoneTabs;
    if (localReader) return combinedShelf ? const [1, 3] : const [2, 3];
    if (combinedShelf) return cachedShelf ? const [1, 3] : const [0, 1, 3];
    return cachedShelf ? const [1, 2, 3] : const [0, 1, 2, 3];
  }

  int destination(int current) {
    if (Platform.isIOS) {
      return _iphoneTabs.contains(current) ? current : _iphoneTabs.first;
    }
    return tabs.contains(current)
        ? current
        : localReader
        ? combinedShelf
              ? 1
              : 2
        : 1;
  }

  void _changed() {
    final next = _read();
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    preferences.navigationChanges.removeListener(_changed);
    network?.removeListener(_changed);
    super.dispose();
  }
}
