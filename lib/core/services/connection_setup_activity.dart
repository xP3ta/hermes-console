import 'package:flutter/foundation.dart';

/// An in-memory scope for connection screens, including re-entry from Home.
/// Nothing unrelated should interrupt a scan or a sign-in with a permission.
class ConnectionSetupActivity extends ChangeNotifier {
  ConnectionSetupActivity._();
  static final instance = ConnectionSetupActivity._();
  int _screens = 0;
  bool get active => _screens > 0;

  VoidCallback hold() {
    _screens++;
    notifyListeners();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _screens--;
      notifyListeners();
    };
  }
}
