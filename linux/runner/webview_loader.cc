// Loads the plugins that need a library not every desktop has installed:
// the browser window (WebKitGTK) and video portraits (libmpv). They are not
// linked into the app (see linux/CMakeLists.txt), so these stand in for their
// register functions: without the library a plugin stays unregistered and
// the app starts anyway.
#include <dlfcn.h>
#include <limits.h>
#include <unistd.h>

#include <string>

#include <desktop_webview_window/desktop_webview_window_plugin.h>
#include <media_kit_video/media_kit_video_plugin.h>

namespace {

// WebKitGTK keeps cookies in memory only, unless told where to save them.
// Keeping them on disk lets the Soulkyn login last from one start of the app
// to the next, like WebView2 on Windows does by itself. The app's "Log out of
// Soulkyn" clears them. Looked up at run time, as WebKitGTK isn't linked.
void keep_cookies() {
  void* webkit = dlopen("libwebkit2gtk-4.1.so.0", RTLD_NOW | RTLD_NOLOAD);
  if (webkit == nullptr) return;
  using GetDefault = void* (*)();
  using GetCookies = void* (*)(void*);
  using SetStorage = void (*)(void*, const char*, int);
  auto get_default = reinterpret_cast<GetDefault>(
      dlsym(webkit, "webkit_web_context_get_default"));
  auto get_cookies = reinterpret_cast<GetCookies>(
      dlsym(webkit, "webkit_web_context_get_cookie_manager"));
  auto set_storage = reinterpret_cast<SetStorage>(
      dlsym(webkit, "webkit_cookie_manager_set_persistent_storage"));
  if (get_default == nullptr || get_cookies == nullptr ||
      set_storage == nullptr) {
    return;
  }
  void* manager = get_cookies(get_default());
  if (manager == nullptr) return;
  g_autofree gchar* dir =
      g_build_filename(g_get_user_data_dir(), APPLICATION_ID, nullptr);
  g_mkdir_with_parents(dir, 0700);
  g_autofree gchar* file = g_build_filename(dir, "browser-cookies.sqlite", nullptr);
  // WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE
  set_storage(manager, file, 1);
}

// Opens lib/<library> next to the executable and calls its [symbol].
bool load_plugin(FlPluginRegistrar* registrar, const char* library,
                 const char* symbol, const char* what) {
  char exe[PATH_MAX];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n <= 0) return false;
  exe[n] = '\0';
  std::string path(exe);
  path = path.substr(0, path.rfind('/')) + "/lib/" + library;

  void* plugin = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (plugin == nullptr) {
    g_message("%s unavailable: %s", what, dlerror());
    return false;
  }
  using Register = void (*)(FlPluginRegistrar*);
  auto register_plugin = reinterpret_cast<Register>(dlsym(plugin, symbol));
  if (register_plugin == nullptr) return false;
  register_plugin(registrar);
  return true;
}

}  // namespace

void desktop_webview_window_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  if (load_plugin(registrar, "libdesktop_webview_window_plugin.so",
                  "desktop_webview_window_plugin_register_with_registrar",
                  "Browser window")) {
    keep_cookies();
  }
}

namespace {

// The system's libmpv, in the order media_kit's Dart side looks for it, so
// both use the same one. Loaded for everyone to see, as the video plugin is
// built without a libmpv of its own (see linux/CMakeLists.txt).
bool load_libmpv() {
  for (const char* name : {"libmpv.so", "libmpv.so.2", "libmpv.so.1"}) {
    if (dlopen(name, RTLD_NOW | RTLD_GLOBAL) != nullptr) return true;
  }
  g_message("Video portraits unavailable: libmpv not found");
  return false;
}

}  // namespace

void media_kit_video_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  if (!load_libmpv()) return;
  load_plugin(registrar, "libmedia_kit_video_plugin.so",
              "media_kit_video_plugin_register_with_registrar",
              "Video portraits");
}
