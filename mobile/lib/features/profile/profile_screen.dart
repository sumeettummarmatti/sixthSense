import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
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
