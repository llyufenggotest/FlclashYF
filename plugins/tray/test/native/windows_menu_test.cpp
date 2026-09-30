#include "../../windows/tray_menu_icons.h"
#include "../../windows/tray_menu_session.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <shellapi.h>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <windows.h>

#define private public
#include "../../windows/tray_plugin.h"
#undef private
#include "../../windows/tray_plugin.cpp"

using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;

void Check(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}

class Messenger : public flutter::BinaryMessenger {
public:
  mutable int selected = 0;
  void Send(const std::string &, const uint8_t *message, size_t size,
            flutter::BinaryReply = nullptr) const override {
    auto call = flutter::StandardMethodCodec::GetInstance().DecodeMethodCall(
        message, size);
    if (call->method_name() == "onMenuItemSelected") {
      selected =
          std::get<int>(std::get<Map>(*call->arguments()).at(Value("id")));
    }
  }
  void SetMessageHandler(const std::string &,
                         flutter::BinaryMessageHandler) override {}
};

Map Node(int id) {
  return {{Value("type"), Value("checkbox")},
          {Value("id"), Value(id)},
          {Value("key"), Value("node-" + std::to_string(id))},
          {Value("label"), Value("香港 & A")},
          {Value("sublabel"), Value("42 ms")},
          {Value("checked"), Value(false)}};
}

Map Group(const char *name, List items) {
  return {{Value("type"), Value("submenu")},
          {Value("label"), Value(name)},
          {Value("items"), Value(std::move(items))}};
}

std::wstring Label(HMENU menu, UINT position) {
  wchar_t label[256]{};
  ::GetMenuStringW(menu, position, label, 256, MF_BYPOSITION);
  return label;
}

