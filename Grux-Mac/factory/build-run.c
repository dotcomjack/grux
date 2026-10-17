#include <stdio.h>

int main(void) {
#if defined(_WIN32)
    const char *os = "windows";
#else
    const char *os = "linux";
#endif
    if (printf("factory-run %s\n", os) < 0) {
        return 1;
    }
    return 0;
}
