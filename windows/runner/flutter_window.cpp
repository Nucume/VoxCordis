#include "flutter_window.h"

#include <commctrl.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "comctl32.lib")

namespace {

// Sent by the tray icon on clicks.
constexpr UINT kTrayMessage = WM_APP + 0x51;
constexpr UINT kTrayOpen = 1;
constexpr UINT kTrayQuit = 2;

// Explorer restarted: the icon has to be added again.
const UINT kTaskbarCreated = RegisterWindowMessage(L"TaskbarCreated");

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "voxcordis/tray",
          &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "show") {
          result->Success(flutter::EncodableValue(ShowTray()));
        } else if (call.method_name() == "hide") {
          HideTray();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  view_hwnd_ = flutter_controller_->view()->GetNativeWindow();
  SetWindowSubclass(view_hwnd_, ViewSubclassProc, 1,
                    reinterpret_cast<DWORD_PTR>(this));
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "voxcordis/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "maxButton") {
          result->NotImplemented();
          return;
        }
        // [left, top, right, bottom], or null when VoxCordis' bar is off.
        max_button_ = {};
        const auto* rect = std::get_if<std::vector<flutter::EncodableValue>>(
            call.arguments());
        if (rect != nullptr && rect->size() == 4) {
          LONG side[4];
          for (size_t i = 0; i < 4; i++) {
            const auto* v = std::get_if<double>(&(*rect)[i]);
            side[i] = v == nullptr ? 0 : static_cast<LONG>(*v + 0.5);
          }
          max_button_ = {side[0], side[1], side[2], side[3]};
        }
        if (IsRectEmpty(&max_button_)) SetMaxButtonState(false, false);
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

bool FlutterWindow::ShowTray() {
  if (tray_shown_) {
    return true;
  }
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayMessage;
  tray_icon_.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"VoxCordis");
  tray_shown_ = Shell_NotifyIcon(NIM_ADD, &tray_icon_) != FALSE;
  return tray_shown_;
}

void FlutterWindow::HideTray() {
  if (tray_shown_) {
    Shell_NotifyIcon(NIM_DELETE, &tray_icon_);
    tray_shown_ = false;
  }
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenu(menu, MF_STRING, kTrayOpen, L"Open VoxCordis");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kTrayQuit, L"Quit VoxCordis");
  POINT point;
  GetCursorPos(&point);
  // Without this the menu stays open after clicking elsewhere.
  SetForegroundWindow(GetHandle());
  const UINT command = static_cast<UINT>(
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                     point.x, point.y, 0, GetHandle(), nullptr));
  PostMessage(GetHandle(), WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (command == kTrayOpen) {
    tray_channel_->InvokeMethod("open", nullptr);
  } else if (command == kTrayQuit) {
    tray_channel_->InvokeMethod("quit", nullptr);
  }
}

// The Flutter view lets the pointer through over the maximise button, so
// the hit test reaches the top-level window (MessageHandler), which answers
// HTMAXBUTTON.
LRESULT CALLBACK FlutterWindow::ViewSubclassProc(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam,
                                                 UINT_PTR id, DWORD_PTR data) {
  auto* self = reinterpret_cast<FlutterWindow*>(data);
  if (message == WM_NCHITTEST && self->OverMaxButton(lparam)) {
    return HTTRANSPARENT;
  }
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(hwnd, ViewSubclassProc, id);
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

bool FlutterWindow::OverMaxButton(LPARAM screen_point) const {
  if (view_hwnd_ == nullptr || IsRectEmpty(&max_button_)) {
    return false;
  }
  POINT point = {GET_X_LPARAM(screen_point), GET_Y_LPARAM(screen_point)};
  ScreenToClient(view_hwnd_, &point);
  return PtInRect(&max_button_, point) != FALSE;
}

// Tells the title bar to light the button up, as Flutter no longer sees the
// pointer there.
void FlutterWindow::SetMaxButtonState(bool hover, bool down) {
  if (hover == max_hover_ && down == max_down_) {
    return;
  }
  max_hover_ = hover;
  max_down_ = down;
  if (window_channel_) {
    window_channel_->InvokeMethod(
        "maxButtonState",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableList{
            flutter::EncodableValue(hover), flutter::EncodableValue(down)}));
  }
}

void FlutterWindow::OnDestroy() {
  HideTray();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // VoxCordis' maximise button, as Windows sees it (see ViewSubclassProc).
  switch (message) {
    case WM_NCHITTEST:
      if (OverMaxButton(lparam)) {
        return HTMAXBUTTON;
      }
      break;
    case WM_NCMOUSEMOVE:
      if (wparam == HTMAXBUTTON) {
        if (!max_hover_) {
          TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE | TME_NONCLIENT,
                                   hwnd, 0};
          TrackMouseEvent(&track);
        }
        SetMaxButtonState(true, max_down_);
        return 0;
      }
      SetMaxButtonState(false, false);
      break;
    case WM_NCMOUSELEAVE:
      SetMaxButtonState(false, false);
      break;
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK:
      if (wparam == HTMAXBUTTON) {
        // Not DefWindowProc: it would draw the classic button over ours.
        SetMaxButtonState(true, true);
        return 0;
      }
      break;
    case WM_NCLBUTTONUP:
      if (wparam == HTMAXBUTTON) {
        const bool clicked = max_down_;
        SetMaxButtonState(true, false);
        if (clicked) {
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        }
        return 0;
      }
      break;
  }

  if (message == kTaskbarCreated && tray_shown_) {
    Shell_NotifyIcon(NIM_ADD, &tray_icon_);
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case kTrayMessage:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
          tray_channel_->InvokeMethod("open", nullptr);
          return 0;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          ShowTrayMenu();
          return 0;
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
