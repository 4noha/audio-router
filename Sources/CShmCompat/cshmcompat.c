#include "cshmcompat.h"
#include <sys/mman.h>
#include <fcntl.h>

/* C コンパイラが正規の可変長呼び出しを発行するので mode は正しく渡る。 */
int cshm_open_create(const char *name) {
    return shm_open(name, O_RDWR | O_CREAT, 0666);
}

int cshm_open_rw(const char *name) {
    return shm_open(name, O_RDWR);
}
