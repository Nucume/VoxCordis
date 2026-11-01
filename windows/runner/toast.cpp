#include "toast.h"

#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

#include <deque>

#pragma comment(lib, "advapi32.lib")

namespace {

using winrt::Windows::Data::Xml::Dom::XmlDocument;
using winrt::Windows::UI::Notifications::ToastNotification;
using winrt::Windows::UI::Notifications::ToastNotificationManager;

std::wstring XmlEscape(const std::wstring& text) {
  std::wstring out;
  for (wchar_t c : text) {
    switch (c) {
      case L'&': out += L"&amp;"; break;
      case L'<': out += L"&lt;"; break;
      case L'>': out += L"&gt;"; break;
      case L'"': out += L"&quot;"; break;
      case L'\'': out += L"&apos;"; break;
      default: out += c;
    }
  }
  return out;
}

// A shown toast only reports clicks while its object is alive.
std::deque<ToastNotification>& Shown() {
  static std::deque<ToastNotification> shown;
  return shown;
}

// Gives the app identity a name and icon, so a toast says "VoxCordis".
void RegisterApp(const std::wstring& app_id, const std::wstring& icon_path) {
  const std::wstring key = L"Software\\Classes\\AppUserModelId\\" + app_id;
  const auto set = [&key](const wchar_t* name, const std::wstring& value) {
    RegSetKeyValueW(HKEY_CURRENT_USER, key.c_str(), name, REG_SZ, value.c_str(),
                    static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  };
  set(L"DisplayName", L"VoxCordis");
  if (!icon_path.empty()) set(L"IconUri", icon_path);
}

}  // namespace

bool ShowToast(const std::wstring& app_id, const std::wstring& title,
               const std::wstring& body, const std::wstring& image_path,
               const std::wstring& icon_path, HWND window, UINT click_message) {
  RegisterApp(app_id, icon_path);
  try {
    std::wstring xml = L"<toast><visual><binding template=\"ToastGeneric\">";
    if (!image_path.empty()) {
      std::wstring uri = L"file:///" + image_path;
      for (wchar_t& c : uri) {
        if (c == L'\\') c = L'/';
      }
      xml += L"<image placement=\"appLogoOverride\" hint-crop=\"circle\" src=\"" +
             XmlEscape(uri) + L"\"/>";
    }
    xml += L"<text>" + XmlEscape(title) + L"</text><text>" + XmlEscape(body) +
           L"</text></binding></visual></toast>";

    XmlDocument doc;
    doc.LoadXml(winrt::hstring(xml));
    ToastNotification toast(doc);
    toast.Activated([window, click_message](auto&&, auto&&) {
      // On a thread of Windows' own: hand over to the window's thread.
      PostMessage(window, click_message, 0, 0);
    });
    ToastNotificationManager::CreateToastNotifier(winrt::hstring(app_id))
        .Show(toast);
    auto& shown = Shown();
    shown.push_back(toast);
    if (shown.size() > 20) shown.pop_front();
    return true;
  } catch (winrt::hresult_error const&) {
    return false;
  }
}
