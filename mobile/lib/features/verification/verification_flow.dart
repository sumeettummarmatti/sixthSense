import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/device_identity.dart';
import 'id_field_ocr.dart';

/// Consent-first mock identity check for people applying to respond nearby.
class VerificationFlowScreen extends StatefulWidget {
  const VerificationFlowScreen({
    super.key,
    required this.api,
    this.pickPhoto,
    this.idOcr,
  });

  final DemoApi api;
  final Future<VerificationImage?> Function(ImageSource source)? pickPhoto;
  final OnDeviceIdOcr? idOcr;

  @override
  State<VerificationFlowScreen> createState() => _VerificationFlowScreenState();
}

class _VerificationFlowScreenState extends State<VerificationFlowScreen>
    with WidgetsBindingObserver {
  static const _sessionKey = 'verification_session_id';
  static const _maxImageBytes = 5 * 1024 * 1024;
  static const _scenarios = [
    'approve',
    'reject_doc',
    'reject_face',
    'liveness_fail',
    'underage',
    'provider_error',
  ];

  late final _idOcr = widget.idOcr ?? OnDeviceIdOcr();
  final _idNumber = TextEditingController();
  final _dateOfBirth = TextEditingController();
  var _stage = _VerificationStage.loading;
  var _consent = false;
  var _faceTemplateConsent = false;
  var _faceTemplateEnabled = false;
  var _faceTemplateBusy = false;
  var _busy = false;
  var _idType = 'drivers_license';
  var _scenario = 'approve';
  String? _sessionId;
  String? _status;
  String? _reason;
  String? _error;
  var _retryComparisonAvailable = false;
  var _pickingIdPhoto = false;
  var _readingIdFields = false;
  var _confirmDetails = false;
  VerificationImage? _idPhoto;
  VerificationImage? _selfiePhoto;
  String? _lastOcrIdNumber;
  String? _lastOcrDateOfBirth;
  String? _ocrMessage;

  bool get _validIdDetails {
    final dobText = _dateOfBirth.text.trim();
    final dob = DateTime.tryParse(dobText);
    return _idNumber.text.trim().isNotEmpty &&
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dobText) &&
        dob != null &&
        dob.toIso8601String().substring(0, 10) == dobText &&
        dob.isBefore(DateTime.now().add(const Duration(days: 1)));
  }

  bool get _canContinueToSelfie => _validIdDetails && _idPhoto != null;

  bool get _canCompareFaces =>
      _sessionId != null &&
      _validIdDetails &&
      _idPhoto != null &&
      _selfiePhoto != null &&
      !_busy;

  bool get _canConfirmAndCompare => _canCompareFaces && _confirmDetails;

  bool get _idNumberIsSuggestion =>
      _lastOcrIdNumber != null && _idNumber.text.trim() == _lastOcrIdNumber;

  bool get _dateOfBirthIsSuggestion =>
      _lastOcrDateOfBirth != null &&
      _dateOfBirth.text.trim() == _lastOcrDateOfBirth;

  void _onIdNumberChanged(String _) => setState(() {
    _lastOcrIdNumber = null;
    _confirmDetails = false;
    _error = null;
  });

  void _onDateOfBirthChanged(String _) => setState(() {
    _lastOcrDateOfBirth = null;
    _confirmDetails = false;
    _error = null;
  });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idNumber.dispose();
    _dateOfBirth.dispose();
    super.dispose();
  }

  Future<VerificationImage?> _choosePhoto(ImageSource source) async {
    final picker = widget.pickPhoto;
    if (picker != null) {
      final photo = await picker(source);
      return photo == null ? null : _validatedPhoto(photo);
    }
    final file = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
      preferredCameraDevice: source == ImageSource.camera
          ? CameraDevice.front
          : CameraDevice.rear,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    try {
      await File(file.path).delete();
    } on FileSystemException {
      // Picker files are temporary; a cleanup failure must not discard the capture.
    }
    return _validatedPhoto(
      VerificationImage(bytes: bytes, mimeType: file.mimeType ?? ''),
      path: file.path,
    );
  }

  VerificationImage _validatedPhoto(VerificationImage photo, {String? path}) {
    if (photo.bytes.isEmpty) {
      throw const _PhotoSelectionException('The selected image is empty.');
    }
    if (photo.bytes.length > _maxImageBytes) {
      throw const _PhotoSelectionException(
        'Choose an image that is 5 MB or smaller.',
      );
    }
    final mimeType = _supportedImageMimeType(photo.mimeType, path);
    if (mimeType == null) {
      throw const _PhotoSelectionException('Choose a JPG, PNG, or WebP image.');
    }
    return VerificationImage(bytes: photo.bytes, mimeType: mimeType);
  }

  Future<void> _pickIdPhoto() async {
    var selectedPhoto = false;
    setState(() => _pickingIdPhoto = true);
    try {
      final photo = await _choosePhoto(ImageSource.gallery);
      if (photo == null) return;
      selectedPhoto = true;
      if (mounted) {
        setState(() {
          _pickingIdPhoto = false;
          _readingIdFields = true;
          _ocrMessage = null;
          _error = null;
          if (_idNumber.text.trim() == _lastOcrIdNumber) _idNumber.clear();
          if (_dateOfBirth.text.trim() == _lastOcrDateOfBirth) {
            _dateOfBirth.clear();
          }
          _lastOcrIdNumber = null;
          _lastOcrDateOfBirth = null;
          _idPhoto = photo;
          _confirmDetails = false;
        });
      }
      final fields = await _idOcr.readFields(photo, idType: _idType);
      if (!mounted) return;
      setState(() {
        if (_idNumber.text.trim().isEmpty && fields.idNumber != null) {
          _idNumber.text = fields.idNumber!;
          _lastOcrIdNumber = fields.idNumber;
        }
        if (_dateOfBirth.text.trim().isEmpty && fields.dateOfBirth != null) {
          _dateOfBirth.text = fields.dateOfBirth!;
          _lastOcrDateOfBirth = fields.dateOfBirth;
        }
        _ocrMessage = fields.isEmpty
            ? 'Could not read those fields from the photo. Enter them manually.'
            : 'Read available ID details on this device. Check the fields below.';
        _confirmDetails = false;
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is _PhotoSelectionException
              ? error.message
              : selectedPhoto
              ? 'Could not read the ID photo on this device. Enter the details manually.'
              : 'Could not open the photo picker.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _pickingIdPhoto = false;
          _readingIdFields = false;
        });
      }
    }
  }

  void _selectIdType(String idType) {
    setState(() {
      if (_idNumber.text.trim() == _lastOcrIdNumber) _idNumber.clear();
      _lastOcrIdNumber = null;
      _idType = idType;
      _confirmDetails = false;
    });
  }

  Future<void> _takeSelfie() async {
    try {
      final photo = await _choosePhoto(ImageSource.camera);
      if (mounted && photo != null) {
        setState(() {
          _selfiePhoto = photo;
          _confirmDetails = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = _photoErrorMessage(
            error,
            'Could not open the selfie camera.',
          ),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _sessionId != null) {
      unawaited(_refreshSession());
    }
  }

  Future<void> _restoreStatus() async {
    try {
      final me = await widget.api.verificationMe();
      if (!mounted) return;
      _faceTemplateEnabled = me['face_template_enabled'] == true;
      final id = me['session_id'] as String?;
      if (me['status'] == 'verified') {
        setState(() {
          _status = 'verified';
          _stage = _VerificationStage.result;
        });
        return;
      }
      if (id != null && id.isNotEmpty) {
        _sessionId = id;
        await widget.api.identity.saveValue(_sessionKey, id);
        final latest = await widget.api.verificationSession(id);
        if (!mounted) return;
        _showStatus(latest);
        return;
      }
    } catch (_) {
      // The consent screen can still explain the flow when verification is offline.
    }
    if (mounted) setState(() => _stage = _VerificationStage.consent);
  }

  Future<void> _startSession() async {
    if (!_consent || _busy) return;
    setState(() => _busy = true);
    try {
      final response = await widget.api.createVerificationSession(
        consent: _consent,
        faceTemplateConsent: _faceTemplateConsent,
      );
      _sessionId = response['id'] as String;
      _status = response['status'] as String? ?? 'not_submitted';
      await widget.api.identity.saveValue(_sessionKey, _sessionId);
      if (mounted) setState(() => _stage = _VerificationStage.idType);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not start verification (${error.detail}).';
          _stage = _VerificationStage.error;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not reach the verification service.';
          _stage = _VerificationStage.error;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshSession() async {
    final id = _sessionId;
    if (id == null || _busy) return;
    try {
      final response = await widget.api.verificationSession(id);
      if (mounted) _showStatus(response);
    } catch (_) {
      // Keep the saved session ID; refresh again on the next resume.
    }
  }

  Future<void> _submitVerification() async {
    final id = _sessionId;
    final dob = DateTime.tryParse(_dateOfBirth.text.trim());
    if (id == null) return;
    if (_idPhoto == null || _selfiePhoto == null) {
      setState(() => _error = 'Add an ID photo and take a selfie first.');
      return;
    }
    if (_idNumber.text.trim().isEmpty || dob == null) {
      setState(
        () => _error = 'Enter a sample ID number and date as YYYY-MM-DD.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _retryComparisonAvailable = false;
    });
    try {
      final result = await widget.api.submitVerificationSelfie(
        sessionId: id,
        idType: _idType,
        idNumber: _idNumber.text.trim(),
        dateOfBirth: dob.toIso8601String().substring(0, 10),
        idImage: _idPhoto!,
        selfieImage: _selfiePhoto!,
        scenario: kDebugMode ? _scenario : null,
      );
      _showStatus(result);
      if (result['status'] == 'verified') {
        unawaited(_refreshFaceTemplateStatus());
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          if (error.detail == 'verification_session_not_pending') {
            _status = 'expired';
            _reason = 'session_expired';
            _error = null;
            _retryComparisonAvailable = false;
            _confirmDetails = false;
            _stage = _VerificationStage.result;
            return;
          }
          if (error.detail == 'face_image_invalid') {
            _retryComparisonAvailable = false;
            _confirmDetails = false;
            _selfiePhoto = null;
            _error = 'Use one clear face in each photo. Retake the selfie, or go back and replace the ID portrait.';
            _stage = _VerificationStage.selfie;
            return;
          }
          _retryComparisonAvailable =
              error.detail == 'face_match_unavailable' || error.statusCode == 0;
          _error = switch (error.detail) {
            'duplicate' =>
              'This identity was already used for another account.',
            'face_mismatch' =>
              'The ID photo and selfie did not match closely enough.',
            'face_match_unavailable' =>
              'The local face matcher is unavailable. Try again later.',
            _ => 'The face match could not finish (${error.detail}).',
          };
          _stage = _VerificationStage.error;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _retryComparisonAvailable = true;
          _error =
              'The face matcher could not be reached. Check the local server.';
          _stage = _VerificationStage.error;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryComparison() async {
    final id = _sessionId;
    if (id == null || _busy || !_canCompareFaces) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final latest = await widget.api.verificationSession(id);
      if (!mounted) return;
      if (latest['status'] != 'not_submitted') {
        _showStatus(latest);
        return;
      }
      setState(() {
        _stage = _VerificationStage.selfie;
        _busy = false;
      });
      await _submitVerification();
    } catch (_) {
      if (mounted) {
        setState(() {
          _retryComparisonAvailable = true;
          _error =
              'Could not check the session. Check the connection and retry.';
          _stage = _VerificationStage.error;
        });
      }
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<void> _retryFaceMismatch() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await widget.api.createVerificationSession(
        consent: true,
        faceTemplateConsent: _faceTemplateConsent,
      );
      _sessionId = response['id'] as String;
      _status = response['status'] as String? ?? 'not_submitted';
      _reason = null;
      _selfiePhoto = null;
      _retryComparisonAvailable = false;
      _confirmDetails = false;
      await widget.api.identity.saveValue(_sessionKey, _sessionId);
      if (mounted) setState(() => _stage = _VerificationStage.selfie);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not start a new face check (${error.detail}).';
          _stage = _VerificationStage.error;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not reach the verification service. Try again.';
          _stage = _VerificationStage.error;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showStatus(Map<String, dynamic> status) {
    _status = status['status'] as String? ?? 'error';
    _reason = status['reason_code'] as String?;
    _stage = switch (_status) {
      'not_submitted' =>
        _stage == _VerificationStage.loading
            ? _VerificationStage.idType
            : _stage,
      'pending' => _VerificationStage.pending,
      'verified' ||
      'rejected' ||
      'underage' ||
      'expired' ||
      'error' => _VerificationStage.result,
      _ => _VerificationStage.error,
    };
    setState(() {});
  }

  Future<void> _refreshFaceTemplateStatus() async {
    try {
      final me = await widget.api.verificationMe();
      if (mounted) {
        setState(
          () => _faceTemplateEnabled = me['face_template_enabled'] == true,
        );
      }
    } catch (_) {
      // Status remains informational; the server remains authoritative on each walk check.
    }
  }

  Future<void> _deleteFaceTemplate() async {
    setState(() => _faceTemplateBusy = true);
    try {
      await widget.api.deleteFaceTemplate();
      if (mounted) {
        setState(() {
          _faceTemplateEnabled = false;
          _faceTemplateConsent = false;
          _idPhoto = null;
          _selfiePhoto = null;
        });
      }
    } on ApiException catch (error) {
      if (mounted) {
        _showMessage(
          'Could not delete the saved face reference (${error.detail}).',
        );
      }
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Could not reach the server to delete the saved face reference.',
        );
      }
    } finally {
      if (mounted) setState(() => _faceTemplateBusy = false);
    }
  }

  Future<void> _pickTemplateIdPhoto() async {
    try {
      final photo = await _choosePhoto(ImageSource.gallery);
      if (mounted && photo != null) setState(() => _idPhoto = photo);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = _photoErrorMessage(
            error,
            'Could not load the ID portrait.',
          ),
        );
      }
    }
  }

  Future<void> _takeTemplateSelfie() async {
    try {
      final photo = await _choosePhoto(ImageSource.camera);
      if (mounted && photo != null) setState(() => _selfiePhoto = photo);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = _photoErrorMessage(
            error,
            'Could not capture the selfie.',
          ),
        );
      }
    }
  }

  Future<void> _enrollFaceTemplate() async {
    final idImage = _idPhoto;
    final selfie = _selfiePhoto;
    if (!_faceTemplateConsent ||
        idImage == null ||
        selfie == null ||
        _faceTemplateBusy) {
      return;
    }
    setState(() {
      _faceTemplateBusy = true;
      _error = null;
    });
    try {
      await widget.api.enrollFaceTemplate(
        idImage: idImage,
        selfieImage: selfie,
      );
      if (mounted) {
        setState(() {
          _faceTemplateEnabled = true;
          _idPhoto = null;
          _selfiePhoto = null;
        });
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = switch (error.detail) {
            'face_mismatch' => 'The ID portrait and selfie did not match. Check both photos and try again.',
            'face_image_invalid' => 'Use one clear face in each photo.',
            _ => 'Could not save the face reference (${error.detail}).',
          };
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not reach the face matcher. Try again later.',
        );
      }
    } finally {
      if (mounted) setState(() => _faceTemplateBusy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _newAttempt() async {
    await widget.api.identity.saveValue(_sessionKey, null);
    if (!mounted) return;
    setState(() {
      _sessionId = null;
      _status = null;
      _reason = null;
      _error = null;
      _retryComparisonAvailable = false;
      _confirmDetails = false;
      _consent = false;
      _idNumber.clear();
      _dateOfBirth.clear();
      _idPhoto = null;
      _selfiePhoto = null;
      _stage = _VerificationStage.consent;
    });
  }

  void _finish(bool verified) => Navigator.of(context).pop(verified);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Responder verification')),
      body: SafeArea(
        child: Column(
          children: [
            const SimulatedBanner(),
            Expanded(
              child: _stage == _VerificationStage.loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      key: ValueKey('verification-screen-${_stage.name}'),
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
                      children: [
                        _progressLabel(),
                        const SizedBox(height: 18),
                        _processStages(),
                        const SizedBox(height: 18),
                        ..._stageContent(),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressLabel() {
    final step = switch (_stage) {
      _VerificationStage.consent => 1,
      _VerificationStage.idType => 2,
      _VerificationStage.document => 3,
      _VerificationStage.selfie => 4,
      _VerificationStage.review => 5,
      _ => null,
    };
    if (step == null) return const SizedBox.shrink();
    return Row(
      children: [
        Expanded(
          child: LinearProgressIndicator(
            value: step / 5,
            minHeight: 6,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(width: 12),
        Text('$step of 5'),
      ],
    );
  }

  List<Widget> _stageContent() => switch (_stage) {
    _VerificationStage.consent => _consentContent(),
    _VerificationStage.idType => _idTypeContent(),
    _VerificationStage.document => _documentContent(),
    _VerificationStage.selfie => _selfieContent(),
    _VerificationStage.review => _reviewContent(),
    _VerificationStage.pending => _pendingContent(),
    _VerificationStage.result => _resultContent(),
    _VerificationStage.error => _errorContent(),
    _VerificationStage.loading => const [],
  };

  Widget _processStages() {
    final faceStatus = switch (_status) {
      'verified' => 'Passed',
      'rejected' || 'underage' || 'expired' || 'error' => 'Needs attention',
      'pending' => 'Under review',
      'not_submitted' => 'Not submitted',
      _ when _busy => 'Comparing',
      _ => 'Next',
    };
    // No approval step: a passed face match makes you ready straight away.
    final readyStatus = _status == 'verified' ? 'Done' : 'After face match';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Column(
          children: [
            _processStageRow('1', 'Email sign-in', 'Complete'),
            const Divider(height: 1),
            _processStageRow(
              '2',
              'Face match',
              faceStatus,
              key: const ValueKey('face-match-stage-status'),
              emphasized: _status != 'verified',
            ),
            const Divider(height: 1),
            _processStageRow('3', 'Ready to help', readyStatus),
          ],
        ),
      ),
    );
  }

  Widget _processStageRow(
    String number,
    String label,
    String status, {
    Key? key,
    bool emphasized = false,
  }) => Padding(
    key: key,
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        CircleAvatar(radius: 12, child: Text(number)),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        Text(
          status,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(fontWeight: emphasized ? FontWeight.bold : null),
        ),
      ],
    ),
  );

  List<Widget> _consentContent() => [
    Text('Before you begin', style: Theme.of(context).textTheme.headlineMedium),
    const SizedBox(height: 10),
    const Text(
      'Helping as a responder or companion requires a face match. This demo '
      'does not validate the ID document. Your journeys, check-ins, and SOS '
      'remain available whether or not you verify.',
    ),
    const SizedBox(height: 18),
    Card(
      child: CheckboxListTile(
        key: const ValueKey('verification-consent'),
        value: _consent,
        onChanged: (value) => setState(() => _consent = value ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('I agree to the demo face match.'),
        subtitle: const Text(
          'The ID photo and selfie are sent to our self-hosted matcher for a '
          'face comparison. SixthSense does not save the images in its database. '
          'Your selfie is also checked, in memory, against people removed from '
          'SixthSense for misconduct.',
        ),
      ),
    ),
    const SizedBox(height: 8),
    Card(
      child: CheckboxListTile(
        key: const ValueKey('face-template-consent'),
        value: _faceTemplateConsent,
        onChanged: (value) =>
            setState(() => _faceTemplateConsent = value ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text(
          'Save an encrypted face reference for Walk With Me checks (optional).',
        ),
        subtitle: const Text(
          'Only a CompreFace embedding is retained, never either photo. It is used to compare a fresh selfie before each companion walk. You can delete it from this screen later.',
        ),
      ),
    ),
    const SizedBox(height: 16),
    FilledButton(
      onPressed: _consent && !_busy ? _startSession : null,
      child: _busy ? const CircularProgressIndicator() : const Text('Continue'),
    ),
    if (_error != null) _inlineError(_error!),
    TextButton(onPressed: () => _finish(false), child: const Text('Not now')),
  ];

  List<Widget> _idTypeContent() => [
    Text('Choose your ID', style: Theme.of(context).textTheme.headlineMedium),
    const SizedBox(height: 8),
    const Text('Select the ID type to compare its portrait with your selfie.'),
    const SizedBox(height: 16),
    RadioGroup<String>(
      groupValue: _idType,
      onChanged: (value) {
        if (value != null) _selectIdType(value);
      },
      child: Column(
        children: [
          for (final option in const [
            ('drivers_license', 'Driving Licence'),
            ('voter_id', 'Voter ID'),
            ('passport', 'Passport'),
          ])
            RadioListTile<String>(value: option.$1, title: Text(option.$2)),
        ],
      ),
    ),
    const SizedBox(height: 12),
    FilledButton(
      onPressed: () => setState(() => _stage = _VerificationStage.document),
      child: const Text('Continue'),
    ),
    TextButton(
      onPressed: () => setState(() => _stage = _VerificationStage.consent),
      child: const Text('Back'),
    ),
  ];

  List<Widget> _documentContent() => [
    Text(
      'Enter sample details',
      style: Theme.of(context).textTheme.headlineMedium,
    ),
    const SizedBox(height: 8),
    const Text(
      'Enter the ID type, number, and date of birth. Document authenticity is not checked in this demo.',
    ),
    const SizedBox(height: 16),
    _SampleDocument(idType: _idType),
    const SizedBox(height: 16),
    TextField(
      key: const ValueKey('sample-id-number'),
      controller: _idNumber,
      onChanged: _onIdNumberChanged,
      decoration: InputDecoration(
        labelText: _idNumberIsSuggestion
            ? 'Suggested ID number'
            : 'Sample ID number',
        hintText: 'DEMO-12345',
        helperText: _idNumberIsSuggestion
            ? 'Read from photo. Tap to edit.'
            : null,
        border: OutlineInputBorder(),
      ),
      textCapitalization: TextCapitalization.characters,
    ),
    const SizedBox(height: 12),
    TextField(
      key: const ValueKey('sample-dob'),
      controller: _dateOfBirth,
      onChanged: _onDateOfBirthChanged,
      keyboardType: TextInputType.datetime,
      decoration: InputDecoration(
        labelText: _dateOfBirthIsSuggestion
            ? 'Suggested date of birth'
            : 'Sample date of birth',
        hintText: 'YYYY-MM-DD',
        helperText: _dateOfBirthIsSuggestion
            ? 'Read from photo. Tap to edit.'
            : null,
        border: const OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      onPressed: _readingIdFields || _pickingIdPhoto ? null : _pickIdPhoto,
      icon: const Icon(Icons.upload_file),
      label: Text(
        _pickingIdPhoto
            ? 'Opening photo picker…'
            : _readingIdFields
            ? 'Reading ID details on this device…'
            : _idPhoto == null
            ? 'Upload ID photo'
            : 'Choose another ID photo',
      ),
    ),
    if (_readingIdFields)
      const Text(
        'Reading only the ID number and date of birth on this device.',
        key: ValueKey('id-ocr-progress'),
      ),
    if (_idPhoto != null) ...[
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(
          _idPhoto!.bytes,
          key: const ValueKey('verification-id-preview'),
          height: 160,
          fit: BoxFit.cover,
        ),
      ),
    ],
    if (_ocrMessage != null) ...[
      const SizedBox(height: 8),
      Text(_ocrMessage!, key: const ValueKey('id-ocr-message')),
    ],
    Text(
      _canContinueToSelfie ? 'ID details and photo ready.' : 'Enter an ID number, a valid date of birth, and upload the ID photo to continue.',
      key: const ValueKey('verification-document-requirements'),
    ),
    if (_error != null) _inlineError(_error!),
    const SizedBox(height: 16),
    FilledButton(
      key: const ValueKey('verification-document-continue'),
      onPressed: _canContinueToSelfie
          ? () => setState(() => _stage = _VerificationStage.selfie)
          : null,
      child: const Text('Continue to selfie check'),
    ),
    TextButton(
      onPressed: () => setState(() => _stage = _VerificationStage.idType),
      child: const Text('Back'),
    ),
  ];

  List<Widget> _selfieContent() => [
    Text('Selfie check', style: Theme.of(context).textTheme.headlineMedium),
    const SizedBox(height: 8),
    const Text(
      'Take a live selfie. The matcher compares it with the face in your ID photo. '
      'This demo does not perform liveness or ID authenticity checks.',
    ),
    const SizedBox(height: 20),
    Container(
      height: 180,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: _selfiePhoto == null
          ? const Center(child: Icon(Icons.face_retouching_natural, size: 84))
          : ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.memory(
                _selfiePhoto!.bytes,
                key: const ValueKey('verification-selfie-preview'),
                fit: BoxFit.cover,
              ),
            ),
    ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      onPressed: _busy ? null : _takeSelfie,
      icon: const Icon(Icons.camera_alt),
      label: Text(_selfiePhoto == null ? 'Take selfie' : 'Retake selfie'),
    ),
    if (kDebugMode) ...[
      const SizedBox(height: 20),
      DropdownButtonFormField<String>(
        key: const ValueKey('verification-scenario-picker'),
        initialValue: _scenario,
        decoration: const InputDecoration(
          labelText: 'Debug scenario',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final scenario in _scenarios)
            DropdownMenuItem(value: scenario, child: Text(scenario)),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _scenario = value);
        },
      ),
    ],
    if (!_canCompareFaces)
      const Text(
        'Add the ID details and photo, then take a selfie before comparing.',
        key: ValueKey('verification-selfie-requirements'),
      ),
    if (_error != null) _inlineError(_error!),
    const SizedBox(height: 20),
    FilledButton(
      key: const ValueKey('verification-review-details'),
      onPressed: _canCompareFaces
          ? () => setState(() {
              _confirmDetails = false;
              _stage = _VerificationStage.review;
            })
          : null,
      child: const Text('Review details'),
    ),
    TextButton(
      onPressed: _busy
          ? null
          : () => setState(() => _stage = _VerificationStage.document),
      child: const Text('Back'),
    ),
  ];

  List<Widget> _reviewContent() => [
    Text(
      'Review before face comparison',
      style: Theme.of(context).textTheme.headlineMedium,
    ),
    const SizedBox(height: 8),
    const Text(
      'Check the ID type, ID number, date of birth, and both photos. The face comparison will start only after you confirm.',
    ),
    const SizedBox(height: 16),
    Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _reviewValue('ID type', _idTypeLabel),
            _reviewValue(
              _idNumberIsSuggestion ? 'Suggested ID number' : 'ID number',
              _idNumber.text.trim(),
            ),
            _reviewValue(
              _dateOfBirthIsSuggestion
                  ? 'Suggested date of birth'
                  : 'Date of birth',
              _dateOfBirth.text.trim(),
            ),
            const SizedBox(height: 12),
            const Text('ID portrait'),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                _idPhoto!.bytes,
                key: const ValueKey('review-id-photo'),
                height: 140,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 12),
            const Text('Selfie'),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                _selfiePhoto!.bytes,
                key: const ValueKey('review-selfie-photo'),
                height: 140,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ],
        ),
      ),
    ),
    CheckboxListTile(
      key: const ValueKey('verification-confirm-details'),
      value: _confirmDetails,
      onChanged: _busy
          ? null
          : (value) => setState(() => _confirmDetails = value ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      title: const Text('I checked the ID number and date of birth.'),
      subtitle: const Text('These details and photos are ready to compare.'),
    ),
    const SizedBox(height: 12),
    FilledButton(
      key: const ValueKey('verification-submit'),
      onPressed: _canConfirmAndCompare ? _submitVerification : null,
      child: _busy
          ? const CircularProgressIndicator()
          : const Text('Confirm and compare faces'),
    ),
    TextButton(
      onPressed: _busy
          ? null
          : () => setState(() {
              _confirmDetails = false;
              _stage = _VerificationStage.document;
            }),
      child: const Text('Edit ID details'),
    ),
    TextButton(
      onPressed: _busy
          ? null
          : () => setState(() {
              _confirmDetails = false;
              _selfiePhoto = null;
              _stage = _VerificationStage.selfie;
            }),
      child: const Text('Retake selfie'),
    ),
  ];

  Widget _reviewValue(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 2),
        SelectableText(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );

  String get _idTypeLabel => switch (_idType) {
    'passport' => 'Passport',
    'voter_id' => 'Voter ID',
    _ => 'Driving Licence',
  };

  List<Widget> _pendingContent() => [
    const Icon(Icons.hourglass_top_rounded, size: 56),
    const SizedBox(height: 12),
    Text(
      'Waiting for review',
      style: Theme.of(context).textTheme.headlineMedium,
    ),
    const SizedBox(height: 8),
    const Text(
      'Your verification is pending. We’ll refresh this status when you return.',
    ),
    const SizedBox(height: 16),
    OutlinedButton(
      onPressed: _refreshSession,
      child: const Text('Refresh status'),
    ),
    TextButton(
      onPressed: () => _finish(false),
      child: const Text('Back to Respond'),
    ),
  ];

  List<Widget> _resultContent() {
    final status = _status ?? 'error';
    final title = switch (status) {
      'verified' => 'Verification complete',
      'underage' => 'You can’t respond as a helper yet',
      'expired' => 'Verification expired',
      'rejected' when _reason == 'duplicate' => 'Identity already used',
      'rejected' when _reason == 'not_eligible' => 'You can’t help on SixthSense',
      'rejected' => 'Verification not approved',
      _ => 'Verification needs attention',
    };
    final message = switch (status) {
      'verified' => 'Your identity check passed. You can now help as a responder or walk as a companion.',
      'rejected' when _reason == 'face_mismatch' => 'The ID portrait and selfie did not match closely enough. Retake the selfie or replace the ID portrait. Your details and ID photo stay on this screen for another try.',
      'underage' => 'This sample check did not meet the age requirement. Your protection features still work: journeys, check-ins, and SOS remain available.',
      'expired' =>
        'This verification session expired. Start a new attempt to continue.',
      'rejected' when _reason == 'duplicate' =>
        'This sample identity is already associated with another account.',
      'rejected' when _reason == 'not_eligible' =>
        'This identity can’t be used to help as a responder or companion.',
      'rejected' => 'The simulated check returned ${_reason ?? 'a rejection'}.',
      _ => _error ?? 'The verification service could not complete this check.',
    };
    return [
      Icon(
        status == 'verified' ? Icons.verified_outlined : Icons.info_outline,
        size: 56,
      ),
      const SizedBox(height: 12),
      Text(title, style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 8),
      Text(message),
      const SizedBox(height: 20),
      if (status == 'verified')
        if (_faceTemplateEnabled)
          OutlinedButton.icon(
            onPressed: _faceTemplateBusy ? null : _deleteFaceTemplate,
            icon: const Icon(Icons.delete_outline),
            label: Text(
              _faceTemplateBusy
                  ? 'Deleting…'
                  : 'Delete saved Walk With Me face reference',
            ),
          )
        else ...[
          if (_faceTemplateConsent)
            const Text(
              'Identity verification succeeded, but the matcher did not return a reusable face reference. You can retry enrollment below.',
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CheckboxListTile(
                    key: const ValueKey('face-template-reenrollment-consent'),
                    contentPadding: EdgeInsets.zero,
                    value: _faceTemplateConsent,
                    onChanged: (value) =>
                        setState(() => _faceTemplateConsent = value ?? false),
                    title: const Text(
                      'I consent to saving an encrypted face reference.',
                    ),
                    subtitle: const Text(
                      'Only the embedding is retained. The new ID portrait and selfie are used for this match and then discarded.',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _faceTemplateBusy ? null : _pickTemplateIdPhoto,
                    icon: const Icon(Icons.badge_outlined),
                    label: Text(
                      _idPhoto == null
                          ? 'Choose ID portrait'
                          : 'Replace ID portrait',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _faceTemplateBusy ? null : _takeTemplateSelfie,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: Text(
                      _selfiePhoto == null
                          ? 'Take enrollment selfie'
                          : 'Retake selfie',
                    ),
                  ),
                  if (_idPhoto != null && _selfiePhoto != null)
                    const Text('Both images are ready for a face match.'),
                  FilledButton.tonal(
                    key: const ValueKey('enroll-face-template'),
                    onPressed:
                        !_faceTemplateConsent ||
                            _idPhoto == null ||
                            _selfiePhoto == null ||
                            _faceTemplateBusy
                        ? null
                        : _enrollFaceTemplate,
                    child: _faceTemplateBusy
                        ? const CircularProgressIndicator()
                        : const Text('Save face reference'),
                  ),
                  if (_error != null) _inlineError(_error!),
                ],
              ),
            ),
          ),
        ],
      if (status == 'verified')
        FilledButton(
          onPressed: () => _finish(true),
          child: const Text('Continue to responder application'),
        )
      else if (status == 'rejected' && _reason == 'face_mismatch') ...[
        FilledButton.tonal(
          key: const ValueKey('retake-after-face-mismatch'),
          onPressed: _busy ? null : _retryFaceMismatch,
          child: const Text('Retake selfie'),
        ),
        TextButton(
          onPressed: () => _finish(false),
          child: const Text('Back to Respond'),
        ),
      ] else ...[
        FilledButton.tonal(
          onPressed: _newAttempt,
          child: const Text('Start a new attempt'),
        ),
        TextButton(
          onPressed: () => _finish(false),
          child: const Text('Back to Respond'),
        ),
      ],
    ];
  }

  List<Widget> _errorContent() => [
    const Icon(Icons.cloud_off_outlined, size: 56),
    const SizedBox(height: 12),
    Text(
      'Could not complete verification',
      style: Theme.of(context).textTheme.headlineMedium,
    ),
    const SizedBox(height: 8),
    Text(_error ?? 'Try again when the server is available.'),
    const SizedBox(height: 16),
    if (_retryComparisonAvailable && _canCompareFaces) ...[
      FilledButton.tonal(
        key: const ValueKey('retry-face-comparison'),
        onPressed: _busy ? null : _retryComparison,
        child: const Text('Retry face comparison'),
      ),
      TextButton(
        onPressed: _busy ? null : _newAttempt,
        child: const Text('Start a new attempt'),
      ),
    ] else
      FilledButton.tonal(
        onPressed: _newAttempt,
        child: const Text('Try again'),
      ),
    TextButton(
      onPressed: () => _finish(false),
      child: const Text('Back to Respond'),
    ),
  ];

  Widget _inlineError(String message) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}

enum _VerificationStage {
  loading,
  consent,
  idType,
  document,
  selfie,
  review,
  pending,
  result,
  error,
}

class SimulatedBanner extends StatelessWidget {
  const SimulatedBanner({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.tertiaryContainer,
    padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 16),
    child: Text(
      'DEMO CHECK · FACE MATCH ONLY',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelLarge,
    ),
  );
}

class _SampleDocument extends StatelessWidget {
  const _SampleDocument({required this.idType});

  final String idType;

  @override
  Widget build(BuildContext context) {
    final label = switch (idType) {
      'voter_id' => 'VOTER ID',
      'passport' => 'PASSPORT',
      _ => 'DRIVING LICENCE',
    };
    return Container(
      height: 148,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primaryContainer,
            Theme.of(context).colorScheme.secondaryContainer,
          ],
        ),
      ),
      child: Row(
        children: [
          const CircleAvatar(child: Icon(Icons.person_outline)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'SAMPLE · $label',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                const Text('DEMO HOLDER'),
                const Text('ID: SAMPLE-0000'),
                const Text('DOB: 2000-01-01'),
              ],
            ),
          ),
          const Icon(Icons.verified_user_outlined),
        ],
      ),
    );
  }
}

String? _supportedImageMimeType(String mimeType, String? path) {
  final declared = mimeType.split(';').first.trim().toLowerCase();
  if (declared == 'image/jpeg' || declared == 'image/jpg') return 'image/jpeg';
  if (declared == 'image/png' || declared == 'image/webp') return declared;
  if (declared.isNotEmpty && declared != 'application/octet-stream') {
    return null;
  }
  final extension = path?.toLowerCase().split('.').last;
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => null,
  };
}

String _photoErrorMessage(Object error, String fallback) =>
    error is _PhotoSelectionException ? error.message : fallback;

class _PhotoSelectionException implements Exception {
  const _PhotoSelectionException(this.message);

  final String message;
}
