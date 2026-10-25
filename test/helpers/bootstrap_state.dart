import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/services.dart';

// Matches Bootstrap._initData: AppState defaults groups to [], then both
// production override lists are installed. No groups/derived-state override.
AppState bootstrapAppState({List<Group> groups = const []}) => AppState(
  groups: groups,
  viewSize: const Size(400, 800),
  brightness: Brightness.light,
  requests: FixedList(10),
  version: 1,
  logs: FixedList(10),
  traffics: FixedList(10),
  totalTraffic: const Traffic(),
  systemUiOverlayStyle: SystemUiOverlayStyle.dark,
);

const bootstrapConfig = Config(
  currentProfileId: 1,
  themeProps: defaultThemeProps,
  appSettingProps: AppSettingProps(locale: 'en'),
  proxiesStyleProps: ProxiesStyleProps(type: ProxiesType.tab),
);
