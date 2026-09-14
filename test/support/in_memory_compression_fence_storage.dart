import 'package:hermes_android/core/services/desktop_compression_fence_store.dart';

final class InMemoryDesktopCompressionFenceStorage
    implements DesktopCompressionFenceStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

DesktopCompressionFenceStore testCompressionFenceStore() =>
    DesktopCompressionFenceStore(
      storage: InMemoryDesktopCompressionFenceStorage(),
    );
