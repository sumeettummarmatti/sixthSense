import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';

/// Shared actions for the contact's side of the demo: accept an invite, then
/// link Telegram so alerts reach this person.

Future<void> acceptInviteFlow(BuildContext context, DemoApi api) async {
  final link = await showDialog<String>(
    context: context,
    builder: (_) => const AcceptInviteDialog(),
  );
  if (link == null || !context.mounted) return;
  try {
    final owner = await api.acceptInvite(link);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('You are now a trusted contact'),
        content: Text(
          'You will be alerted if $owner asks for help. Tap "Get alerts on '
          'Telegram" so the alert reaches you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              linkTelegramFlow(context, api);
            },
            child: const Text('Get alerts on Telegram'),
          ),
        ],
      ),
    );
  } on ApiException catch (error) {
    if (context.mounted) _show(context, _inviteError(error));
  } catch (_) {
    if (context.mounted) {
      _show(
        context,
        'Could not accept the invite. Check the server connection.',
      );
    }
  }
}

Future<void> linkTelegramFlow(BuildContext context, DemoApi api) async {
  try {
    final url = await api.createTelegramLink();
    await const DeviceIdentity().openUrl(url);
    if (context.mounted) {
      _show(context, 'In Telegram, tap Start to finish linking alerts.');
    }
  } on ApiException catch (error) {
    if (context.mounted) {
      _show(
        context,
        error.detail == 'telegram_not_configured'
            ? 'Telegram alerts are not configured on the server yet.'
            : 'Could not link Telegram (HTTP ${error.statusCode}: ${error.detail}).',
      );
    }
  } catch (_) {
    if (context.mounted) {
      _show(context, 'Could not open Telegram. Check the server connection.');
    }
  }
}

String _inviteError(ApiException error) => switch (error.detail) {
  'invite_invalid' => 'That invite link is wrong, expired or already used.',
  'cannot_add_self' => 'You cannot accept your own invite.',
  'rate_limited' => 'Too many tries. Wait a little, then try again.',
  'server_unreachable' || 'server_timeout' =>
    'Could not reach the server. Check that it is running on this network.',
  _ =>
    'Could not accept the invite (HTTP ${error.statusCode}: ${error.detail}).',
};

void _show(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class AcceptInviteDialog extends StatefulWidget {
  const AcceptInviteDialog({super.key});

  @override
  State<AcceptInviteDialog> createState() => _AcceptInviteDialogState();
}

class _AcceptInviteDialogState extends State<AcceptInviteDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _accept() {
    if (DemoApi.inviteTokenFrom(_controller.text).isEmpty) {
      setState(() => _error = 'Paste the invite link you were sent.');
      return;
    }
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Accept an invite'),
      content: TextField(
        key: const ValueKey('invite-link'),
        controller: _controller,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: 'Invite link',
          hintText: 'Paste the link you were sent',
          errorText: _error,
        ),
        onSubmitted: (_) => _accept(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _accept, child: const Text('Accept')),
      ],
    );
  }
}
