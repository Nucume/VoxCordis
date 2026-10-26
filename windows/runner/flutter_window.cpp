#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

#pragma comment(lib, "shell32.lib")

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
