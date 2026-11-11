import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

typedef SelfieCapture = Future<Uint8List?> Function();

/// Local UI prototype for Walk With Me. It does not match real people or send
/// chat, location, selfie, or verification data to a service.
class WalkFlow extends StatefulWidget {
  const WalkFlow({super.key, this.captureSelfie});

  final SelfieCapture? captureSelfie;

  @override
  State<WalkFlow> createState() => _WalkFlowState();
}

enum _WalkScreen {
  role,
  travellerRequest,
  travellerProfile,
  handshake,
  chat,
  companionDuty,
  liveness,
  complete,
}

enum _WalkRole { traveller, companion }

class _WalkMessage {
  const _WalkMessage(this.text, this.isLocal);

  final String text;
  final bool isLocal;
}

class _WalkFlowState extends State<WalkFlow> {
  static const _privacyChannel = MethodChannel('in.sixthsense/privacy');
  static const _meetingPoints = [
    'Campus main gate',
    'Library entrance',
    'Transit stop',
  ];
  static const _posePrompts = [
    'Turn your face slightly to the left',
    'Look toward the top of the screen',
    'Face the camera and blink once',
  ];
  static final _phoneNumberPattern = RegExp(r'(?<!\w)\+?\d[\d\s-]{8,}\d(?!\w)');

