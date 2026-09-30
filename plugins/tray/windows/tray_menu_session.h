#ifndef FLUTTER_PLUGIN_TRAY_MENU_SESSION_H_
#define FLUTTER_PLUGIN_TRAY_MENU_SESSION_H_

#include <windows.h>

#include <functional>
#include <unordered_set>

namespace tray {

class TrayMenuSession {
 public:
  TrayMenuSession(HWND owner, const std::unordered_set<UINT>& persistent_items,
                  std::function<void(int)> on_selected,
                  std::function<void(HMENU)> on_open,
                  std::function<void(HMENU)> on_close = {});
  ~TrayMenuSession();

  TrayMenuSession(const TrayMenuSession&) = delete;
  TrayMenuSession& operator=(const TrayMenuSession&) = delete;

  static void InvalidateItem(HMENU menu, UINT position);

 private:
  static LRESULT CALLBACK FilterProc(int code, WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK OwnerProc(HWND window, UINT message, WPARAM wparam,
                                    LPARAM lparam, UINT_PTR id, DWORD_PTR data);
  bool Filter(const MSG& message);

  static thread_local TrayMenuSession* current_;
  TrayMenuSession* previous_ = nullptr;
  HWND owner_;
  bool subclassed_ = false;
  HHOOK hook_ = nullptr;
  HMENU selected_menu_ = nullptr;
  UINT selected_id_ = 0;
  const std::unordered_set<UINT>& persistent_items_;
  std::function<void(int)> on_selected_;
  std::function<void(HMENU)> on_open_;
  std::function<void(HMENU)> on_close_;
};

}  // namespace tray

#endif
