import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';
import '../../core/contacts/contact_book.dart';

/// My trusted contacts: add one any time, see who has accepted, remove quietly.
class MyPeopleScreen extends StatefulWidget {
  const MyPeopleScreen({super.key, required this.api, this.embedded = false});

  final DemoApi api;

  /// Inside the People tab, which shows its own app bar.
  final bool embedded;

  @override
  State<MyPeopleScreen> createState() => _MyPeopleScreenState();
}

class _MyPeopleScreenState extends State<MyPeopleScreen> {
  late final _book = ContactBook(widget.api.identity);
  List<Map<String, dynamic>>? _links;
  Map<String, LocalContact> _names = {};
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final links = await widget.api.listContacts();
      Map<String, LocalContact> names = {};
      try {
        names = await _book.load();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _links = links;
        _names = names;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the server.');
    }
  }

  Future<void> _add() async {
    final contact = await showDialog<LocalContact>(
      context: context,
      builder: (_) => const _AddPersonDialog(),
    );
    if (contact == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final invite = await widget.api.createInvite(await _book.ownerLabel());
      await _book.save(invite['contact_link_id'] as String, contact);
      await const DeviceIdentity().shareInvite(
        invite['invite_url'] as String,
        contact.name,
      );
      _show('Invite ready. Send it to ${contact.name}.');
    } on ApiException catch (error) {
      _show('Could not create the invite (${error.detail}).');
    } catch (_) {
      _show('Could not create the invite. Check the server connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _remove(String linkId, String name) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $name?'),
        content: const Text(
          'They stop getting your alerts and live location. They are not told.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await widget.api.removeContact(linkId);
      await _book.remove(linkId);
      _show('$name removed.');
    } catch (_) {
      _show('Could not remove. Check the server connection.');
    }
    await _refresh();
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final links = _links;
    final accepted =
        links?.where((link) => link['status'] == 'accepted').length ?? 0;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('My people')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('add-person'),
        onPressed: _busy ? null : _add,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add someone'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [colors.primary, colors.secondary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    links == null
                        ? 'Your circle'
                        : '$accepted ${accepted == 1 ? 'person' : 'people'} in your circle',
                    style: text.titleLarge?.copyWith(color: colors.onPrimary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'They get an alert if you miss a check-in or press SOS, and see your live location only while a journey is open.',
                    style: text.bodyMedium?.copyWith(
                      color: colors.onPrimary.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: TextStyle(color: colors.error)),
              ),
            if (links == null && _error == null)
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (links != null && links.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 32),
                child: Column(
                  children: [
                    Icon(
                      Icons.diversity_1_rounded,
                      size: 44,
                      color: colors.primary,
                    ),
                    const SizedBox(height: 12),
                    Text('Nobody yet', style: text.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      'Add someone you trust. They accept with the link you send.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            else if (links != null)
              for (final link in links) _personTile(link, colors, text),
          ],
        ),
      ),
    );
  }

  Widget _personTile(
    Map<String, dynamic> link,
    ColorScheme colors,
    TextTheme text,
  ) {
    final id = link['id'] as String;
    final local = _names[id];
    final name = local?.name ?? 'Contact';
    final accepted = link['status'] == 'accepted';
    return Card(
      key: ValueKey('person-$id'),
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outline),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          foregroundColor: colors.onPrimaryContainer,
          child: Text(name.characters.first.toUpperCase()),
        ),
        title: Text(name, style: text.titleMedium),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(
                accepted ? Icons.verified_user_outlined : Icons.schedule_send,
                size: 16,
                color: accepted ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  accepted
                      ? 'Gets your alerts'
                      : 'Invite sent, not accepted yet',
                ),
              ),
            ],
          ),
        ),
        trailing: IconButton(
          tooltip: 'Remove $name',
          icon: const Icon(Icons.person_remove_outlined),
          onPressed: () => _remove(id, name),
        ),
      ),
    );
  }
}

class _AddPersonDialog extends StatefulWidget {
  const _AddPersonDialog();

  @override
  State<_AddPersonDialog> createState() => _AddPersonDialogState();
}

class _AddPersonDialogState extends State<_AddPersonDialog> {
  final _name = TextEditingController();
  final _phone = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add someone you trust'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('person-name'),
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('person-phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone (for offline SMS, optional)',
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Their name and number stay on this phone. You get a link to send them.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(
              context,
              LocalContact(name: name, phone: _phone.text.trim()),
            );
          },
          child: const Text('Create invite'),
        ),
      ],
    );
  }
}
