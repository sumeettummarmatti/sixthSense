import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';
import '../contacts/contact_alerts.dart';
import '../../core/contacts/contact_book.dart';
import '../../core/location/live_location.dart';
import '../home/home_shell.dart';
import '../profile/profile_form.dart';

/// Demo onboarding connected to email OTP, Android device-key auth, contacts,
/// and Telegram linking.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key, this.api = const DemoApi()});

  final DemoApi api;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _contacts = <TrustedContactDraft>[];
  var _step = OnboardingStep.email;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _resumeSession();
  }

  Future<void> _resumeSession() async {
    final signedIn = await widget.api.trySilentSignIn();
    if (!mounted) return;
    if (signedIn) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => HomeShell(api: widget.api)),
      );
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _continueToCode() async {
    final email = _emailController.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      _showMessage('Enter a valid email address to continue.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.api.requestOtp(email);
      if (mounted) setState(() => _step = OnboardingStep.code);
    } on ApiException catch (error) {
      _showApiError(error);
    } catch (_) {
      _showMessage(
        'Could not request a sign-in code. Check the server connection.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      _showMessage('Enter the 6-digit verification code.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.api.verifyOtp(
        email: _emailController.text.trim(),
        code: code,
      );
      E2EKeyring.reset();
      final email = _emailController.text.trim();
      try {
        // How contacts see me in invites and alerts: the email name for the demo.
        await ContactBook(widget.api.identity).saveOwnerLabel(
          email.contains('@') ? email.substring(0, email.indexOf('@')) : email,
        );
      } catch (_) {
        // Not available in widget tests; the label falls back to a default.
      }
      await _askForProfileOnce();
      if (mounted) setState(() => _step = OnboardingStep.contacts);
    } on ApiException catch (error) {
      _showApiError(error);
    } catch (_) {
      _showMessage('Could not verify the code. Check the server connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// After the first sign-in: first name, bio, strengths, languages (P1-W3).
  /// Skippable; it can be filled in later from the Profile tab.
  Future<void> _askForProfileOnce() async {
    Profile? existing;
    try {
      existing = await widget.api.profile();
    } catch (_) {
      return; // offline or not reachable: the Profile tab can do it later
    }
    if (existing != null || !mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ProfileSetupScreen(api: widget.api)),
    );
  }

  Future<void> _addContact() async {
    final contact = await showDialog<TrustedContactDraft>(
      context: context,
      builder: (_) => const _AddContactDialog(),
    );
    if (contact == null || !mounted) return;
    setState(() => _busy = true);
    try {
      // The contact sees this name when they accept. Email prefix for the demo.
      final email = _emailController.text.trim();
      final prefix = email.contains('@')
          ? email.substring(0, email.indexOf('@'))
          : '';
      // Server allows 1-40 characters.
      final ownerLabel = prefix.isEmpty
          ? 'A SixthSense user'
          : prefix.substring(0, prefix.length.clamp(0, 40));
      final invite = await widget.api.createInvite(ownerLabel);
      final linkedContact = TrustedContactDraft(
        name: contact.name,
        phone: contact.phone,
        contactLinkId: invite['contact_link_id'] as String,
      );
      try {
        await ContactBook(widget.api.identity).save(
          linkedContact.contactLinkId,
          LocalContact(name: contact.name, phone: contact.phone),
        );
      } catch (_) {
        // Names are a convenience; the invite still works without them.
      }
      await const DeviceIdentity().shareInvite(
        invite['invite_url'] as String,
        contact.name,
      );
      if (mounted) {
        setState(() => _contacts.add(linkedContact));
        _showMessage('Invite created and ready to share.');
      }
    } on ApiException catch (error) {
      _showApiError(error);
    } catch (_) {
      _showMessage(
        'Could not create or share the invite. Check the server connection.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _getTelegramAlerts() async {
    setState(() => _busy = true);
    await linkTelegramFlow(context, widget.api);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _acceptInvite() async {
    setState(() => _busy = true);
    await acceptInviteFlow(context, widget.api);
    if (mounted) setState(() => _busy = false);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showApiError(ApiException error) {
    final message = switch (error.detail) {
      'rate_limited' => 'Too many requests. Wait a little, then try again.',
      'invalid_or_expired_code' =>
        'That code is incorrect or expired. Request a new one.',
      'too_many_attempts' => 'Too many attempts. Request a new code.',
      'telegram_not_configured' =>
        'Telegram alerts are not configured on the server yet.',
      'contact_limit_reached' => 'You have reached the trusted-contact limit.',
      'account_suspended' =>
        'This account has been blocked after a safety review. If you need help now, call 112.',
      'server_unreachable' || 'server_timeout' =>
        'Could not reach the server. Check that it is running on this network.',
      _ =>
        'The server could not complete this request (HTTP ${error.statusCode}: ${error.detail}).',
    };
    _showMessage(message);
  }

  void _finishOnboarding() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => HomeShell(api: widget.api)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TopBar(
                    step: _step,
                    onBack: _step == OnboardingStep.email
                        ? null
                        : () => setState(
                            () =>
                                _step = OnboardingStep.values[_step.index - 1],
                          ),
                  ),
                  const SizedBox(height: 28),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: switch (_step) {
                        OnboardingStep.email => _EmailStep(
                          key: const ValueKey('email'),
                          controller: _emailController,
                          onContinue: _continueToCode,
                          busy: _busy,
                          text: text,
                        ),
                        OnboardingStep.code => _CodeStep(
                          key: const ValueKey('code'),
                          controller: _codeController,
                          email: _emailController.text.trim(),
                          onContinue: _verifyCode,
                          busy: _busy,
                          text: text,
                        ),
                        OnboardingStep.contacts => _ContactsStep(
                          key: const ValueKey('contacts'),
                          contacts: _contacts,
                          onAdd: _addContact,
                          onRemove: (contact) =>
                              setState(() => _contacts.remove(contact)),
                          onTelegram: _getTelegramAlerts,
                          onAcceptInvite: _acceptInvite,
                          busy: _busy,
                          onContinue: _finishOnboarding,
                          text: text,
                        ),
                      },
                    ),
                  ),
                  if (_step != OnboardingStep.contacts)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        'Your account is yours. You choose who can support you.',
                        style: text.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum OnboardingStep { email, code, contacts }

class _TopBar extends StatelessWidget {
  const _TopBar({required this.step, required this.onBack});

  final OnboardingStep step;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: onBack == null
              ? const Icon(Icons.wb_twilight_rounded, size: 28)
              : IconButton(
                  tooltip: 'Go back',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: (step.index + 1) / OnboardingStep.values.length,
              minHeight: 6,
              backgroundColor: colors.primaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '${step.index + 1} of 3',
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ],
    );
  }
}

class _EmailStep extends StatelessWidget {
  const _EmailStep({
    super.key,
    required this.controller,
    required this.onContinue,
    required this.busy,
    required this.text,
  });

  final TextEditingController controller;
  final VoidCallback onContinue;
  final bool busy;
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        Text(
          'SixthSense',
          style: text.labelLarge?.copyWith(color: colors.primary),
        ),
        const SizedBox(height: 10),
        Text(
          'See the risk. Stop it early.',
          style: text.headlineLarge?.copyWith(height: 1.08),
        ),
        const SizedBox(height: 16),
        Text(
          'Sign in with your email. Use your college email on campus. You never need an ID to use protection.',
          style: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 30),
        Text('Email', style: text.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.mail_outline_rounded),
            hintText: 'name@college.edu.in',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: busy ? null : onContinue,
          child: busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Continue'),
        ),
        const Spacer(flex: 2),
      ],
    );
  }
}

