part of '../action.dart';

class _DelayTestTarget {
  _DelayTestTarget({
    required this.proxyName,
    required this.testUrl,
    required this.key,
    required this.sourceProxyNames,
  });

  final String proxyName;
  final String testUrl;
  final String key;
  final Set<String> sourceProxyNames;
}

@Riverpod(keepAlive: true)
class ProxiesAction extends _$ProxiesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  final TaskPool _delayTestPool = TaskPool(maxConcurrentDelayTests);
  final Map<String, Future<Delay?>> _pendingDelayTests = {};
  final Map<String, _DelayTestTarget> _pendingDelayTargets = {};
  int _delayTestGeneration = 0;
  int _groupRefreshGeneration = 0;
  final Map<String, ({int? profileId, Object token, String name})>
  _pendingSelectedRollback = {};

  bool _configurationListening = false;

  void _listenConfiguration() {
    if (_configurationListening) return;
    _configurationListening = true;
    final config = _core.configuration;
    Object token = config.token;
    void changed() {
      if (identical(token, config.token)) return;
      token = config.token;
      _groupRefreshGeneration++;
      cancelDelayTests();
      cancelPendingSelections();
    }

    config.addListener(changed);
    ref.onDispose(() => config.removeListener(changed));
  }

  @override
  void build() {
    ref.listen(currentProfileIdProvider, (previous, next) {
      _groupRefreshGeneration++;
      if (previous != next) {
        cancelDelayTests();
        cancelPendingSelections();
      }
    });
    ref.listen(coreStatusProvider, (_, next) {
      if (next != CoreStatus.connected) {
        cancelDelayTests();
      }
    });
  }

  void cancelPendingSelections() {
    for (final group in _pendingSelectedRollback.keys.toList()) {
      debouncer.cancel((FunctionTag.changeProxy, group));
      final pending = _pendingSelectedRollback[group]!;
      _writeSelection(pending.profileId, group, pending.name);
    }
    _pendingSelectedRollback.clear();
  }

  void cancelDelayTests() {
    final cancelledTargets = _pendingDelayTargets.values.toList();
    _delayTestGeneration++;
    _pendingDelayTests.clear();
    _pendingDelayTargets.clear();
    ref.read(pendingDelayTestsProvider.notifier).clear();
    ref
        .read(delayDataSourceProvider.notifier)
        .setDelays(
          cancelledTargets.map(
            (target) =>
                Delay(url: target.testUrl, name: target.proxyName, value: -1),
          ),
        );
  }

  void updateGroupsDebounce([Duration? duration]) {
    debouncer.call(FunctionTag.updateGroups, updateGroups, duration: duration);
  }

  bool get _canChangeSelection {
    _listenConfiguration();
    final config = _core.configuration;
    final loaded = ref.read(loadedGroupsProvider);
    final owner = ref.read(setupActionProvider.notifier).coreGroupsOwner;
    return config.sessionActive &&
        !config.applying &&
        (config.generation == 0 || (config.succeeded && owner != null)) &&
        (loaded == null ||
            (loaded.profileId == ref.read(currentProfileIdProvider) &&
                identical(loaded.token, config.token))) &&
        (owner == null ||
            owner.profileId == ref.read(currentProfileIdProvider));
  }

  void _writeSelection(int? profileId, String groupName, String proxyName) {
    if (profileId == null) return;
    final profile = ref.read(profileProvider(profileId));
    if (profile == null) return;
    final selections = {...profile.selectedMap};
    if (proxyName.isEmpty || proxyName == compatibleProxyName) {
      selections.remove(groupName);
    } else {
      selections[groupName] = proxyName;
    }
    final unchanged =
        selections.length == profile.selectedMap.length &&
        selections.entries.every(
          (entry) => profile.selectedMap[entry.key] == entry.value,
        );
    if (unchanged) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(selectedMap: selections));
  }

  void changeProxyDebounce(String groupName, String proxyName) {
    if (!_canChangeSelection) return;
    final profileId = ref.read(currentProfileIdProvider);
    final token = _core.configuration.token;
    _pendingSelectedRollback.putIfAbsent(
      groupName,
      () => (
        profileId: profileId,
        token: token,
        name: _currentSelectedName(groupName),
      ),
    );
    _writeSelection(profileId, groupName, proxyName);
    debouncer.call((FunctionTag.changeProxy, groupName), (
      String groupName,
      String proxyName,
    ) async {
      if (!identical(token, _core.configuration.token) ||
          ref.read(currentProfileIdProvider) != profileId ||
          !_canChangeSelection) {
        return;
      }
      await changeProxy(groupName: groupName, proxyName: proxyName);
      updateGroupsDebounce();
    }, args: [groupName, proxyName]);
  }

  Future<void> resetProxySelection(String groupName) async {
    if (!_canChangeSelection) return;
    debouncer.cancel((FunctionTag.changeProxy, groupName));
    debouncer.cancel(FunctionTag.updateGroups);
    _pendingSelectedRollback.remove(groupName);
    await changeProxy(groupName: groupName, proxyName: '');
    await updateGroups();
  }

  String _currentSelectedName(String groupName) {
    return ref.read(currentProfileProvider)?.selectedMap[groupName] ?? '';
  }

  Future<void> updateGroups() async {
    _listenConfiguration();
    final config = _core.configuration;
    if (!config.sessionActive ||
        config.applying ||
        (config.generation > 0 && !config.succeeded)) {
      return;
    }
    final owner = ref.read(setupActionProvider.notifier).coreGroupsOwner;
    // No guessed owner after a real configuration operation. Initial native
    // hydration is explicitly bound by SetupAction's running-service path.
    if (owner == null && config.generation > 0) return;
    final loaded = ref.read(loadedGroupsProvider);
    if (owner == null &&
        loaded != null &&
        !identical(loaded.token, config.token)) {
      return;
    }
    final profileId = owner != null
        ? owner.profileId
        : loaded != null
        ? loaded.profileId
        : ref.read(currentProfileProvider)?.id;
    final token = config.token;
    final intent = ref.read(currentProfileIdProvider);
    final generation = ++_groupRefreshGeneration;
    bool owns() =>
        identical(token, config.token) &&
        config.sessionActive &&
        !config.applying &&
        generation == _groupRefreshGeneration &&
        ref.read(currentProfileIdProvider) == intent;
    try {
      commonPrint.log('updateGroups');
      List<Group>? result;
      await retry<bool>(
        maxAttempts: system.isIOS ? 8 : 3,
        delay: system.isIOS ? const Duration(seconds: 2) : midDuration,
        task: () async {
          if (!owns()) return true;
          try {
            result = await _core.getProxiesGroups(
              selectedMap: profileId == null
                  ? {}
                  : ref.read(profileProvider(profileId))?.selectedMap ?? {},
              sortType: ref.read(proxiesStyleSettingProvider).sortType,
              delayMap: ref.read(delayDataSourceProvider),
              defaultTestUrl: ref.read(appSettingProvider).testUrl,
            );
            return true; // A successful empty snapshot is authoritative.
          } catch (e) {
            commonPrint.log(
              'updateGroups error: $e',
              logLevel: coreFailureLogLevel(e),
            );
            return false;
          }
        },
        retryIf: (success) => !success,
      );
      if (!owns() || result == null) return;
      ref
          .read(groupsProvider.notifier)
          .publish(profileId: profileId, token: token, groups: result!);
      if (result!.isNotEmpty) {
        _removeUnavailableSelections(profileId: profileId, groups: result!);
      }
    } catch (e) {
      commonPrint.log(
        'updateGroups failed: $e',
        logLevel: coreFailureLogLevel(e),
      );
    }
  }

  void _removeUnavailableSelections({
    required int? profileId,
    required List<Group> groups,
  }) {
    if (profileId == null) return;
    final currentProfile = ref.read(profileProvider(profileId));
    if (currentProfile == null) {
      return;
    }
    final availableProxies = {
      for (final group in groups)
        group.name: group.all.map((proxy) => proxy.name).toSet(),
    };
    final selectedMap = Map<String, String>.fromEntries(
      currentProfile.selectedMap.entries.where(
        (entry) => availableProxies[entry.key]?.contains(entry.value) == true,
      ),
    );
    if (selectedMap.length == currentProfile.selectedMap.length) {
      return;
    }
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(selectedMap: selectedMap));
  }

  void updateCurrentGroupName(String groupName) {
    final profile = ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(currentGroupName: groupName));
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(unfoldSet: value));
  }

  void setDelay(Delay delay) {
    if (_pendingDelayTests.containsKey(delayTestKey(delay.url, delay.name))) {
      return;
    }
    ref.read(delayDataSourceProvider.notifier).setDelay(delay);
  }

  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
  }) async {
    if (!_canChangeSelection) return;
    final profileId = ref.read(currentProfileIdProvider);
    final token = _core.configuration.token;
    final appSetting = ref.read(appSettingProvider);
    final closeConnections = appSetting.closeConnections;
    final params = ChangeProxyParams(
      groupName: groupName,
      proxyName: proxyName,
    );
    final pending = _pendingSelectedRollback.remove(groupName);
    final rollbackName =
        pending != null &&
            pending.profileId == profileId &&
            identical(pending.token, token)
        ? pending.name
        : _currentSelectedName(groupName);
    _writeSelection(profileId, groupName, proxyName);
    try {
      await _core.changeProxy(params, closeConnections: closeConnections);
    } catch (error) {
      commonPrint.log(
        'changeProxy($groupName -> $proxyName) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
      // Compare-and-swap the original owner only. A late failure must not
      // overwrite B, a newer tap, or a same-ID force reload's selection.
      final currentSelection = ref
          .read(profileProvider(profileId))
          ?.selectedMap;
      final requestedSelection =
          proxyName.isEmpty || proxyName == compatibleProxyName
          ? null
          : proxyName;
      final selectionMatches =
          currentSelection?[groupName] == requestedSelection;
      if (identical(token, _core.configuration.token) && selectionMatches) {
        _writeSelection(profileId, groupName, rollbackName);
      }
      dialogs.showNotifier(
        currentAppLocalizations.changeProxyFailedTip,
        level: MessageLevel.error,
      );
      return;
    }
    if (!identical(token, _core.configuration.token) ||
        ref.read(currentProfileIdProvider) != profileId) {
      return;
    }
    if (!closeConnections && appSetting.promptCloseConnections) {
      _showCloseConnectionsSnackBar(params);
    }
    ref.read(checkIpNumProvider.notifier).add();
  }

  void _showCloseConnectionsSnackBar(ChangeProxyParams params) {
    final token = _core.configuration.token;
    final profileId = ref.read(currentProfileIdProvider);
    final context = globalState.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    context.showSnackBar(
      currentAppLocalizations.closeConnectionsPrompt,
      persist: false,
      action: SnackBarAction(
        label: MaterialLocalizations.of(context).closeButtonTooltip,
        onPressed: () async {
          if (!_canChangeSelection ||
              !identical(token, _core.configuration.token) ||
              ref.read(currentProfileIdProvider) != profileId) {
            return;
          }
          await _core.changeProxy(params, closeConnections: true);
        },
      ),
    );
  }

  Future<String> updateProvider(
    ExternalProvider provider, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      final message = await _core.updateExternalProvider(
        providerName: provider.name,
      );
      if (message.isNotEmpty) return message;
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
      return '';
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<String> sideLoadExternalProvider(
    ExternalProvider provider,
    String data, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      final message = await _core.sideLoadExternalProvider(
        providerName: provider.name,
        data: data,
      );
      if (message.isNotEmpty) return message;
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
      return '';
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<void> proxyDelayTest(Proxy proxy, [String? testUrl]) {
    return _runDelayTests([proxy], testUrl, bumpSort: false);
  }

  Future<void> delayTestGroups(List<Group> groups) async {
    _listenConfiguration();
    final generation = _delayTestGeneration;
    for (final group in groups) {
      if (generation != _delayTestGeneration) return;
      await _runDelayTests(group.all, group.testUrl, bumpSort: false);
    }
    if (generation != _delayTestGeneration) return;
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTest(
    List<Proxy> proxies, [
    String? testUrl,
    Duration uiTimeout = const Duration(seconds: 1),
    FutureOr<void> Function(Set<String> proxyNames)? onDelayChanged,
  ]) {
    final operation = _runDelayTests(
      proxies,
      testUrl,
      bumpSort: true,
      onDelayChanged: onDelayChanged,
    );
    return operation.timeout(uiTimeout, onTimeout: () {});
  }

  List<_DelayTestTarget> _resolveDelayTestTargets(
    List<Proxy> proxies,
    String? testUrl,
  ) {
    final groups = ref.read(groupsProvider);
    final selectedMap = ref.read(selectedMapProvider);
    final fallbackTestUrl = ref.read(realTestUrlProvider(testUrl));
    final targets = <String, _DelayTestTarget>{};
    for (final proxy in proxies) {
      final state = computeRealSelectedProxyState(
        proxy.name,
        groups: groups,
        selectedMap: selectedMap,
      );
      if (state.proxyName.isEmpty) {
        continue;
      }
      final currentTestUrl = state.testUrl.takeFirstValid([fallbackTestUrl]);
      final key = delayTestKey(currentTestUrl, state.proxyName);
      final target = targets[key];
      if (target != null) {
        target.sourceProxyNames.add(proxy.name);
        continue;
      }
      targets[key] = _DelayTestTarget(
        proxyName: state.proxyName,
        testUrl: currentTestUrl,
        key: key,
        sourceProxyNames: {proxy.name},
      );
    }
    return targets.values.toList();
  }

  Future<void> _runDelayTests(
    List<Proxy> proxies,
    String? testUrl, {
    required bool bumpSort,
    FutureOr<void> Function(Set<String> proxyNames)? onDelayChanged,
  }) async {
    _listenConfiguration();
    final config = _core.configuration;
    final loaded = ref.read(loadedGroupsProvider);
    if (!config.sessionActive ||
        config.applying ||
        (config.generation > 0 && (!config.succeeded || loaded == null)) ||
        (loaded != null && !identical(loaded.token, config.token))) {
      return;
    }
    final generation = _delayTestGeneration;
    final targets = _resolveDelayTestTargets(proxies, testUrl);
    if (targets.isEmpty) {
      return;
    }
    final scheduled = _scheduleDelayTests(targets);
    final operations = targets.map((target) async {
      try {
        await scheduled[target.key];
      } catch (error) {
        commonPrint.log(
          'Delay test failed for ${target.proxyName}: $error',
          logLevel: coreFailureLogLevel(error),
        );
      } finally {
        await onDelayChanged?.call(target.sourceProxyNames);
      }
    }).toList();
    await onDelayChanged?.call(
      targets.expand((target) => target.sourceProxyNames).toSet(),
    );
    await Future.wait(operations);
    if (bumpSort && generation == _delayTestGeneration) {
      ref.read(sortNumProvider.notifier).add();
    }
  }

  Map<String, Future<Delay?>> _scheduleDelayTests(
    List<_DelayTestTarget> targets,
  ) {
    final scheduled = <String, Future<Delay?>>{};
    final fresh = <_DelayTestTarget>[];
    for (final target in targets) {
      final pending = _pendingDelayTests[target.key];
      if (pending != null) {
        scheduled[target.key] = pending;
      } else {
        fresh.add(target);
      }
    }
    if (fresh.isEmpty) {
      return scheduled;
    }
    final generation = _delayTestGeneration;
    final completers = <_DelayTestTarget, Completer<Delay?>>{};
    for (final target in fresh) {
      final completer = Completer<Delay?>();
      completers[target] = completer;
      scheduled[target.key] = completer.future;
      _pendingDelayTests[target.key] = completer.future;
      _pendingDelayTargets[target.key] = target;
    }
    ref
        .read(pendingDelayTestsProvider.notifier)
        .acquire(fresh.map((target) => target.key));
    ref
        .read(delayDataSourceProvider.notifier)
        .setDelays(
          fresh.map(
            (target) =>
                Delay(url: target.testUrl, name: target.proxyName, value: 0),
          ),
        );
    for (final MapEntry(key: target, value: completer) in completers.entries) {
      final operation = completer.future;
      void release() {
        if (identical(_pendingDelayTests[target.key], operation)) {
          _pendingDelayTests.remove(target.key);
          _pendingDelayTargets.remove(target.key);
          ref.read(pendingDelayTestsProvider.notifier).release([target.key]);
        }
      }

      unawaited(
        operation.then<void>(
          (_) => release(),
          onError: (Object _, StackTrace _) => release(),
        ),
      );
      unawaited(
        _delayTestPool
            .run(() => _runDelayTest(target, generation))
            .then<void>(completer.complete, onError: completer.completeError),
      );
    }
    return scheduled;
  }

  Future<Delay?> _runDelayTest(_DelayTestTarget target, int generation) async {
    if (generation != _delayTestGeneration) {
      return null;
    }
    try {
      final delay = await _core.getDelay(target.testUrl, target.proxyName);
      if (generation != _delayTestGeneration) {
        return null;
      }
      final result =
          delay ??
          Delay(url: target.testUrl, name: target.proxyName, value: -1);
      ref.read(delayDataSourceProvider.notifier).setDelay(result);
      return result;
    } catch (error) {
      if (error is CoreMethodException &&
          error.isCoreUnavailable &&
          generation == _delayTestGeneration) {
        cancelDelayTests();
        rethrow;
      }
      if (generation == _delayTestGeneration) {
        ref
            .read(delayDataSourceProvider.notifier)
            .setDelay(
              Delay(url: target.testUrl, name: target.proxyName, value: -1),
            );
      }
      rethrow;
    }
  }
}
