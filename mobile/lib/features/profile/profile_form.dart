import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';

/// First name, short bio, strengths, languages, optional gender and the
/// "willing to be a companion" switch. Used after the first sign-in and in the
/// Profile tab. Shown to someone else only inside a consented walk match.
class ProfileForm extends StatefulWidget {
  const ProfileForm({
    super.key,
    required this.onSave,
    this.initial,
    this.saveLabel = 'Save profile',
  });

  final Profile? initial;
  final Future<void> Function(Profile profile) onSave;
  final String saveLabel;

  @override
  State<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<ProfileForm> {
  static const maxBio = 200;

  late final _name = TextEditingController(text: widget.initial?.firstName);
  late final _bio = TextEditingController(text: widget.initial?.bio);
  late final _strengths = <String>{...?widget.initial?.strengths};
  late final _languages = <String>{...?widget.initial?.languages};
  late String? _gender = widget.initial?.gender;
  late bool _willing = widget.initial?.willingCompanion ?? false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Add your first name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        Profile(
          firstName: name,
          bio: _bio.text.trim(),
          strengths: profileStrengths.keys.where(_strengths.contains).toList(),
          languages: profileLanguages.where(_languages.contains).toList(),
          gender: _gender,
          willingCompanion: _willing,
        ),
      );
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = 'Could not save (${error.detail}).');
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save. Try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(text, style: theme.textTheme.titleSmall),
    );
    // A short form: build it all at once (keeps every field reachable).
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Only a walk partner you both agreed to will see this. '
            'Nobody can browse profiles.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('profile-first-name'),
            controller: _name,
            textCapitalization: TextCapitalization.words,
            maxLength: 40,
            decoration: const InputDecoration(labelText: 'First name'),
          ),
          TextField(
            key: const ValueKey('profile-bio'),
            controller: _bio,
            maxLength: maxBio,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Short bio (optional)',
              hintText:
                  'e.g. Final-year student, I walk this way most evenings',
            ),
          ),
          heading('Strengths'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final entry in profileStrengths.entries)
                FilterChip(
                  key: ValueKey('strength-${entry.key}'),
                  label: Text(entry.value),
                  selected: _strengths.contains(entry.key),
                  onSelected: (on) => setState(
                    () => on
                        ? _strengths.add(entry.key)
                        : _strengths.remove(entry.key),
                  ),
                ),
            ],
          ),
          heading('Languages'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final language in profileLanguages)
                FilterChip(
                  key: ValueKey('language-$language'),
                  label: Text(language),
                  selected: _languages.contains(language),
                  onSelected: (on) => setState(
                    () => on
                        ? _languages.add(language)
                        : _languages.remove(language),
                  ),
                ),
            ],
          ),
          heading('Gender (optional)'),
          DropdownButtonFormField<String?>(
            key: const ValueKey('profile-gender'),
            initialValue: _gender,
            decoration: const InputDecoration(
              helperText: 'Only used if a traveller asks for women companions.',
            ),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('Prefer not to say'),
              ),
              for (final entry in profileGenders.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) => setState(() => _gender = value),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            key: const ValueKey('profile-willing'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Willing to be a companion'),
            subtitle: const Text(
              'Walk with people heading your way. Companions are verified first.',
            ),
            value: _willing,
            onChanged: (value) => setState(() => _willing = value),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('profile-save'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : widget.saveLabel),
          ),
        ],
      ),
    );
  }
}

/// Shown once after the first email sign-in.
class ProfileSetupScreen extends StatelessWidget {
  const ProfileSetupScreen({super.key, required this.api});

  final DemoApi api;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('About you'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Later'),
          ),
        ],
      ),
      body: ProfileForm(
        saveLabel: 'Continue',
        onSave: (profile) async {
          await api.saveProfile(profile);
          if (context.mounted) Navigator.of(context).pop(true);
        },
      ),
    );
  }
}
