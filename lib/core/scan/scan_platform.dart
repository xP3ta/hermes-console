/// Platform edges of the document scanner: the camera/gallery pick, the
/// decoding of a photo into pixels and the isolate runner. All of it is local;
/// nothing here touches the network.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'scan_image_ops.dart';

enum ScanImageOrigin { camera, gallery }

/// Longest side kept when a photo is decoded for cropping.
const int kScanDecodeMaxSide = 2400;

Future<Uint8List?> pickScanImageFromPlatform(ScanImageOrigin origin) async {
  final picker = ImagePicker();
  if (origin == ScanImageOrigin.gallery) {
    final implementation = ImagePickerPlatform.instance;
    if (implementation is ImagePickerAndroid) {
      implementation.useAndroidPhotoPicker = true;
    }
  }
  final file = await picker.pickImage(
    source: origin == ScanImageOrigin.camera
        ? ImageSource.camera
        : ImageSource.gallery,
    imageQuality: 92,
    maxWidth: kScanDecodeMaxSide.toDouble(),
    maxHeight: kScanDecodeMaxSide.toDouble(),
  );
  return file?.readAsBytes();
}

/// Decodes an encoded photo into RGBA pixels, scaled down at decode time to
/// at most [kScanDecodeMaxSide] on the long side. `null` if it is not an image.
Future<ScanRgba?> decodeScanImage(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longSide = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;
    final scale = longSide > kScanDecodeMaxSide
        ? kScanDecodeMaxSide / longSide
        : 1.0;
    codec = await descriptor.instantiateCodec(
      targetWidth: scale < 1 ? (descriptor.width * scale).round() : null,
      targetHeight: scale < 1 ? (descriptor.height * scale).round() : null,
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return ScanRgba(
      image.width,
      image.height,
      Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      ),
    );
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Default runner: a short-lived isolate per job, so the warp and the filters
/// never block the UI thread.
Future<R> runScanOnIsolate<R>(FutureOr<R> Function() computation) =>
    Isolate.run(computation);

/// Runs the job right here. For tests and tiny images.
Future<R> runScanInline<R>(FutureOr<R> Function() computation) async =>
    computation();
