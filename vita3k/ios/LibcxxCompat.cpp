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
//
// The second half does the same for the floating-point std::to_chars overloads,
// which iOS 16.3.1's libc++ also lacks ("Symbol not found: __ZNSt3__18to_charsEPcS0_d").
// They are built on snprintf and are not bit-exact with libc++ in every corner
// case, but they round-trip (shortest form) and honour format/precision.

#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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


// ---- floating-point std::to_chars ------------------------------------------
// Local mirrors of the libc++ types. Layout/ABI matches (errc is an int enum,
// to_chars_result is {char*, errc}); only the mangled names of the functions
// below matter to the linker, and they depend on std::__1::chars_format.

enum class errc : int { value_too_large = EOVERFLOW };
enum class chars_format : int { scientific = 1, fixed = 2, hex = 4, general = 3 };
struct to_chars_result {
    char *ptr;
    errc ec;
};

namespace {

// 0 = float, 1 = double / long double (identical on arm64 Apple).
bool round_trips(const char *text, long double v, int kind) {
    if (kind == 0) {
        return strtof(text, nullptr) == static_cast<float>(v);
    }
    return strtod(text, nullptr) == static_cast<double>(v);
}

// Writes into tmp using conversion 'g', 'f', 'e' or 'a'; precision < 0 means
// "shortest representation that round-trips".
int render(char *tmp, size_t cap, long double v, char conv, int precision, int kind) {
    char fmt[8] = {'%', '.', '*', 'L', conv, 0};
    if (!isfinite(static_cast<double>(v))) {
        return snprintf(tmp, cap, "%Lg", v);
    }
    if (conv == 'a') {
        return snprintf(tmp, cap, "%La", v);
    }
    if (precision >= 0) {
        return snprintf(tmp, cap, fmt, precision, v);
    }
    const int max_precision = kind == 0 ? 9 : 17;
    const int start = conv == 'g' ? 1 : 0;
    int n = 0;
    for (int p = start; p <= max_precision + 2; ++p) {
        n = snprintf(tmp, cap, fmt, p, v);
        if (n < 0 || static_cast<size_t>(n) >= cap || round_trips(tmp, v, kind)) {
            break;
        }
    }
    return n;
}

to_chars_result emit(char *first, char *last, long double v, chars_format f, int precision, int kind) {
    char tmp[1100];
    char conv = 'g';
    switch (f) {
    case chars_format::fixed: conv = 'f'; break;
    case chars_format::scientific: conv = 'e'; break;
    case chars_format::hex: conv = 'a'; break;
    default: conv = 'g'; break;
    }
    int n = render(tmp, sizeof(tmp), v, conv, precision, kind);
    const char *src = tmp;
    if (n > 0 && f == chars_format::hex) {
        // std hex output has no "0x" prefix.
        const char *x = strstr(tmp, "0x");
        if (x) {
            memmove(const_cast<char *>(x), x + 2, strlen(x + 2) + 1);
            n -= 2;
        }
    }
    if (n < 0 || n > last - first) {
        return {last, errc::value_too_large};
    }
    memcpy(first, src, static_cast<size_t>(n));
    return {first + n, errc(0)};
}

} // namespace

#define TSUBOMI_EXPORT __attribute__((visibility("default"), used))

TSUBOMI_EXPORT to_chars_result to_chars(char *first, char *last, float v) {
    return emit(first, last, v, chars_format::general, -1, 0);
}
TSUBOMI_EXPORT to_chars_result to_chars(char *first, char *last, double v) {
    return emit(first, last, v, chars_format::general, -1, 1);
}
TSUBOMI_EXPORT to_chars_result to_chars(char *first, char *last, long double v) {
    return emit(first, last, v, chars_format::general, -1, 1);
}
TSUBOMI_EXPORT to_chars_result to_chars(char *first, char *last, float v, chars_format f) {
    return emit(first, last, v, f, -1, 0);
}
TSUBOMI_EXPORT to_chars_result to_chars(char *first, char *last, double v, chars_format f) {
    return emit(first, last, v, f, -1, 1);
}
TSUBOMI_EXPORT to_chars_result to_chars(char *first, char *last, long double v, chars_format f) {
    return emit(first, last, v, f, -1, 1);
}
TSUBOMI_EXPORT to_chars_result to_chars(char *first, char *last, float v, chars_format f, int precision) {
    return emit(first, last, v, f, precision, 0);
}
TSUBOMI_EXPORT to_chars_result to_chars(char *first, char *last, double v, chars_format f, int precision) {
    return emit(first, last, v, f, precision, 1);
}
TSUBOMI_EXPORT to_chars_result to_chars(char *first, char *last, long double v, chars_format f, int precision) {
    return emit(first, last, v, f, precision, 1);
}

} // namespace __1
} // namespace std
