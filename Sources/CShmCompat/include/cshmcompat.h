#ifndef CSHMCOMPAT_H
#define CSHMCOMPAT_H

/* shm_open は C 可変長関数。Swift の dlsym 固定引数だと arm64 ABI で
   mode がゴミ化するため、C で正しい varargs を発行する非可変長ラッパを
   提供する。戻り値は fd（失敗時 -1, errno 設定）。 */
int cshm_open_create(const char *name); /* O_RDWR|O_CREAT, mode 0666 */
int cshm_open_rw(const char *name);     /* O_RDWR（既存を開く） */

#endif
