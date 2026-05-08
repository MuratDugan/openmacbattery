#ifndef BATTRACKER_CSQLITE_SHIM_H
#define BATTRACKER_CSQLITE_SHIM_H

#include <sqlite3.h>

// Swift'ten SQLITE_TRANSIENT'ı doğru ifade etmek zor — helper expose ediyoruz.
static inline int bt_bind_text(sqlite3_stmt *stmt, int idx, const char *s) {
    if (s == 0) return sqlite3_bind_null(stmt, idx);
    return sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT);
}

#endif
