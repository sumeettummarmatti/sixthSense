import 'package:flutter/material.dart';

import '../../core/api/device_identity.dart';
import '../../core/location/live_location.dart';
import 'contact_alerts_screen.dart';
import 'my_people_screen.dart';

/// One tab for both sides of trust: the people who look out for me ("My people")
/// and the people I look out for ("I support", with their alerts and live
/// location). Both screens are unchanged inside.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({
    super.key,
    required this.api,
    required this.tab,
    this.relay,
    this.openAlerts = 0,
  });

  final DemoApi api;
  final LiveLocationRelay? relay;

  /// 0 = My people, 1 = I support. The home shell switches it when an alert comes in.
  final ValueNotifier<int> tab;
  final int openAlerts;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen>
    with SingleTickerProviderStateMixin {
  late final _controller = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.tab.value,
  );

  @override
  void initState() {
    super.initState();
    widget.tab.addListener(_follow);
    _controller.addListener(() => widget.tab.value = _controller.index);
  }

  void _follow() {
    if (_controller.index != widget.tab.value) {
      _controller.animateTo(widget.tab.value);
    }
  }

  @override
  void dispose() {
    widget.tab.removeListener(_follow);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        bottom: TabBar(
          controller: _controller,
          tabs: [
            const Tab(key: ValueKey('people-tab-mine'), text: 'My people'),
            Tab(
              key: const ValueKey('people-tab-support'),
              child: Badge(
                isLabelVisible: widget.openAlerts > 0,
                label: Text('${widget.openAlerts}'),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('I support'),
                ),
              ),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _controller,
        children: [
          MyPeopleScreen(api: widget.api, embedded: true),
          ContactAlertsScreen(
            api: widget.api,
            relay: widget.relay,
            embedded: true,
          ),
        ],
      ),
    );
  }
}