int main() {
  try {
    Messenger messenger;
    auto channel = std::make_unique<flutter::MethodChannel<Value>>(
        &messenger, "tray", &flutter::StandardMethodCodec::GetInstance());
    tray::TrayPlugin plugin(nullptr, std::move(channel));
    List nodes;
    for (int i = 0; i < 500; ++i)
      nodes.emplace_back(Node(1024 + i));
    nodes.emplace_back(Map{{Value("type"), Value("action")},
                           {Value("label"), Value("Delay test")},
                           {Value("id"), Value(4000)},
                           {Value("keepsMenuOpen"), Value(true)}});
    plugin.SetMenu(
        {Value(Group("Proxy", nodes)),
         Value(Group("Other", {Value(Group("Nested", {Value(Node(5000))}))}))});
    HMENU first = ::GetSubMenu(plugin.menu_, 0);
    HMENU other = ::GetSubMenu(plugin.menu_, 1);
    Check(::GetMenuItemCount(plugin.menu_) == 2, "root menu missing groups");
    Check(::GetMenuItemCount(first) == 0 && ::GetMenuItemCount(other) == 0,
          "unopened submenus were populated");

    Map update{{Value("key"), Value("node-1024")},
               {Value("sublabel"), Value("Timeout")},
               {Value("sublabelStyle"), Value("destructive")},
               {Value("checked"), Value(true)}};
    Check(plugin.UpdateMenuItems({Value(update)}), "deferred update rejected");
    Check(::GetMenuItemCount(first) == 0, "update materialized a submenu");
    Check(
        !plugin.UpdateMenuItems({Value(Map{{Value("key"), Value("node-1024")},
                                           {Value("label"), Value("wrong")}}),
                                 Value(Map{{Value("key"), Value("missing")}})}),
        "invalid batch was accepted");

    HWND owner = ::CreateWindowExW(WS_EX_TOOLWINDOW, L"STATIC", L"", WS_POPUP,
                                   0, 0, 0, 0, nullptr, nullptr,
                                   ::GetModuleHandleW(nullptr), nullptr);
    Check(owner != nullptr, "test owner creation failed");
    {
      tray::TrayMenuSession session(
          owner, plugin.persistent_menu_items_,
          [&](int id) { plugin.SendMenuSelection(id); },
          [&](HMENU menu) { plugin.MaterializeMenu(menu); },
          [&](HMENU menu) { plugin.open_menus_.erase(menu); });
      ::SendMessageW(owner, WM_INITMENUPOPUP, reinterpret_cast<WPARAM>(first),
                     0);
      Check(::GetMenuItemCount(first) == 501, "first submenu not populated");
      Check(::GetMenuItemCount(other) == 0,
            "sibling submenu populated eagerly");
      Check(Label(first, 0) == L"香港 && A\tTimeout",
            "deferred label update lost");
      Check((::GetMenuState(first, 0, MF_BYPOSITION) & MF_CHECKED) != 0,
            "deferred checkmark lost");
      Check(::GetMenuItemID(first, 0) == 1024, "command id changed");
      ::SendMessageW(owner, WM_INITMENUPOPUP, reinterpret_cast<WPARAM>(first),
                     0);
      Check(::GetMenuItemCount(first) == 501, "reopening duplicated children");
      Check(plugin.UpdateMenuItems(
                {Value(Map{{Value("key"), Value("node-1024")},
                           {Value("sublabel"), Value("17 ms")}})}),
            "visible update rejected");
      Check(Label(first, 0) == L"香港 && A\t17 ms", "visible update lost");
      Check(plugin.persistent_menu_items_.count(4000) == 1,
            "lazy action lost keepsMenuOpen");
      plugin.SendMenuSelection(::GetMenuItemID(first, 1));
      Check(messenger.selected == 1025, "lazy selection id did not round-trip");
      ::SendMessageW(owner, WM_INITMENUPOPUP, reinterpret_cast<WPARAM>(other),
                     0);
      HMENU nested = ::GetSubMenu(other, 0);
      Check(::GetMenuItemCount(nested) == 0, "nested submenu was eager");
      Check(plugin.UpdateMenuItems(
                {Value(Map{{Value("key"), Value("node-5000")},
                           {Value("sublabel"), Value("9 ms")}})}),
            "nested deferred update rejected");
      ::SendMessageW(owner, WM_INITMENUPOPUP, reinterpret_cast<WPARAM>(nested),
                     0);
      Check(Label(nested, 0) == L"香港 && A\t9 ms", "nested update lost");
      ::SendMessageW(owner, WM_UNINITMENUPOPUP,
                     reinterpret_cast<WPARAM>(first), 0);
      Check(plugin.open_menus_.count(first) == 0, "closed menu stayed active");
      Check(plugin.UpdateMenuItems(
                {Value(Map{{Value("key"), Value("node-1024")},
                           {Value("sublabel"), Value("77 ms")},
                           {Value("sublabelStyle"), Value("badge")}}),
                 Value(Map{{Value("key"), Value("node-5000")},
                           {Value("sublabel"), Value("88 ms")}})}),
            "cross-menu update rejected");
      Check(Label(first, 0) == L"香港 && A\t17 ms",
            "closed menu was refreshed eagerly");
      Check(Label(nested, 0) == L"香港 && A\t88 ms",
            "open menu did not refresh immediately");
      ::SendMessageW(owner, WM_INITMENUPOPUP,
                     reinterpret_cast<WPARAM>(first), 0);
      Check(Label(first, 0) == L"香港 && A\t77 ms",
            "reopened menu did not use cached delay");
      Check(::GetMenuItemCount(first) == 501 &&
                ::GetMenuItemID(first, 0) == 1024,
            "refresh changed menu structure");
      Check((::GetMenuState(first, 0, MF_BYPOSITION) & MF_CHECKED) != 0,
            "refresh lost selection");
    }
    ::DestroyWindow(owner);
    plugin.SetMenu({Value(Group("New", {Value(Node(6000))}))});
    Check(!plugin.UpdateMenuItems({Value(update)}),
          "stale key survived rebuild");
    Check(plugin.deferred_menus_.size() == 1, "stale deferred menus survived");
    Check(plugin.open_menus_.empty(), "rebuild retained open menus");
    plugin.Hide();
    Check(plugin.menu_entries_.empty() && plugin.deferred_menus_.empty(),
          "hide retained deferred state");
    std::cout << "Native Windows menu tests passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
