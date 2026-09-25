part of '../action.dart';

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  @override
  void build() {}

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    final selectedMap = Map<String, String>.from(currentProfile.selectedMap);
    if (proxyName.isEmpty || proxyName == compatibleProxyName) {
      selectedMap.remove(groupName);
    } else {
      selectedMap[groupName] = proxyName;
    }
    final unchanged =
        selectedMap.length == currentProfile.selectedMap.length &&
        selectedMap.entries.every(
          (entry) => currentProfile.selectedMap[entry.key] == entry.value,
        );
    if (unchanged) return;
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(selectedMap: selectedMap));
  }

  Future<void> deleteProfile(int id) async {
    await ref.read(profilesProvider.notifier).del(id);
    await clearEffect(id);
    final currentProfileId = ref.read(currentProfileIdProvider);
    if (currentProfileId == id) {
      final profiles = ref.read(profilesProvider);
      if (profiles.isNotEmpty) {
        final updateId = profiles.first.id;
        ref.read(currentProfileIdProvider.notifier).value = updateId;
      } else {
        ref.read(currentProfileIdProvider.notifier).value = null;
        unawaited(ref.read(setupActionProvider.notifier).setRunning(false));
      }
    }
  }

  Future<String> validateConfigWithData(String data) async {
    return _core.validateConfigWithData(data);
  }

  Future<String> loadProfileTemplate() {
    return profileTemplateStore.load();
  }

  Future<void> saveProfileTemplate(String content) {
    return profileTemplateStore.save(content, _core.validateConfigWithData);
  }

  Future<void> resetProfileTemplate() {
    return profileTemplateStore.reset();
  }

  Future<String> prepareProfileConfig(
    String content,
    String? ageSecretKey,
  ) async {
    var prepared = content;
    if (ageSecretKey?.isNotEmpty == true) {
      final decrypted = await _core.decryptAgeConfig(content, ageSecretKey!);
      if (decrypted.isNotEmpty) {
        prepared = decrypted;
      }
    }
    final convertedFastup = convertFastupSubscription(prepared);
    final isFastup = convertedFastup != prepared;
    prepared = convertedFastup;
    final yamlProxies = extractYamlProxies(prepared);
    if (yamlProxies != null && !isFullYamlProfile(prepared)) {
      final template = await loadProfileTemplate();
      prepared = injectSubscriptionProxies(
        template: template,
        proxies: yamlProxies,
      );
    } else if (!isFastup && !isYamlProfile(prepared)) {
      final proxies = await _core.convertUriSubscription(prepared);
      final template = await loadProfileTemplate();
      prepared = injectSubscriptionProxies(
        template: template,
        proxies: proxies,
      );
    }
    final message = await _core.validateConfigWithData(prepared);
    if (message.isNotEmpty) {
      throw MessageException(message);
    }
    return prepared;
  }

  void putProfile(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (ref.read(currentProfileIdProvider) != null) return;
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<void> updateProfiles() async {
    for (final profile in ref.read(profilesProvider)) {
      if (profile.type == ProfileType.file) continue;
      await updateProfile(profile);
    }
  }

  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref.read(updatingKeysProvider.notifier).start(profile.updatingKey)
        : null;
    try {
      ref.read(profilesProvider.notifier).put(profile);
      final newProfile = await profile.update(prepare: prepareProfileConfig);
      ref.read(profilesProvider.notifier).put(newProfile);
      if (profile.id == ref.read(currentProfileIdProvider)) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      }
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(profile.updatingKey, operation);
      }
    }
  }

  Future<ClipboardImportPreview> inspectClipboardContent(String content) async {
    final value = content.trim();
    if (value.isEmpty) {
      throw const MessageException('Clipboard is empty');
    }
    final uri = Uri.tryParse(value);
    if (!value.contains(RegExp(r'[\r\n]')) &&
        uri != null &&
        uri.hasAuthority &&
        (uri.scheme == 'http' || uri.scheme == 'https')) {
      return ClipboardImportPreview(
        kind: ClipboardImportKind.url,
        source: uri.host,
        suggestedName: uri.host,
      );
    }
    final yamlProxies = extractYamlProxies(value);
    if (yamlProxies != null) {
      return ClipboardImportPreview(
        kind: ClipboardImportKind.yaml,
        source: isFullYamlProfile(value) ? 'YAML profile' : 'YAML proxies',
        nodeCount: yamlProxies.length,
        suggestedName: currentAppLocalizations.clipboardImport,
      );
    }
    final proxies = await _core.convertUriSubscription(value);
    final decodedBase64 = !value.contains('://');
    return ClipboardImportPreview(
      kind: decodedBase64
          ? ClipboardImportKind.base64
          : ClipboardImportKind.uri,
      source: decodedBase64 ? 'Base64' : 'Proxy links',
      nodeCount: proxies.length,
      suggestedName: currentAppLocalizations.clipboardImport,
    );
  }

  Future<void> addProfileFromClipboardContent(
    String content, [
    String? label,
  ]) async {
    final value = content.trim();
    if (value.isEmpty) {
      throw const MessageException('Clipboard is empty');
    }
    final uri = Uri.tryParse(value);
    if (!value.contains(RegExp(r'[\r\n]')) &&
        uri != null &&
        uri.hasAuthority &&
        (uri.scheme == 'http' || uri.scheme == 'https')) {
      await addProfileFormURL(value, label: label);
      return;
    }
    final profile = await globalState.loadingRun(
      () =>
          Profile.normal(
            label: label?.trim().isNotEmpty == true
                ? label!.trim()
                : currentAppLocalizations.clipboardImport,
          ).saveFile(
            Uint8List.fromList(utf8.encode(value)),
            prepare: prepareProfileConfig,
          ),
      tag: LoadingTag.profiles,
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  Future<void> addProfileFormClipboard() async {
    final data = await globalState.safeRun(
      () => Clipboard.getData(Clipboard.kTextPlain),
    );
    final content = data?.text;
    if (content == null || content.trim().isEmpty) {
      throw const MessageException('Clipboard is empty');
    }
    await addProfileFromClipboardContent(content);
  }

  Future<void> addProfileFormFile() async {
    final platformFile = await globalState.safeRun(picker.pickerFile);
    if (platformFile == null) return;
    final bytes = await platformFile.readBytes();
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    ref.read(currentPageLabelProvider.notifier).toProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return Profile.normal(
          label: platformFile.name,
        ).saveFile(bytes, prepare: prepareProfileConfig);
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  Future<void> addProfileFormURL(
    String url, {
    String? ageSecretKey,
    String? label,
  }) async {
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    ref.read(currentPageLabelProvider.notifier).value = PageLabel.profiles;
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return Profile.normal(
          url: url,
          label: label?.trim().isNotEmpty == true ? label!.trim() : null,
          ageSecretKey: ageSecretKey,
        ).update(prepare: prepareProfileConfig);
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  void setProfileAndAutoApply(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (profile.id == ref.read(currentProfileIdProvider)) {
      ref.read(setupActionProvider.notifier).applyProfileDebounce();
    }
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    unawaited(addProfileFormURL(url));
  }

  void reorder(List<Profile> profiles) {
    ref.read(profilesProvider.notifier).reorder(profiles);
  }

  Future<void> clearEffect(int profileId) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final profileFile = File(profilePath);
    final isExists = await profileFile.exists();
    if (isExists) {
      await profileFile.safeDelete(recursive: true);
    }
    final error = await _core.deleteManagedPath(
      DeleteManagedPathParams(
        scope: ManagedPathScope.providers,
        relativePath: profileId.toString(),
      ),
    );
    if (error.isNotEmpty) {
      commonPrint.log(error, logLevel: LogLevel.warning);
    }
  }
}
