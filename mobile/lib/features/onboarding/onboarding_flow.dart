import 'package:flutter/material.dart';

import '../journey/journey_flow.dart';

/// Local UI flow for P1-W1. OTP delivery and contact sync are connected when
/// the shared auth and contacts API contract is ready.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _contacts = <TrustedContactDraft>[];
  var _step = OnboardingStep.phone;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _continueToCode() {
    if (_phoneController.text.trim().replaceAll(RegExp(r'\D'), '').length <
        10) {
      _showMessage('Enter a valid phone number to continue.');
      return;
    }
    setState(() => _step = OnboardingStep.code);
  }

  void _verifyCode() {
    if (_codeController.text.trim().length < 4) {
      _showMessage('Enter the verification code to continue.');
      return;
    }
    setState(() => _step = OnboardingStep.contacts);
  }

  Future<void> _addContact() async {
    final contact = await showDialog<TrustedContactDraft>(
      context: context,
      builder: (_) => const _AddContactDialog(),
    );
    if (contact != null && mounted) {
      setState(() => _contacts.add(contact));
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _finishOnboarding() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const JourneyFlow()),
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
                    onBack: _step == OnboardingStep.phone
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
                        OnboardingStep.phone => _PhoneStep(
                          key: const ValueKey('phone'),
                          controller: _phoneController,
                          onContinue: _continueToCode,
                          text: text,
                        ),
                        OnboardingStep.code => _CodeStep(
                          key: const ValueKey('code'),
                          controller: _codeController,
                          phone: _phoneController.text.trim(),
                          onContinue: _verifyCode,
                          text: text,
                        ),
                        OnboardingStep.contacts => _ContactsStep(
                          key: const ValueKey('contacts'),
                          contacts: _contacts,
                          onAdd: _addContact,
                          onRemove: (contact) =>
                              setState(() => _contacts.remove(contact)),
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

enum OnboardingStep { phone, code, contacts }

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

class _PhoneStep extends StatelessWidget {
  const _PhoneStep({
    super.key,
    required this.controller,
    required this.onContinue,
    required this.text,
  });

  final TextEditingController controller;
  final VoidCallback onContinue;
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
          'Sign in with your phone number. You never need an ID to use protection.',
          style: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 30),
        Text('Phone number', style: text.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumber],
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.phone_iphone_rounded),
            hintText: '+91 98765 43210',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        FilledButton(onPressed: onContinue, child: const Text('Continue')),
        const Spacer(flex: 2),
      ],
    );
  }
}

class _CodeStep extends StatelessWidget {
  const _CodeStep({
    super.key,
    required this.controller,
    required this.phone,
    required this.onContinue,
    required this.text,
  });

  final TextEditingController controller;
  final String phone;
  final VoidCallback onContinue;
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
          'Enter the verification code sent to $phone.',
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
        FilledButton(onPressed: onContinue, child: const Text('Verify number')),
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
    required this.onContinue,
    required this.text,
  });

  final List<TrustedContactDraft> contacts;
  final VoidCallback onAdd;
  final ValueChanged<TrustedContactDraft> onRemove;
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
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('Add a trusted contact'),
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
          onPressed: onContinue,
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
  const TrustedContactDraft({required this.name, required this.phone});

  final String name;
  final String phone;
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
