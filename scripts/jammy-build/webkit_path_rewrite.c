// LD_PRELOAD shim that rewrites WebKit's hardcoded /usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/
// process paths to our AppImage-internal copy. WebKitGTK 4.0 bakes
// LIBEXECDIR=/usr/lib/x86_64-linux-gnu at compile time; there's no env var
// override (WEBKIT_EXEC_PATH was removed before the 4.0 series). On a noble
// host where that directory doesn't exist, WebKit's `g_spawn_*` call fails
// before any UI shows. We intercept execve / posix_spawn / posix_spawnp and
// rewrite the path prefix so the process spawns from inside the AppDir.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <spawn.h>

static const char HOST_PREFIX[]  = "/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/";
static const size_t HOST_PREFIX_LEN = sizeof(HOST_PREFIX) - 1;

static const char* rewrite(const char* pathname, char* buf, size_t bufsz) {
    if (!pathname) return pathname;
    if (strncmp(pathname, HOST_PREFIX, HOST_PREFIX_LEN) != 0) return pathname;
    const char* appdir = getenv("APPDIR");
    if (!appdir || !*appdir) return pathname;
    snprintf(buf, bufsz, "%s/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/%s",
             appdir, pathname + HOST_PREFIX_LEN);
    return buf;
}

typedef int (*execve_t)(const char*, char* const[], char* const[]);
typedef int (*execv_t)(const char*, char* const[]);
typedef int (*posix_spawn_t)(pid_t*, const char*, const posix_spawn_file_actions_t*,
                              const posix_spawnattr_t*, char* const[], char* const[]);

int execve(const char* path, char* const argv[], char* const envp[]) {
    static execve_t real = NULL;
    if (!real) real = (execve_t)dlsym(RTLD_NEXT, "execve");
    char buf[4096];
    return real(rewrite(path, buf, sizeof(buf)), argv, envp);
}

int execv(const char* path, char* const argv[]) {
    static execv_t real = NULL;
    if (!real) real = (execv_t)dlsym(RTLD_NEXT, "execv");
    char buf[4096];
    return real(rewrite(path, buf, sizeof(buf)), argv);
}

int posix_spawn(pid_t* pid, const char* path,
                const posix_spawn_file_actions_t* fa,
                const posix_spawnattr_t* attr,
                char* const argv[], char* const envp[]) {
    static posix_spawn_t real = NULL;
    if (!real) real = (posix_spawn_t)dlsym(RTLD_NEXT, "posix_spawn");
    char buf[4096];
    return real(pid, rewrite(path, buf, sizeof(buf)), fa, attr, argv, envp);
}

int posix_spawnp(pid_t* pid, const char* path,
                 const posix_spawn_file_actions_t* fa,
                 const posix_spawnattr_t* attr,
                 char* const argv[], char* const envp[]) {
    static posix_spawn_t real = NULL;
    if (!real) real = (posix_spawn_t)dlsym(RTLD_NEXT, "posix_spawnp");
    char buf[4096];
    return real(pid, rewrite(path, buf, sizeof(buf)), fa, attr, argv, envp);
}

// dlopen() hook — WebKit loads the injected-bundle .so via dlopen with an
// absolute path, which bypasses LD_LIBRARY_PATH and our execve hook.
typedef void* (*dlopen_t)(const char*, int);
void* dlopen(const char* filename, int flag) {
    static dlopen_t real = NULL;
    if (!real) real = (dlopen_t)dlsym(RTLD_NEXT, "dlopen");
    char buf[4096];
    return real(rewrite(filename, buf, sizeof(buf)), flag);
}
