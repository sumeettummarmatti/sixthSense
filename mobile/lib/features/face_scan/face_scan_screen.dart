import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/device_identity.dart';

/// A captured selfie: its bytes and how many faces the phone found in it.
class FaceScanCapture {
  const FaceScanCapture({required this.image, required this.faces});

  final VerificationImage image;
  final int faces;
}

/// Takes a front-camera photo and counts faces on the phone. Null = cancelled.
typedef FaceScanCamera = Future<FaceScanCapture?> Function();

/// Sends the scan to the server together with the action it unlocks (accept a walk,
/// "I'm going"). Returns null when done, or a message to show so the person can retry.
typedef FaceScanSubmit = Future<String?> Function(VerificationImage scan);

/// Fresh face scan before a companion or responder receives someone's location.
///
/// Separate from identity verification (done once with ID + selfie): this checks that the person
/// holding the phone right now is the verified account holder. The phone checks that exactly one
/// face is in front of the camera (ML Kit, on-device); the server checks the scan in the same
/// request as the action, so it cannot be skipped. The photo is never saved.
///
/// Pops `true` once [submit] succeeds.
class FaceScanScreen extends StatefulWidget {
  const FaceScanScreen({
    super.key,
    required this.title,
    required this.reason,
    required this.actionLabel,
    required this.submit,
    this.camera,
  });

  /// Opens the scan and returns whether it passed.
  static Future<bool> open(
    BuildContext context, {
    required String title,
    required String reason,
    required String actionLabel,
    required FaceScanSubmit submit,
    FaceScanCamera? camera,
  }) async {
    final passed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => FaceScanScreen(
          title: title,
          reason: reason,
          actionLabel: actionLabel,
          submit: submit,
          camera: camera,
        ),
      ),
    );
    return passed ?? false;
  }

  final String title;
  final String reason;
  final String actionLabel;
  final FaceScanSubmit submit;
  final FaceScanCamera? camera;

  @override
  State<FaceScanScreen> createState() => _FaceScanScreenState();
}

enum _Stage { ready, capturing, checking }

class _FaceScanScreenState extends State<FaceScanScreen> {
  _Stage _stage = _Stage.ready;
  String? _message;

  Future<void> _scan() async {
    setState(() {
      _stage = _Stage.capturing;
      _message = null;
    });
    FaceScanCapture? capture;
    try {
      capture = await (widget.camera ?? captureAndCountFaces)();
    } on PlatformException catch (error) {
      _fail(error.message ?? 'The camera could not take a photo.');
      return;
    } catch (_) {
      _fail('The camera could not take a photo. Try again.');
      return;
    }
    if (!mounted) return;
    if (capture == null) {
      setState(() => _stage = _Stage.ready);
      return;
    }
    if (capture.faces == 0) {
      _fail(
        'We could not see a face. Hold the phone at eye level in good light and try again.',
      );
      return;
    }
    if (capture.faces > 1) {
      _fail('Only you should be in the photo. Try again with just your face.');
      return;
    }
    setState(() => _stage = _Stage.checking);
    String? problem;
    try {
      problem = await widget.submit(capture.image);
    } catch (_) {
      problem = 'Could not reach the server. Try again.';
    }
    if (!mounted) return;
    if (problem == null) {
      Navigator.of(context).pop(true);
    } else {
      _fail(problem);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _stage = _Stage.ready;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final busy = _stage != _Stage.ready;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          children: [
            Center(
              child: Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.primaryContainer,
                  border: Border.all(color: colors.primary, width: 3),
                ),
                child: busy
                    ? Padding(
                        padding: const EdgeInsets.all(36),
                        child: CircularProgressIndicator(
                          key: const ValueKey('face-scan-progress'),
                          color: colors.primary,
                        ),
                      )
                    : Icon(
                        Icons.face_retouching_natural_rounded,
                        size: 64,
                        color: colors.onPrimaryContainer,
                      ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _stage == _Stage.checking
                  ? 'Confirming it\'s you…'
                  : 'Confirm it\'s you',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              widget.reason,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'Take a quick selfie with the front camera. It is checked and then '
                'discarded: never saved on the phone or the server. This confirms '
                'the verified person is holding the phone; it is not a liveness check.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(
                _message!,
                key: const ValueKey('face-scan-message'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.error,
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const ValueKey('face-scan-start'),
              onPressed: busy ? null : _scan,
              icon: const Icon(Icons.photo_camera_front_rounded),
              label: Text(_message == null ? 'Scan my face' : 'Try again'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: busy ? null : () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            const SizedBox(height: 8),
            Text(
              'Scanning will ${widget.actionLabel}.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Front-camera photo, faces counted on the phone, temporary file deleted.
Future<FaceScanCapture?> captureAndCountFaces() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.camera,
    preferredCameraDevice: CameraDevice.front,
    maxWidth: 1280,
    imageQuality: 85,
  );
  if (file == null) return null;
  try {
    final bytes = await file.readAsBytes();
    final faces = await _countFaces(file.path);
    return FaceScanCapture(
      image: VerificationImage(bytes: bytes, mimeType: _mimeTypeOf(file)),
      faces: faces,
    );
  } finally {
    try {
      await File(file.path).delete();
    } on FileSystemException {
      // Best effort: the scan itself is still valid.
    }
  }
}

Future<int> _countFaces(String path) async {
  if (defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.iOS) {
    return 1; // ML Kit runs on phones only.
  }
  final detector = FaceDetector(
    options: FaceDetectorOptions(performanceMode: FaceDetectorMode.fast),
  );
  try {
    return (await detector.processImage(InputImage.fromFilePath(path))).length;
  } finally {
    await detector.close();
  }
}

String _mimeTypeOf(XFile file) {
  final declared = (file.mimeType ?? '').toLowerCase();
  if (declared == 'image/png' || declared == 'image/webp') return declared;
  final path = file.path.toLowerCase();
  if (path.endsWith('.png')) return 'image/png';
  if (path.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

/// Plain-language message for the face-scan errors the server can return, or null.
String? faceScanProblem(ApiException error) => switch (error.detail) {
  'face_mismatch' => 'This face did not match the verified account holder. Only the verified person can continue.',
  'face_image_invalid' ||
  'empty_image' => 'Use a clear photo of just your face.',
  'image_too_large' => 'That photo is too large. Try again.',
  'unsupported_image_type' => 'That photo format is not supported. Try again.',
  'face_scan_required' => 'A face scan is needed. Try again.',
  'face_template_not_enrolled' => 'The face check needs your saved face reference. Turn it on in identity verification first.',
  'face_template_model_changed' => 'Your saved face reference is out of date. Save it again in identity verification.',
  _ when error.statusCode == 503 =>
    'The face check is unavailable right now. Try again in a moment.',
  _ => null,
};
