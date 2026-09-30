#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>

#include "../../windows/tray_menu_icons.h"

#define private public
#include "../../windows/tray_plugin.h"
#undef private
#include "../../windows/tray_plugin.cpp"

namespace {

using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;

void Check(bool condition, const char* message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}

class Messenger : public flutter::BinaryMessenger {
 public:
  void Send(const std::string&, const uint8_t*, size_t,
            flutter::BinaryReply = nullptr) const override {}
  void SetMessageHandler(const std::string&,
                         flutter::BinaryMessageHandler) override {}
};

class Fixture {
 public:
  Fixture()
      : plugin(nullptr, std::make_unique<flutter::MethodChannel<Value>>(
                            &messenger, "tray",
                            &flutter::StandardMethodCodec::GetInstance())) {
    plugin.SetMenu(
        {Value(Node("selected", 101, true)), Value(Node("other", 102, false))});
    plugin.MaterializeMenu(plugin.menu_);
  }

  void Update(const char* key, Map fields) {
    fields[Value("key")] = Value(key);
    Check(plugin.UpdateMenuItems({Value(fields)}), "menu update failed");
  }

  MENUITEMINFOW Item(UINT position) {
    MENUITEMINFOW item{};
    item.cbSize = sizeof(item);
    item.fMask = MIIM_STATE | MIIM_BITMAP | MIIM_CHECKMARKS | MIIM_FTYPE;
    Check(::GetMenuItemInfoW(plugin.menu_, position, TRUE, &item) != FALSE,
          "cannot read native menu item");
    return item;
  }

  std::wstring Label(UINT position) {
    wchar_t label[256]{};
    Check(
        ::GetMenuStringW(plugin.menu_, position, label, 256, MF_BYPOSITION) > 0,
        "cannot read native menu label");
    return label;
  }

  Messenger messenger;
  tray::TrayPlugin plugin;

 private:
  static Map Node(const char* key, int id, bool checked) {
    return {{Value("type"), Value("checkbox")},
            {Value("key"), Value(key)},
            {Value("id"), Value(id)},
            {Value("label"), Value("Proxy & node")},
            {Value("sublabel"), Value("42 ms")},
            {Value("sublabelStyle"), Value("badge")},
            {Value("checked"), Value(checked)}};
  }
};

void CheckSystemCheckmark(const MENUITEMINFOW& item) {
  Check((item.fState & MFS_CHECKED) != 0, "selected node lost checked state");
  Check(item.hbmpItem == nullptr, "status icon masks the system checkmark");
  Check(item.hbmpChecked == nullptr && item.hbmpUnchecked == nullptr,
        "checkmark was replaced with a custom bitmap");
  Check((item.fType & MFT_OWNERDRAW) == 0, "menu row became owner-drawn");
}

void TestCheckmarks() {
  Fixture fixture;
  CheckSystemCheckmark(fixture.Item(0));
  const HBITMAP initial_icon = fixture.Item(1).hbmpItem;
  Check(initial_icon != nullptr, "unselected node has no status icon");

  for (const auto& delay :
       {std::pair{"...", "muted"}, std::pair{"Timeout", "destructive"},
        std::pair{"650 ms", "warning"}}) {
    fixture.Update("selected", {{Value("sublabel"), Value(delay.first)},
                                {Value("sublabelStyle"), Value(delay.second)}});
    CheckSystemCheckmark(fixture.Item(0));
  }
  Check(fixture.Label(0) == L"Proxy && node\t650 ms",
        "delay update lost the node label or result");

  fixture.Update("selected", {{Value("checked"), Value(false)}});
  auto unchecked = fixture.Item(0);
  Check((unchecked.fState & MFS_CHECKED) == 0, "node stayed checked");
  Check(unchecked.hbmpItem != nullptr,
        "unchecking did not restore status icon");
  fixture.Update("other", {{Value("checked"), Value(true)},
                           {Value("enabled"), Value(false)},
                           {Value("sublabel"), Value("17 ms")}});
  CheckSystemCheckmark(fixture.Item(1));
  Check((fixture.Item(1).fState & MFS_DISABLED) != 0,
        "changing the checkmark lost disabled state");
  Check(fixture.Label(1) == L"Proxy && node\t17 ms",
        "combined update lost text");

  fixture.Update("other", {{Value("checked"), Value(false)},
                           {Value("enabled"), Value(true)}});
  Check(fixture.Item(1).hbmpItem == initial_icon,
        "unchanged status icon not reused");
  fixture.Update("other", {{Value("sublabel"), Value("")}});
  Check(fixture.Item(1).hbmpItem == nullptr,
        "empty delay retained status icon");
  fixture.Update("other", {{Value("checked"), Value(true)}});
  CheckSystemCheckmark(fixture.Item(1));
  fixture.Update("other", {{Value("checked"), Value(false)}});
  Check(fixture.Item(1).hbmpItem == nullptr,
        "unchecking invented a delay icon");
}

void TestAppearance() {
  Fixture fixture;
  for (UINT dpi : {96u, 144u, 192u}) {
    for (bool dark : {false, true}) {
      fixture.plugin.menu_icons_.SetAppearance(dpi, dark);
      fixture.plugin.RefreshMenuIcons();
      CheckSystemCheckmark(fixture.Item(0));
      const auto icon = fixture.Item(1).hbmpItem;
      BITMAP bitmap{};
      Check(icon != nullptr && ::GetObjectW(icon, sizeof(bitmap), &bitmap) != 0,
            "appearance update produced an invalid icon");
      Check(
          bitmap.bmWidth == ::GetSystemMetricsForDpi(SM_CXMENUCHECK, dpi) &&
              bitmap.bmHeight == ::GetSystemMetricsForDpi(SM_CYMENUCHECK, dpi),
          "status icon does not match menu DPI");
      fixture.plugin.RefreshMenuIcons();
      Check(fixture.Item(1).hbmpItem == icon,
            "unchanged appearance recreated icon");
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  try {
    Check(argc == 2, "expected a test case name");
    const std::string name = argv[1];
    if (name == "checkmarks") {
      TestCheckmarks();
    } else if (name == "appearance") {
      TestAppearance();
    } else {
      throw std::runtime_error("unknown test case: " + name);
    }
    std::cout << name << " passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