class _CodeStep extends StatelessWidget {
  const _CodeStep({
    super.key,
    required this.controller,
    required this.email,
    required this.onContinue,
    required this.busy,
    required this.text,
  });

  final TextEditingController controller;
  final String email;
  final VoidCallback onContinue;
  final bool busy;
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        Icon(Icons.mark_email_read_outlined, size: 38, color: colors.primary),
        const SizedBox(height: 24),
        Text('Check your messages', style: text.headlineMedium),
        const SizedBox(height: 12),
        Text(
          'Enter the verification code we emailed to $email.',
          style: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Verification code',
            hintText: '6-digit code',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => onContinue(),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: busy ? null : onContinue,
          child: busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Verify email'),
        ),
        const Spacer(flex: 2),
      ],
    );
  }
}

class _ContactsStep extends StatelessWidget {
  const _ContactsStep({
    super.key,
    required this.contacts,
    required this.onAdd,
    required this.onRemove,
    required this.onTelegram,
    required this.onAcceptInvite,
    required this.busy,
    required this.onContinue,
    required this.text,
  });

  final VoidCallback onAcceptInvite;
  final List<TrustedContactDraft> contacts;
  final VoidCallback onAdd;
  final ValueChanged<TrustedContactDraft> onRemove;
  final VoidCallback onTelegram;
  final bool busy;
  final VoidCallback onContinue;
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text('Choose your people', style: text.headlineMedium),
        const SizedBox(height: 10),
        Text(
          'Trusted contacts can receive an alert if you ask for help. They only see your live location during an active journey or alert.',
          style: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 22),
        FilledButton.tonalIcon(
          onPressed: busy ? null : onTelegram,
          icon: const Icon(Icons.notifications_active_outlined),
          label: const Text('Get alerts on Telegram'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: busy ? null : onAdd,
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('Add a trusted contact'),
        ),
        TextButton.icon(
          onPressed: busy ? null : onAcceptInvite,
          icon: const Icon(Icons.link_rounded),
          label: const Text('I got an invite link'),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: contacts.isEmpty
              ? Center(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: colors.outline),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.people_outline_rounded,
                          size: 34,
                          color: colors.primary,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Your circle starts here',
                          style: text.titleMedium,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Add someone you trust. You can change this any time.',
                          textAlign: TextAlign.center,
                          style: text.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: contacts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final contact = contacts[index];
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            contact.name.substring(0, 1).toUpperCase(),
                          ),
                        ),
                        title: Text(contact.name),
                        subtitle: Text(contact.phone),
                        trailing: IconButton(
                          tooltip: 'Remove contact',
                          onPressed: () => onRemove(contact),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy ? null : onContinue,
          child: Text(contacts.isEmpty ? 'Do this later' : 'Finish setup'),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'You can remove a contact quietly at any time.',
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class TrustedContactDraft {
  const TrustedContactDraft({
    required this.name,
    required this.phone,
    this.contactLinkId = '',
  });

  final String name;
  final String phone;
  final String contactLinkId;
}

class _AddContactDialog extends StatefulWidget {
  const _AddContactDialog();

  @override
  State<_AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<_AddContactDialog> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    if (name.isEmpty || phone.replaceAll(RegExp(r'\D'), '').length < 10) return;
    Navigator.of(context).pop(TrustedContactDraft(name: name, phone: phone));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add trusted contact'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone number'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Add')),
      ],
    );
  }
}
