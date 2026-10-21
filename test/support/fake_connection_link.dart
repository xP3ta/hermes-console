import 'package:flutter/foundation.dart';
import 'package:hermes_android/core/services/connection_status.dart';

/// A socket the connection status registry can be driven with.
final class FakeConnectionLink implements ConnectionLinkSource {
  final ConnectionSignal signal = ConnectionSignal();
  @override
  bool isConnected = false;
  @override
  bool isClosed = false;
  @override
  bool linkAuthRejected = false;
  @override
  DateTime? linkReconnectAt;
  @override
  int linkReconnectAttempt = 0;
  @override
  bool linkParked = false;

  @override
  Listenable get linkListenable => signal;

  void change(void Function() edit) {
    edit();
    signal.notify();
  }
}
