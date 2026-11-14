import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';
import '../../core/location/live_location.dart';
import '../journey/journey_flow.dart';
import '../onboarding/onboarding_flow.dart';
import 'profile_form.dart';

/// The Profile tab: edit what a walk partner may see.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.api});

  final DemoApi api;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<Profile?> _loading = widget.api.profile();
  var _version = 0;
  var _signingOut = false;

  Future<void> _logout() async {
    if (JourneyFlow.activeJourneyId.value != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('End your journey first, then log out.'),
        ),
      );
      return;
    }
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'You will need a new email code to sign in again. Your trusted contacts '
          'stay linked to your account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('logout-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _signingOut = true);
    try {
      await widget.api.logout();
    } catch (_) {
      // Offline: still sign out on this phone; the server token expires on its own.
    }
    try {
      await LiveLocationRelay.instance.stop();
      E2EKeyring.reset();
      await widget.api.identity.signOut();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => OnboardingFlow(api: widget.api)),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          TextButton.icon(
            key: const ValueKey('logout'),
            onPressed: _signingOut ? null : _logout,
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Log out'),
          ),
        ],
      ),
      body: FutureBuilder<Profile?>(
        future: _loading,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () =>
                    setState(() => _loading = widget.api.profile()),
                child: const Text('Could not load your profile. Retry'),
              ),
            );
          }
          return ProfileForm(
            key: ValueKey(_version),
            initial: snapshot.data,
            onSave: (profile) async {
              final saved = await widget.api.saveProfile(profile);
              if (!context.mounted) return;
              setState(() {
                _loading = Future.value(saved);
                _version++;
              });
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Profile saved')));
            },
          );
        },
      ),
    );
  }
}
