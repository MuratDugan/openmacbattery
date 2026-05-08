#ifndef BATTRACKER_CPROCINFO_SHIM_H
#define BATTRACKER_CPROCINFO_SHIM_H

#include <stdint.h>
#include <sys/types.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <libproc.h>
#include <errno.h>
#include <unistd.h>

// Swift'ten erişebilmek için sabit/struct expose ediyoruz.
// rusage_info_v6 macOS 14+'da public; eski sürümlerde V4 fallback kullanırız.

static inline int bt_rusage_info_size_v6(void) { return (int)sizeof(struct rusage_info_v6); }
static inline int bt_rusage_info_size_v4(void) { return (int)sizeof(struct rusage_info_v4); }

// V6 alanları için Swift'ten direkt erişim — Swift importer bazı bitfield'larla zorlanıyor.
typedef struct {
    uint64_t user_time_ns;
    uint64_t system_time_ns;
    uint64_t pkg_idle_wakeups;
    uint64_t interrupt_wakeups;
    uint64_t diskio_bytesread;
    uint64_t diskio_byteswritten;
    uint64_t billed_energy;
    uint64_t serviced_energy;
    uint64_t runnable_time_ns;
    int      version;        // 4 veya 6
    int      ok;             // 1 başarı, 0 fail (errno bt_last_errno ile)
} bt_rusage_t;

static inline bt_rusage_t bt_proc_rusage(pid_t pid) {
    bt_rusage_t out;
    out.user_time_ns = 0;
    out.system_time_ns = 0;
    out.pkg_idle_wakeups = 0;
    out.interrupt_wakeups = 0;
    out.diskio_bytesread = 0;
    out.diskio_byteswritten = 0;
    out.billed_energy = 0;
    out.serviced_energy = 0;
    out.runnable_time_ns = 0;
    out.version = 0;
    out.ok = 0;

    struct rusage_info_v6 ru6;
    int ret = proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ru6);
    if (ret == 0) {
        out.user_time_ns        = ru6.ri_user_time;
        out.system_time_ns      = ru6.ri_system_time;
        out.pkg_idle_wakeups    = ru6.ri_pkg_idle_wkups;
        out.interrupt_wakeups   = ru6.ri_interrupt_wkups;
        out.diskio_bytesread    = ru6.ri_diskio_bytesread;
        out.diskio_byteswritten = ru6.ri_diskio_byteswritten;
        out.billed_energy       = ru6.ri_billed_energy;
        out.serviced_energy     = ru6.ri_serviced_energy;
        out.runnable_time_ns    = ru6.ri_runnable_time;
        out.version = 6;
        out.ok = 1;
        return out;
    }

    // V6 desteklenmiyorsa V4 ile dene (energy field'ları yok, billed_energy=0 kalır)
    struct rusage_info_v4 ru4;
    ret = proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ru4);
    if (ret == 0) {
        out.user_time_ns        = ru4.ri_user_time;
        out.system_time_ns      = ru4.ri_system_time;
        out.pkg_idle_wakeups    = ru4.ri_pkg_idle_wkups;
        out.interrupt_wakeups   = ru4.ri_interrupt_wkups;
        out.diskio_bytesread    = ru4.ri_diskio_bytesread;
        out.diskio_byteswritten = ru4.ri_diskio_byteswritten;
        out.runnable_time_ns    = ru4.ri_runnable_time;
        out.version = 4;
        out.ok = 1;
        return out;
    }

    return out;  // ok=0
}

typedef struct {
    uint64_t start_tvsec;
    uint32_t ppid;
    uint32_t uid;
    int      ok;
} bt_procshort_t;

static inline bt_procshort_t bt_proc_shortinfo(pid_t pid) {
    bt_procshort_t out = {0, 0, 0, 0};
    struct proc_bsdshortinfo info;
    int sz = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof(info));
    if (sz == sizeof(info)) {
        out.start_tvsec = info.pbsi_status; // not used; placeholder
        out.ppid = info.pbsi_ppid;
        out.uid  = info.pbsi_uid;
        out.ok = 1;
    }
    return out;
}

// PROC_PIDTBSDINFO başlangıç zamanını veriyor (saniye + usec)
typedef struct {
    uint64_t start_tvsec;
    uint64_t start_tvusec;
    uint32_t ppid;
    uint32_t uid;
    int      ok;
} bt_procbsd_t;

static inline bt_procbsd_t bt_proc_bsdinfo(pid_t pid) {
    bt_procbsd_t out = {0, 0, 0, 0, 0};
    struct proc_bsdinfo info;
    int sz = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (sz == sizeof(info)) {
        out.start_tvsec  = info.pbi_start_tvsec;
        out.start_tvusec = info.pbi_start_tvusec;
        out.ppid = info.pbi_ppid;
        out.uid  = info.pbi_uid;
        out.ok = 1;
    }
    return out;
}

// Tüm PID listesini döndür. Caller buffer alanını yönetir.
// Dönüş: yazılan PID sayısı (negatifse hata)
static inline int bt_listallpids(pid_t *buf, int capacity) {
    return proc_listallpids(buf, capacity * (int)sizeof(pid_t)) ;
}

static inline int bt_proc_path(pid_t pid, char *buf, int buflen) {
    return proc_pidpath(pid, buf, (uint32_t)buflen);
}

static inline int bt_errno(void) { return errno; }

// IOKit power messages — Swift'e import edilemediği için sabit olarak veriyoruz.
// IOMessage.h: iokit_common_msg(x) = sys_iokit | sub_iokit_common | x
//   sys_iokit         = 0x38000000 (err_system(0x38))
//   sub_iokit_common  = 0x00000000
static const uint32_t BT_kIOMessageCanSystemSleep     = 0x38000270;
static const uint32_t BT_kIOMessageSystemWillSleep    = 0x38000280;
static const uint32_t BT_kIOMessageSystemHasPoweredOn = 0x38000300;

#endif
