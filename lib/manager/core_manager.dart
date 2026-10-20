import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/core/loaded_provider_recovery.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CoreManager extends ConsumerStatefulWidget {
  final Widget child;

  const CoreManager({super.key, required this.child});

  @override
  ConsumerState<CoreManager> createState() => _CoreContainerState();
}

class _CoreContainerState extends ConsumerState<CoreManager>
    with CoreEventListener {
  LoadedProviderRecovery? _recovery;
  bool _inBatch = false;
  final _batchLogs = <Log>[];
  final _batchRequests = <TrackerInfo>[];
  final _batchDns = <DnsQuery>[];

  @override
  void onBatchStart() {
    _inBatch = true;
  }

  @override
  void onBatchEnd() {
    _inBatch = false;
    try {
      if (mounted) {
        if (_batchLogs.isNotEmpty) {
          ref.read(logsProvider.notifier).addLogs(_batchLogs);
        }
        if (_batchRequests.isNotEmpty) {
          ref.read(requestsProvider.notifier).addRequests(_batchRequests);
        }
        if (_batchDns.isNotEmpty) {
          ref.read(dnsQueriesProvider.notifier).addQueries(_batchDns);
        }
      }
    } finally {
      _batchLogs.clear();
      _batchRequests.clear();
      _batchDns.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final owner = ref.watch(providersProvider.notifier).recovery;
    _attachRecovery(owner);
    return widget.child;
  }

  void _attachRecovery(LoadedProviderRecovery owner) {
    if (!identical(_recovery, owner)) _recovery?.pause();
    _recovery = owner;
    owner.resume();
    owner.updated = () {
      if (mounted) {
        ref.read(proxiesActionProvider.notifier).updateGroupsDebounce();
      }
    };
  }

  @override
  void initState() {
    super.initState();
    coreEventManager.addListener(this);
    _attachRecovery(ref.read(providersProvider.notifier).recovery);
    ref.read(updatingActionProvider.notifier);
    // A rejected profile stays selected on purpose: silently reverting to
    // the previous one hides the error and looks like the switch was lost.
    ref.listenManual(currentProfileIdProvider, (prev, next) {
      if (prev == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(ref.read(setupActionProvider.notifier).fullSetup());
      });
    });
    ref.listenManual(updateParamsProvider, (prev, next) {
      if (prev != next) {
        ref.read(setupActionProvider.notifier).updateConfigDebounce();
      }
    });
    ref.listenManual(profileReloadStateProvider, (prev, next) {
      if (prev != next) _reloadProfile();
    });
    ref.listenManual(activeAddedRulesProvider, (prev, next) {
      if (next.profileId == null ||
          prev?.profileId != next.profileId ||
          prev?.rules.value == null ||
          next.rules.isLoading ||
          next.rules.hasError ||
          ruleListEquality.equals(prev?.rules.value, next.rules.value)) {
        return;
      }
      _reloadProfile();
    });
  }

  void _reloadProfile() {
    if (!ref.read(initProvider) ||
        ref.read(coreStatusProvider) != CoreStatus.connected ||
        ref.read(currentProfileIdProvider) == null) {
      return;
    }
    ref.read(setupActionProvider.notifier).applyProfileDebounce(silence: true);
  }

  @override
  void dispose() {
    coreEventManager.removeListener(this);
    _recovery?.pause();
    debouncer.cancel(FunctionTag.updateGroups);
    super.dispose();
  }

  @override
  Future<void> onDelay(Delay delay) async {
    super.onDelay(delay);
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    proxiesAction.setDelay(delay);
    debouncer.call(FunctionTag.updateDelay, () async {
      proxiesAction.updateGroupsDebounce();
    }, duration: const Duration(milliseconds: 5000));
  }

  @override
  void onLog(Log log) {
    if (_inBatch) {
      _batchLogs.add(log);
    } else {
      ref.read(logsProvider.notifier).add(log);
    }
    if (log.logLevel == LogLevel.error) {
      throttler.call(
        FunctionTag.coreErrorNotifier,
        () => dialogs.showNotifier(log.payload, level: MessageLevel.error),
        duration: const Duration(seconds: 3),
        fire: true,
      );
    }
    super.onLog(log);
  }

  @override
  void onRequest(TrackerInfo trackerInfo) {
    if (_inBatch) {
      _batchRequests.add(trackerInfo);
    } else {
      ref.read(requestsProvider.notifier).addRequest(trackerInfo);
    }
    super.onRequest(trackerInfo);
  }

  @override
  void onDns(DnsQuery dnsQuery) {
    if (_inBatch) {
      _batchDns.add(dnsQuery);
    } else {
      ref.read(dnsQueriesProvider.notifier).addQuery(dnsQuery);
    }
    super.onDns(dnsQuery);
  }

  @override
  void onLoaded(String providerName) {
    // Synchronous queueing: no async-void future can escape event dispatch.
    // Read the current provider owner rather than retaining a global singleton.
    _attachRecovery(ref.read(providersProvider.notifier).recovery);
    _recovery!.loaded(providerName);
    super.onLoaded(providerName);
  }

  @override
  Future<void> onCrash(String message) async {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    _recovery?.core.configuration.retire();
    ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      context.showNotifier(message, level: MessageLevel.error);
    }
    super.onCrash(message);
  }

  @override
  void onGeoUpdate(String geoType, bool updating, bool skipped, String? error) {
    ref
        .read(geoResourceActionProvider.notifier)
        .handleCoreUpdate(geoType, updating, skipped, error);
    super.onGeoUpdate(geoType, updating, skipped, error);
  }
}
