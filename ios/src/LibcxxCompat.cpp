// iOS 16 libc++ compatibility shims.
//
// The app is built with a recent Xcode SDK whose libc++ headers call
// std::__libcpp_verbose_abort (hardening / assertion failures). That function
// lives in the system libc++.1.dylib only on newer iOS releases. On iOS 16.3.x
// dyld refuses to launch the app with
//   "Symbol not found: __ZNSt3__122__libcpp_verbose_abortEPKcz".
//
// Defining it here makes the linker bind every reference (ours and those from
// the statically linked vcpkg dependencies) to this copy, so the app no longer
// imports it from the system dylib. Only C headers are included on purpose, so
// this file never sees libc++'s own (availability-annotated) declaration.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

namespace std {
inline namespace __1 {

__attribute__((noreturn, visibility("default")))
void __libcpp_verbose_abort(const char *format, ...);

void __libcpp_verbose_abort(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
    fputc('\n', stderr);
    fflush(stderr);
    abort();
}

} // namespace __1
} // namespace std
