#include "system_info.h"

#include <knownfolders.h>
#include <shlobj.h>
#include <windows.h>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "shell32.lib")

namespace {

constexpr wchar_t kDisplayClass[] =
    L"SYSTEM\\ControlSet001\\Control\\Class\\"
    L"{4d36e968-e325-11ce-bfc1-08002be10318}";
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

}  // namespace

std::vector<std::pair<std::wstring, unsigned long long>> DisplayAdapters() {
  std::vector<std::pair<std::wstring, unsigned long long>> found;
  HKEY cls = nullptr;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kDisplayClass, 0, KEY_READ, &cls) !=
      ERROR_SUCCESS) {
    return found;
  }
  wchar_t sub[256];
  for (DWORD i = 0;; i++) {
    DWORD size = 256;
    if (RegEnumKeyExW(cls, i, sub, &size, nullptr, nullptr, nullptr,
                      nullptr) != ERROR_SUCCESS) {
      break;
    }
    HKEY adapter = nullptr;
    if (RegOpenKeyExW(cls, sub, 0, KEY_READ, &adapter) != ERROR_SUCCESS) {
      continue;
    }
    wchar_t name[256] = {};
    DWORD name_size = sizeof(name) - sizeof(wchar_t);
    unsigned long long bytes = 0;
    DWORD bytes_size = sizeof(bytes);
    DWORD type = 0;
    if (RegQueryValueExW(adapter, L"DriverDesc", nullptr, &type,
                         reinterpret_cast<LPBYTE>(name),
                         &name_size) == ERROR_SUCCESS &&
        (type == REG_SZ)) {
      // REG_QWORD, or 8 bytes of REG_BINARY: both are a little-endian number.
      if (RegQueryValueExW(adapter, L"HardwareInformation.qwMemorySize",
                           nullptr, &type, reinterpret_cast<LPBYTE>(&bytes),
                           &bytes_size) != ERROR_SUCCESS) {
        bytes = 0;
      }
      found.emplace_back(name, bytes);
    }
    RegCloseKey(adapter);
  }
  RegCloseKey(cls);
  return found;
}

std::wstring KnownFolderPath(const std::wstring& name) {
  const KNOWNFOLDERID* id = nullptr;
  if (name == L"desktop") id = &FOLDERID_Desktop;
  else if (name == L"documents") id = &FOLDERID_Documents;
  else if (name == L"downloads") id = &FOLDERID_Downloads;
  else if (name == L"music") id = &FOLDERID_Music;
  else if (name == L"pictures") id = &FOLDERID_Pictures;
  else if (name == L"videos") id = &FOLDERID_Videos;
  if (id == nullptr) return L"";
  PWSTR path = nullptr;
  std::wstring out;
  if (SUCCEEDED(SHGetKnownFolderPath(*id, 0, nullptr, &path)) &&
      path != nullptr) {
    out = path;
  }
  CoTaskMemFree(path);
  return out;
}

bool SetLoginItem(const std::wstring& command) {
  if (command.empty()) {
    const LSTATUS r =
        RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, L"VoxCordis");
    return r == ERROR_SUCCESS || r == ERROR_FILE_NOT_FOUND;
  }
  return RegSetKeyValueW(HKEY_CURRENT_USER, kRunKey, L"VoxCordis", REG_SZ,
                         command.c_str(),
                         static_cast<DWORD>((command.size() + 1) *
                                            sizeof(wchar_t))) == ERROR_SUCCESS;
}

bool ReadUserDword(const std::wstring& key, const std::wstring& name,
                   unsigned long* value) {
  DWORD data = 0;
  DWORD size = sizeof(data);
  if (RegGetValueW(HKEY_CURRENT_USER, key.c_str(), name.c_str(), RRF_RT_DWORD,
                   nullptr, &data, &size) != ERROR_SUCCESS) {
    return false;
  }
  *value = data;
  return true;
}

std::wstring ProcessImageName(unsigned long pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return L"";
  wchar_t path[MAX_PATH * 2];
  DWORD size = static_cast<DWORD>(sizeof(path) / sizeof(path[0]));
  std::wstring name;
  if (QueryFullProcessImageNameW(process, 0, path, &size)) {
    name.assign(path, size);
    const size_t slash = name.find_last_of(L"\\/");
    if (slash != std::wstring::npos) name.erase(0, slash + 1);
  }
  CloseHandle(process);
  return name;
}

bool OpenWithShell(const std::wstring& target) {
  const HINSTANCE r = ShellExecuteW(nullptr, L"open", target.c_str(), nullptr,
                                    nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<INT_PTR>(r) > 32;
}