  final _random = Random.secure();
  final _chatController = TextEditingController();
  final _chatMessages = <_WalkMessage>[];
  final _imagePicker = ImagePicker();
  late final String _handshakeCode;
  late final String _pseudonym;
  late final String _posePrompt;
  _WalkScreen _screen = _WalkScreen.role;
  _WalkRole _role = _WalkRole.traveller;
  String _meetingPoint = _meetingPoints.first;
  Uint8List? _selfieBytes;
  bool _isOnDuty = false;
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    _handshakeCode = (1000 + _random.nextInt(9000)).toString();
    _pseudonym = 'Walker #${_random.nextInt(9000) + 1000}';
    _posePrompt = _posePrompts[_random.nextInt(_posePrompts.length)];
    unawaited(_setScreenshotProtection(true));
  }

  @override
  void dispose() {
    _chatController.dispose();
    _chatMessages.clear();
    _selfieBytes = null;
    unawaited(_setScreenshotProtection(false));
    super.dispose();
  }

  Future<void> _setScreenshotProtection(bool enabled) async {
    try {
      await _privacyChannel.invokeMethod<void>('setScreenshotProtection', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // The iOS privacy module is part of the later iOS port.
    } on PlatformException {
      // The flow remains usable if the OS does not support the protection.
    }
  }

  Future<Uint8List?> _captureSelfie() async {
    final photo = await _imagePicker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 80,
    );
    if (photo == null) return null;
    try {
      return await photo.readAsBytes();
    } finally {
      // image_picker stores camera captures in cache. Keep only the in-memory
      // bytes for this screen and remove its temporary file promptly.
      try {
        await File(photo.path).delete();
      } on FileSystemException {
        // Continue with the in-memory capture if cache cleanup is unavailable.
      }
    }
  }

  Future<void> _takeSelfie() async {
    setState(() => _isCapturing = true);
    try {
      final bytes = await (widget.captureSelfie ?? _captureSelfie)();
      if (!mounted) return;
      if (bytes != null) setState(() => _selfieBytes = bytes);
    } on PlatformException catch (error) {
      if (!mounted) return;
      _showMessage(error.message ?? 'The camera could not capture a selfie.');
    } catch (_) {
      if (!mounted) return;
      _showMessage('The camera could not capture a selfie. Try again.');
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  void _sendMessage() {
    final message = _chatController.text.trim();
    if (message.isEmpty) return;
    if (_phoneNumberPattern.hasMatch(message)) {
      _showMessage('Phone numbers cannot be shared in masked chat.');
      return;
    }
    setState(() {
      _chatMessages.add(_WalkMessage(message, true));
      _chatController.clear();
    });
  }

  void _endWalk() {
    _chatMessages.clear();
    _selfieBytes = null;
    setState(() => _screen = _WalkScreen.complete);
  }

  void _showMessage(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Walk With Me'),
        leading: _screen == _WalkScreen.role || _screen == _WalkScreen.complete
            ? null
            : IconButton(
                tooltip: 'Back',
                onPressed: () => setState(() {
                  _screen = switch (_screen) {
                    _WalkScreen.travellerRequest => _WalkScreen.role,
                    _WalkScreen.travellerProfile =>
                      _WalkScreen.travellerRequest,
                    _WalkScreen.handshake =>
                      _role == _WalkRole.traveller
                          ? _WalkScreen.travellerProfile
                          : _WalkScreen.liveness,
                    _WalkScreen.chat => _WalkScreen.handshake,
                    _WalkScreen.liveness => _WalkScreen.companionDuty,
                    _ => _WalkScreen.role,
                  };
                }),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: switch (_screen) {
                _WalkScreen.role => _buildRoleChooser(),
                _WalkScreen.travellerRequest => _buildTravellerRequest(),
                _WalkScreen.travellerProfile => _buildTravellerProfile(),
                _WalkScreen.handshake => _buildHandshake(),
                _WalkScreen.chat => _buildChat(),
                _WalkScreen.companionDuty => _buildCompanionDuty(),
                _WalkScreen.liveness => _buildLiveness(),
                _WalkScreen.complete => _buildComplete(),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoleChooser() => _page(
    key: const ValueKey('walk-role'),
    children: [
      const SizedBox(height: 24),
      const Icon(Icons.directions_walk_rounded, size: 54),
      const SizedBox(height: 16),
      Text(
        'Choose your role',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 12),
      const Text(
        'Prototype preview only. No real companion matching, identity checks, or communication happens here.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        key: const ValueKey('walk-traveller-role'),
        onPressed: () => setState(() {
          _role = _WalkRole.traveller;
          _screen = _WalkScreen.travellerRequest;
        }),
        icon: const Icon(Icons.person_pin_circle_outlined),
        label: const Text('Continue as traveller'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const ValueKey('walk-companion-role'),
        onPressed: () => setState(() {
          _role = _WalkRole.companion;
          _screen = _WalkScreen.companionDuty;
        }),
        icon: const Icon(Icons.volunteer_activism_outlined),
        label: const Text('Continue as companion'),
      ),
    ],
  );

  Widget _buildTravellerRequest() => _page(
    key: const ValueKey('walk-request'),
    children: [
      Text('Request a walk', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 10),
      const Text(
        'Choose a public meeting point. In the real service, a companion would receive only a coarse nearby area, not your exact location or destination.',
      ),
      const SizedBox(height: 24),
      DropdownButtonFormField<String>(
        key: const ValueKey('walk-meeting-point'),
        initialValue: _meetingPoint,
        decoration: const InputDecoration(
          labelText: 'Public meeting point',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final point in _meetingPoints)
            DropdownMenuItem(value: point, child: Text(point)),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _meetingPoint = value);
        },
      ),
      const Spacer(),
      FilledButton.icon(
        onPressed: () => setState(() => _screen = _WalkScreen.travellerProfile),
        icon: const Icon(Icons.search_rounded),
        label: const Text('Preview sample match'),
      ),
    ],
  );

  Widget _buildTravellerProfile() => _page(
    key: const ValueKey('walk-profile'),
    children: [
      Text(
        'Companion preview',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 18),
      const CircleAvatar(
        radius: 38,
        child: Icon(Icons.person_outline, size: 42),
      ),
      const SizedBox(height: 10),
      Text('Sample companion', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 6),
      const Chip(label: Text('Sample profile · not verified')),
      const SizedBox(height: 16),
      _notice(
        'No person was matched. Real profiles, trust tier, fresh liveness, and trusted-contact sharing require the unfinished P3 services.',
      ),
      const SizedBox(height: 14),
      ListTile(
        leading: const Icon(Icons.place_outlined),
        title: const Text('Meet at a public place'),
        subtitle: Text(_meetingPoint),
      ),
      const Spacer(),
      FilledButton(
        onPressed: () => setState(() => _screen = _WalkScreen.handshake),
        child: const Text('Continue to demo handshake'),
      ),
    ],
  );

  Widget _buildHandshake() => _page(
    key: const ValueKey('walk-handshake'),
    children: [
      Text(
        'Check the handshake code',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 12),
      const Text(
        'In a real walk, both phones must show the same code in person before you continue.',
        textAlign: TextAlign.center,
      ),
      const Spacer(),
      Semantics(
        label: 'Handshake code $_handshakeCode',
        child: Text(
          _handshakeCode,
          key: const ValueKey('walk-handshake-code'),
          style: Theme.of(context).textTheme.displayLarge
              ?.copyWith(letterSpacing: 12, fontWeight: FontWeight.w700),
        ),
      ),
      const SizedBox(height: 16),
      _notice(
        'Demo code only. It is not shared with another phone or verified.',
      ),
      const Spacer(),
      FilledButton(
        onPressed: () => setState(() => _screen = _WalkScreen.chat),
        child: const Text('Continue demo'),
      ),
    ],
  );

  Widget _buildChat() => _page(
    key: const ValueKey('walk-chat'),
    children: [
      Text('Masked chat', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 4),
      Text(_pseudonym, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      const Text('This local demo never sends phone numbers or messages.'),
      const SizedBox(height: 10),
      Expanded(
        child: _chatMessages.isEmpty
            ? const Center(child: Text('No messages yet'))
            : ListView.builder(
                itemCount: _chatMessages.length,
                itemBuilder: (context, index) {
                  final message = _chatMessages[index];
                  return Align(
                    alignment: message.isLocal
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(message.text),
                      ),
                    ),
                  );
                },
              ),
      ),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('walk-chat-input'),
              controller: _chatController,
              decoration: const InputDecoration(
                hintText: 'Message',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          IconButton(
            key: const ValueKey('walk-chat-send'),
            tooltip: 'Send message',
            onPressed: _sendMessage,
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _endWalk,
        icon: const Icon(Icons.flag_outlined),
        label: const Text('End walk demo'),
      ),
    ],
  );

  Widget _buildCompanionDuty() => _page(
    key: const ValueKey('walk-companion-duty'),
    children: [
      Text('Companion mode', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 12),
      const Text(
        'Companions must be verified before they can accept real walks. This prototype does not register you or receive requests.',
      ),
      const SizedBox(height: 18),
      SwitchListTile.adaptive(
        key: const ValueKey('walk-on-duty'),
        value: _isOnDuty,
        onChanged: (value) => setState(() => _isOnDuty = value),
        title: const Text('Go on duty'),
        subtitle: const Text('Prototype toggle only'),
      ),
      const Spacer(),
      FilledButton.icon(
        onPressed: _isOnDuty
            ? () => setState(() => _screen = _WalkScreen.liveness)
            : null,
        icon: const Icon(Icons.assignment_ind_outlined),
        label: const Text('Review sample walk request'),
      ),
    ],
  );

  Widget _buildLiveness() => SingleChildScrollView(
    key: const ValueKey('walk-liveness'),
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Fresh selfie check',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text('Pose prompt for this sample request:'),
        const SizedBox(height: 8),
        Text(_posePrompt, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        if (_selfieBytes case final bytes?)
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.memory(
              bytes,
              key: const ValueKey('walk-selfie-preview'),
              height: 220,
              width: 220,
              fit: BoxFit.cover,
            ),
          )
        else
          const CircleAvatar(
            radius: 72,
            child: Icon(Icons.camera_alt_outlined, size: 48),
          ),
        const SizedBox(height: 14),
        _notice(
          'A photo capture is not a liveness check. No face matching or verification SDK is connected; do not use this demo to accept a real walk.',
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _isCapturing ? null : _takeSelfie,
          icon: _isCapturing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.camera_alt_outlined),
          label: Text(
            _selfieBytes == null ? 'Take verification selfie' : 'Retake selfie',
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _selfieBytes == null
              ? null
              : () => setState(() => _screen = _WalkScreen.handshake),
          child: const Text('Continue demo only'),
        ),
      ],
    ),
  );

  Widget _buildComplete() => _page(
    key: const ValueKey('walk-complete'),
    children: [
      const Spacer(),
      const Icon(Icons.check_circle_outline_rounded, size: 56),
      const SizedBox(height: 16),
      Text(
        'Walk demo complete',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 10),
      const Text(
        'This prototype cleared the local chat and selfie from memory. It retained no route or partner profile.',
        textAlign: TextAlign.center,
      ),
      const Spacer(),
      FilledButton(
        onPressed: () => setState(() {
          _screen = _WalkScreen.role;
          _isOnDuty = false;
        }),
        child: const Text('Done'),
      ),
    ],
  );

  Widget _page({required Key key, required List<Widget> children}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _notice(String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Theme.of(context).colorScheme.outline),
    ),
    child: Text(text, textAlign: TextAlign.center),
  );
}
