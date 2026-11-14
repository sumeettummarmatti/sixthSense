import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';

/// "How was it?" after a journey or a walk ends. Skippable. Stored raw on the
/// server by journey (and walk) id: no location, no names.
Future<void> showFeedbackSheet(
  BuildContext context, {
  required DemoApi api,
  required String journeyId,
  String? walkId,
  String? companionName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FeedbackSheet(
      api: api,
      journeyId: journeyId,
      walkId: walkId,
      companionName: companionName,
    ),
  );
}

class FeedbackSheet extends StatefulWidget {
  const FeedbackSheet({
    super.key,
    required this.api,
    required this.journeyId,
    this.walkId,
    this.companionName,
  });

  final DemoApi api;
  final String journeyId;

  /// Set when there was a companion: then their stars are asked too.
  final String? walkId;
  final String? companionName;

  @override
  State<FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<FeedbackSheet> {
  static const maxNote = 500;

  int _routeStars = 0;
  int _companionStars = 0;
  final _chips = <String>{};
  final _note = TextEditingController();
  bool _sending = false;
  String? _error;

  bool get _hasCompanion => widget.walkId != null;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_routeStars == 0 || (_hasCompanion && _companionStars == 0)) {
      setState(() => _error = 'Pick the stars, or tap Skip.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.api.sendFeedback(
        FeedbackDraft(
          journeyId: widget.journeyId,
          walkId: widget.walkId,
          routeStars: _routeStars,
          companionStars: _hasCompanion ? _companionStars : null,
          chips: feedbackChips.keys.where(_chips.contains).toList(),
          note: _note.text.trim(),
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('Thanks for the feedback')));
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.detail == 'feedback_already_given') {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _error = 'Could not send (${error.detail}).');
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not send. Try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chips = {
      for (final entry in feedbackChips.entries)
        if (_hasCompanion || entry.key != 'companion_was_late')
          entry.key: entry.value,
    };
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('How was it?', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            Text('The route', style: theme.textTheme.titleSmall),
            _Stars(
              keyPrefix: 'route-star',
              value: _routeStars,
              onChanged: (stars) => setState(() => _routeStars = stars),
            ),
            if (_hasCompanion) ...[
              const SizedBox(height: 12),
              Text(
                widget.companionName == null
                    ? 'Your companion'
                    : 'Walking with ${widget.companionName}',
                style: theme.textTheme.titleSmall,
              ),
              _Stars(
                keyPrefix: 'companion-star',
                value: _companionStars,
                onChanged: (stars) => setState(() => _companionStars = stars),
              ),
              if (_companionStars == 1)
                Text(
                  'One star stops this person walking with anyone until our team reviews it.',
                  key: const ValueKey('companion-one-star-warning'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final entry in chips.entries)
                  FilterChip(
                    key: ValueKey('feedback-chip-${entry.key}'),
                    label: Text(entry.value),
                    selected: _chips.contains(entry.key),
                    onSelected: (on) => setState(
                      () =>
                          on ? _chips.add(entry.key) : _chips.remove(entry.key),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('feedback-note'),
              controller: _note,
              maxLength: maxNote,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Anything else? (optional)',
                helperText:
                    "About the place or the walk. Please don't add names.",
              ),
            ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 12),
            // The app theme makes filled buttons full width: stack, don't row.
            FilledButton(
              key: const ValueKey('feedback-send'),
              onPressed: _sending ? null : _send,
              child: Text(_sending ? 'Sending…' : 'Send'),
            ),
            Center(
              child: TextButton(
                key: const ValueKey('feedback-skip'),
                onPressed: _sending ? null : () => Navigator.of(context).pop(),
                child: const Text('Skip'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stars extends StatelessWidget {
  const _Stars({
    required this.keyPrefix,
    required this.value,
    required this.onChanged,
  });

  final String keyPrefix;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        for (var star = 1; star <= 5; star++)
          IconButton(
            key: ValueKey('$keyPrefix-$star'),
            tooltip: '$star of 5',
            onPressed: () => onChanged(star),
            icon: Icon(
              star <= value ? Icons.star_rounded : Icons.star_outline_rounded,
              color: color,
              size: 32,
            ),
          ),
      ],
    );
  }
}

/// After an alert: stars for each responder who said "I'm going" (P2-W4-helper-ban).
/// Skippable. One star suspends that responder until an admin reviews it, so the
/// sheet says so before sending.
Future<void> showResponderRatingSheet(
  BuildContext context, {
  required DemoApi api,
  required List<ResponderToRate> responders,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ResponderRatingSheet(api: api, responders: responders),
  );
}

class ResponderRatingSheet extends StatefulWidget {
  const ResponderRatingSheet({
    super.key,
    required this.api,
    required this.responders,
  });

  final DemoApi api;
  final List<ResponderToRate> responders;

  @override
  State<ResponderRatingSheet> createState() => _ResponderRatingSheetState();
}

class _ResponderRatingSheetState extends State<ResponderRatingSheet> {
  final _stars = <String, int>{};
  final _note = TextEditingController();
  var _sending = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_stars.isEmpty) {
      setState(() => _error = 'Pick the stars, or tap Skip.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      for (final entry in _stars.entries) {
        try {
          await widget.api.rateResponder(
            offerId: entry.key,
            stars: entry.value,
            note: _note.text.trim(),
          );
        } on ApiException catch (error) {
          if (error.detail != 'feedback_already_given') rethrow;
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('Thanks for the feedback')));
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = 'Could not send (${error.detail}).');
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not send. Try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final anyOneStar = _stars.values.any((stars) => stars == 1);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'How were the people who came?',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            const Text('Your rating helps us keep responders trustworthy.'),
            for (final responder in widget.responders) ...[
              const SizedBox(height: 12),
              Text(responder.name, style: theme.textTheme.titleSmall),
              _Stars(
                keyPrefix: 'responder-star-${responder.offerId}',
                value: _stars[responder.offerId] ?? 0,
                onChanged: (stars) =>
                    setState(() => _stars[responder.offerId] = stars),
              ),
            ],
            if (anyOneStar)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'One star stops this person helping anyone until our team reviews it.',
                  key: const ValueKey('responder-one-star-warning'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('responder-note'),
              controller: _note,
              maxLength: 500,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'What happened? (optional)',
                helperText: 'Seen only by the SixthSense team.',
              ),
            ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('responder-send'),
              onPressed: _sending ? null : _send,
              child: Text(_sending ? 'Sending…' : 'Send'),
            ),
            Center(
              child: TextButton(
                onPressed: _sending ? null : () => Navigator.of(context).pop(),
                child: const Text('Skip'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
