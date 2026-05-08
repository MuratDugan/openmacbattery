# macOS Battery Tracker — Per-App Geçmiş Pil Tüketim Takibi

## 🎯 Amaç

macOS'ta (Apple Silicon, M-series) **uygulama / process bazında geçmişe dönük pil/enerji tüketimini** kayıt altına alan bir araç. Apple'ın yerleşik araçları (Activity Monitor, System Settings → Battery) sadece anlık veya en fazla son 12 saatlik rolling window verisi sunuyor. Hedef: "dün gece 02:00–08:00 arası pilim niye %40 düşmüş, hangi uygulama yüzünden?" sorusuna cevap verebilen kalıcı bir log + sorgu sistemi.

İkincil hedef: aracın kendisi pili yememeli. Sampler hedefi: **pildeyken < 20 J/saat** (yaklaşık 5–6 mW ortalama, ihmal edilebilir).

## 🖥️ Hedef Sistem

- **Donanım:** MacBook Air M4, 16 GB RAM
- **OS:** macOS 14+ (Sonoma / Sequoia). 13'te V6 yok, V4 fallback ile kısmen çalışır.
- **Mimari:** arm64 (Apple Silicon)
- **Kullanıcı:** Tek kullanıcı, kişisel makine, ad-hoc imzayla yerel kullanım

## 🏗️ Mimari

Üç bileşenli sistem, tek binary:

```
┌──────────────────────────────────────────────────────────┐
│  1. Sampler (CLI binary, Swift)                          │
│     - Her 60 saniyede bir tüm process'leri tarar         │
│     - proc_pid_rusage(RUSAGE_INFO_V6 → V4 fallback)      │
│     - Bundle ID + display name çözer (cache'li)          │
│     - SQLite'a yazar (WAL mode)                          │
└──────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────┐
│  2. LaunchAgent (~/Library/LaunchAgents/...)             │
│     - Sampler'ı arka planda sürekli çalışır tutar        │
│     - Login'de otomatik başlar                           │
│     - KeepAlive throttle'lı (crash loop pil yemesin)     │
└──────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────┐
│  3. Query CLI (aynı binary, alt komut)                   │
│     - `battracker top --since 24h`                       │
│     - `battracker app Slack --since 7d`                  │
│     - `battracker timeline --from 2026-04-27T02:00`      │
│     - `battracker export --format csv`                   │
└──────────────────────────────────────────────────────────┘
```

İleride opsiyonel **Faz 2:** SwiftUI menu bar app + privileged helper ile `powermetrics` entegrasyonu. Şimdilik CLI yeterli.

## 📡 Veri Kaynağı: `proc_pid_rusage`

**Birincil kaynak.** Sudo gerektirmez ama erişim sınırları var (aşağıda).

```c
#include <libproc.h>
#include <sys/resource.h>

struct rusage_info_v6 ru;
int ret = proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ru);
// ret == -1 ve errno == EPERM ise: başka kullanıcı / korumalı process
// ret == -1 ve errno == EINVAL ise: V6 desteklenmiyor → V4 ile retry
```

`rusage_info_v6`'dan kullanılacak alanlar:

| Alan | Açıklama | Birim |
|------|----------|-------|
| `ri_pkg_idle_wkups` | Package idle wake-up sayısı | count |
| `ri_interrupt_wkups` | Interrupt wake-up sayısı | count |
| `ri_user_time` | Kullanıcı modu CPU zamanı | nanosaniye |
| `ri_system_time` | Sistem modu CPU zamanı | nanosaniye |
| `ri_billed_energy` | Bu process'e fatura edilen enerji | **Apple internal energy unit (≠ joule)** |
| `ri_serviced_energy` | Başkaları adına harcanan enerji | aynı internal unit |
| `ri_diskio_bytesread` | Disk okuma | byte |
| `ri_diskio_byteswritten` | Disk yazma | byte |
| `ri_runnable_time` | Runnable durum süresi | nanosaniye |

### ⚠️ `ri_billed_energy` hakkında dürüst olalım

Bu alan Apple tarafından **public olarak dokümante edilmedi.** Birimi joule **değil**; Apple'ın dahili "energy unit" havuzundan bir sayı (`task_power_info_v2` ile aynı). Açık kaynak referanslar (Stats, htop) bunu mutlak joule olarak göstermiyor — relatif "energy impact" puanı olarak kullanıyor.

Yaklaşımımız:
- **Raw değeri olduğu gibi sakla** (`energy_billed_raw`).
- Joule göstermek için **kalibrasyon faktörü** kullan: `joule = raw × ENERGY_UNIT_FACTOR`.
- Faktörü ampirik bul: bilinen yük altında (yt-dlp, cpuburn vb.) `powermetrics --show-process-energy` ile cross-check, lineer regresyonla katsayı çıkar. Bu kalibrasyon adımı **Phase 1 DoD'sine dahil**.
- Faktör bulunana / güvensiz olduğunda raporda joule yerine **"Energy Score"** göster, `*` ile kalibrasyon durumunu belirt.

### Process listesi alma

```c
int n = proc_listallpids(NULL, 0);
pid_t *pids = malloc(n * sizeof(pid_t));
proc_listallpids(pids, n * sizeof(pid_t));
```

### Bundle ID + display name çözme (cache'li)

Her sample'da 250 PID için `NSRunningApplication(processIdentifier:)` çağırmak pahalı. `(pid, start_time)` anahtarlı in-memory cache tut; PID reuse'da invalidate et.

```swift
struct ProcessKey: Hashable { let pid: pid_t; let startTimeSec: UInt64 }
var cache: [ProcessKey: (bundleId: String?, displayName: String?, execPath: String)]
```

GUI app'ler için `NSRunningApplication.bundleIdentifier` + `.localizedName`. Daemon/CLI için `proc_pidpath` + path parse fallback.

## 🔐 Erişim Sınırları (önemli)

`proc_pid_rusage` kullanıcının **kendi UID'sindeki** process'ler için çalışır. Aşağıdakiler için `EPERM` döner:
- WindowServer, kernel_task, launchd, coreaudiod gibi system daemon'lar (root/_windowserver vs.)
- Diğer kullanıcıların process'leri
- SIP korumalı bazı Apple process'leri (kısmen okunabilir, energy field'ları sıfır gelebilir)

**Sonuç:** Phase 1 root'suz çalışacak, attribution **eksik kalacak.** Bu açık raporda gösterilecek:

```
Identified: 73% (user-space apps)
Unattributed: 27% (system daemons + idle/baseline)
```

Phase 2'de privileged helper tool (`SMAppService`) eklendiğinde bu gap kapanır.

## 📡 Opsiyonel İkinci Kaynak: `powermetrics`

`sudo powermetrics --samplers tasks --show-process-energy --format plist` her process için `energy_impact` ve gerçek mW okuması verir. Phase 1'de **kalibrasyon için** kullanılacak; Phase 2'de privileged helper ile runtime'da.

Phase 1 manuel kalibrasyon:
```bash
battracker calibrate --duration 300
# 5 dakika boyunca paralel powermetrics + rusage örnekler,
# ENERGY_UNIT_FACTOR'ü hesaplar, meta tablosuna yazar
```

## 💤 Uyku/Uyanma Yönetimi

Mac uykudayken sampler çalışmamalı, uyandığında gap'i tanımalı.

```swift
import IOKit.pwr_mgt
// IORegisterForSystemPower:
//  kIOMessageSystemWillSleep      → "sleep_start" yaz, timer'ı durdur
//  kIOMessageSystemHasPoweredOn   → "sleep_end" yaz, gap'i hesapla, timer'ı yeniden başlat
```

DB'de `sleep_periods` tablosu, raporlarda exclude veya açıkça göster.

## 🗄️ SQLite Şeması

DB konumu: `~/Library/Application Support/BatteryTracker/data.db`
WAL mode (`PRAGMA journal_mode=WAL`), `synchronous=NORMAL`, `auto_vacuum=INCREMENTAL`.

```sql
CREATE TABLE samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,            -- Unix epoch (saniye)
    pid INTEGER NOT NULL,
    proc_start_sec INTEGER NOT NULL,       -- PID reuse tespiti için
    bundle_id TEXT,
    display_name TEXT,
    exec_path TEXT,
    cpu_user_ns INTEGER NOT NULL,          -- delta, sample aralığı için
    cpu_system_ns INTEGER NOT NULL,
    energy_billed_raw INTEGER,             -- Apple internal unit, kalibre EDİLMEMİŞ
    energy_serviced_raw INTEGER,
    pkg_idle_wakeups INTEGER,
    interrupt_wakeups INTEGER,
    disk_read_bytes INTEGER,
    disk_write_bytes INTEGER,
    is_on_battery INTEGER NOT NULL,
    battery_percent INTEGER,
    rusage_version INTEGER NOT NULL        -- 4 veya 6
);

CREATE INDEX idx_samples_time ON samples(timestamp);
CREATE INDEX idx_samples_bundle ON samples(bundle_id, timestamp);

CREATE TABLE hourly_aggregates (
    hour_epoch INTEGER NOT NULL,
    bundle_id TEXT NOT NULL,
    display_name TEXT,
    total_energy_raw INTEGER,
    total_cpu_ns INTEGER,
    total_wakeups INTEGER,
    sample_count INTEGER,
    avg_battery_percent REAL,
    on_battery_seconds INTEGER,
    PRIMARY KEY (hour_epoch, bundle_id)
);

CREATE TABLE sleep_periods (
    sleep_start INTEGER PRIMARY KEY,
    sleep_end INTEGER
);

CREATE TABLE battery_events (
    timestamp INTEGER PRIMARY KEY,
    event_type TEXT NOT NULL,              -- 'plugged_in', 'unplugged', 'low_battery'
    battery_percent INTEGER
);

CREATE TABLE meta (
    key TEXT PRIMARY KEY,
    value TEXT
);
-- meta key'leri: schema_version, energy_unit_factor,
--   energy_unit_calibrated_at, sampler_version
```

### Aggregate & Retention

- Günde ~1440 sample × ~250 process ≈ 360K satır.
- Her saat başı `hourly_aggregates`'e roll-up.
- Default retention: raw `samples` = 7 gün, `hourly_aggregates` = 180 gün.
- Prune sonrası `PRAGMA incremental_vacuum` (auto_vacuum=INCREMENTAL ile birlikte) — yoksa dosya küçülmez. Haftalık tam `VACUUM` AC'deyken.

## 🔧 CLI Komutları

Binary adı: `battracker`

```bash
# Daemon kontrolü (sudo gerekmez)
battracker daemon install
battracker daemon uninstall
battracker daemon status         # Çalışıyor mu, son sample, kalibrasyon durumu

# Kalibrasyon
battracker calibrate --duration 300   # powermetrics ile faktör çıkar (sudo ister)
battracker calibrate --show

# Sorgu komutları
battracker top --since 24h
battracker top --since 7d --limit 10
battracker top --on-battery --since 24h
battracker app Slack --since 7d
battracker app com.tinyspeck.slackmacgap
battracker timeline --from "2026-04-27 02:00" --to "2026-04-27 08:00"
battracker timeline --since 24h --top 5

# Veri yönetimi
battracker export --format csv --since 30d > out.csv
battracker export --format json --app Slack
battracker stats
battracker prune                              # retention + incremental_vacuum
battracker reset --confirm

# Debug
battracker sample --once --verbose
```

### Çıktı örneği — `battracker top --since 24h`

```
Top energy consumers — last 24 hours (12.4h on battery)
Energy unit: calibrated 2026-04-27 (factor 1.42e-9 J/unit, ±8%)

  RANK  APP                           ENERGY      CPU TIME    WAKEUPS    % OF IDENTIFIED
  ----  ----------------------------  ----------  ----------  ---------  ---------------
   1    Google Chrome                 ~4.2 kJ     2h 14m      1.2M       28.4%
   2    Slack                         ~1.8 kJ     45m         890K       12.1%
   3    Ryujinx                       ~1.5 kJ     28m         340K       10.2%
   4    Claude                        ~980 J      22m         210K        6.6%
  ...

Battery: 98% → 42% (−56% over 14.2h on battery, sleep excluded)
Identified: 73% of drain  |  Unattributed (system + baseline): 27%
* Energy values are estimates from Apple internal counters, calibrated against powermetrics.
```

Kalibre değilse joule yerine ham "Energy Score" göster.

## 📦 LaunchAgent plist

`~/Library/LaunchAgents/com.murat.battracker.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.murat.battracker</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/battracker</string>
        <string>daemon</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- KeepAlive dict: yalnız crash veya non-zero exit'te restart.
         ThrottleInterval crash loop'ta pil yemeyi engeller. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
        <key>Crashed</key><true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>/Users/USERNAME/Library/Logs/battracker.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/USERNAME/Library/Logs/battracker.error.log</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
```

`battracker daemon install` USERNAME'i çözer ve `launchctl bootstrap gui/$(id -u) ...` ile yükler. **Sudo gerekmez** — user-scope LaunchAgent.

## 🛠️ Tech Stack

- **Dil:** Swift 5.9+ (Apple Silicon native)
- **Build:** Swift Package Manager (`swift build -c release --arch arm64`)
- **Bağımlılıklar:**
  - `swift-argument-parser` — CLI komut yapısı
  - **SQLite:** `sqlite3` C API doğrudan (system framework, ek dependency yok). `SQLite.swift` opsiyonel; basit şema için overhead.
  - C interop ile `<libproc.h>`, `<sys/resource.h>`, `<IOKit/...>` direkt çağrı
- **Test:** XCTest — sample parsing, delta hesabı, PID reuse, retention/prune

### Proje yapısı

```
battracker/
├── Package.swift
├── Sources/
│   ├── BatTracker/
│   │   ├── main.swift
│   │   └── Commands/
│   │       ├── DaemonCommand.swift
│   │       ├── CalibrateCommand.swift
│   │       ├── TopCommand.swift
│   │       ├── AppCommand.swift
│   │       ├── TimelineCommand.swift
│   │       └── ExportCommand.swift
│   ├── BatTrackerCore/
│   │   ├── Sampler.swift            # DispatchSourceTimer ana loop
│   │   ├── ProcessInfo.swift        # proc_pid_rusage wrapper, V6→V4 fallback
│   │   ├── BundleResolver.swift     # PID → bundle ID, cache'li
│   │   ├── PowerSource.swift        # IOPSCopyPowerSourcesInfo
│   │   ├── SleepWatcher.swift       # IORegisterForSystemPower
│   │   ├── Database.swift           # sqlite3 C API + WAL
│   │   ├── Aggregator.swift         # roll-up + prune + vacuum
│   │   ├── Calibrator.swift         # powermetrics cross-check
│   │   └── Reporter.swift
│   └── CProcInfo/
│       ├── module.modulemap
│       └── shim.h                   # rusage_info_v6 + v4 erişimi
└── Tests/
    └── BatTrackerCoreTests/
```

## ⚠️ Önemli Detaylar / Tuzaklar

1. **`rusage_info` cumulative.** PID başladığından beri toplam değer döner. Sample'lar arası **delta** hesapla. `(pid, proc_start_sec)` anahtarıyla baseline tut.

2. **PID reuse.** macOS PID'leri yeniden kullanır. `proc_bsdshortinfo.pbi_start_tvsec` ile start time karşılaştır; değişmişse yeni baseline.

3. **`RUSAGE_INFO_V6` yoksa V4 fallback.** V4 enerji alanlarını içermez; o sample'da `energy_billed_raw=NULL`, CPU+wakeup tabanlı proxy.

4. **`EPERM` toleransı.** System daemon'ların çoğu için fail eder. Sessizce skip et, "unattributed" havuzuna ekle, log'u kirletme.

5. **Kısa ömürlü process'ler.** 60 sn'den kısa yaşayanlar kaçar. Phase 2'de `kqueue NOTE_EXIT`.

6. **App grouping.** Chrome/Slack helper'ları parent bundle ID'sini taşımaz. `NSRunningApplication.bundleIdentifier` GUI app için doğru. Helper'lar için exec path pattern'i: `.app/Contents/Frameworks/...Helper.app`, `.../XPCServices/...`.

7. **Battery vs AC.** `IOPSCopyPowerSourcesInfo` ile her sample'a `is_on_battery` yaz, "sadece pildeyken" filtrelenebilsin.

8. **Sample drift.** `Timer.scheduledTimer` yerine `DispatchSourceTimer`, leeway 5s.

9. **DB lock.** WAL mode + `busy_timeout=5000`. Sampler tek yazıcı; query CLI rahat okur.

10. **Bundle resolver cache.** `(pid, start_time) → metadata` cache'i olmadan her sample'da 250× `NSRunningApplication` çağrısı sampler'ın enerjisini şişirir.

11. **Self-throttling.** Sample süresi >500ms veya CPU >%1 olursa interval'ı 120s'ye çıkar (debug log bırak).

12. **İzinler.** Sandbox dışı çalışacak, Mac App Store'a göndermiyoruz. Ad-hoc imza yeterli. README'de net olsun.

13. **VACUUM.** `prune` sadece DELETE yapar, dosya küçülmez. `auto_vacuum=INCREMENTAL` + her prune sonrası `PRAGMA incremental_vacuum`. Haftalık tam `VACUUM` AC'deyken.

## 🚀 Build & Install

```bash
# Build
git clone <repo>
cd battracker
swift build -c release --arch arm64

# Install (sudo gerekmez)
mkdir -p /opt/homebrew/bin
cp .build/release/battracker /opt/homebrew/bin/
battracker daemon install

# (Önerilir) Kalibrasyon — bir kerelik, sudo ister
battracker calibrate --duration 300

# Verify
battracker daemon status
sleep 120
battracker top --since 5m
```

## ✅ Definition of Done — Phase 1

- [ ] `swift build` hatasız, binary <5MB
- [ ] `battracker sample --once` erişilebilir tüm process'leri tarayıp DB'ye yazıyor; `EPERM` olanları sessizce atlıyor
- [ ] `RUSAGE_INFO_V6` mevcutsa enerji alanları doluyor; değilse V4 fallback ile cpu+wakeup yazılıyor
- [ ] Bundle resolver cache çalışıyor, sample süresi <500ms (250 process için)
- [ ] LaunchAgent kuruluyor (sudo'suz), login'de başlıyor, throttle'lı KeepAlive ile crash loop'a girmiyor
- [ ] 60 sn aralıklarla en az 24 saat kesintisiz sample
- [ ] Sleep/wake doğru tespit ediliyor, sleep periyotları DB'ye yazılıyor, raporlardan exclude
- [ ] `battracker calibrate` powermetrics ile cross-check yapıp `energy_unit_factor`'ü meta'ya yazıyor; rapor kalibre edilmişse joule, değilse "Energy Score" gösteriyor
- [ ] `top`, `app`, `timeline`, `export` komutları doğru sonuç veriyor
- [ ] Identified vs unattributed yüzdesi raporda gösteriliyor
- [ ] **Sampler kendi enerji tüketimi: pildeyken < 20 J/saat ortalama** (`battracker app battracker --since 24h` ile doğrula)
- [ ] DB boyutu 7 günde <50MB; `prune` sonrası dosya küçülüyor
- [ ] README'de install/uninstall/sorun giderme/kalibrasyon talimatları var

## 📝 Phase 2 (Opsiyonel)

- SwiftUI menu bar app: canlı top 5 + tıklayınca grafik
- Privileged helper (`SMAppService`) ile sürekli `powermetrics` entegrasyonu — system daemon attribution gap'ini kapatır
- `kqueue NOTE_EXIT` ile kısa ömürlü process yakalama
- Anomali tespiti ("Slack normalde 50J/saat, son saatte 800J")
- Charts framework ile native grafikler
- Pildeyken anormal tüketim notification'ı
- iCloud sync (kişisel kullanım)

## 🎁 Referanslar

- **Stats** (https://github.com/exelban/stats) — `proc_pid_rusage` + `IOPSCopyPowerSourcesInfo` kullanımı
- **htop / osquery** — task_power_info örnekleri
- Apple `darwintests/proc_info` (XNU) — `RUSAGE_INFO_V6` örnekleri
- WWDC 2014 "Writing Energy Efficient Code"
- `man powermetrics` — `--show-process-energy` çıktı formatı

---

**Not:** Bu bir spec dokümanıdır. Phase 1'i bitir, kalibrasyonu yap, 24–48 saat veri topla, sonra Phase 2. Yeniden başlatmadan veya kullanıcı etkileşimi olmadan en az 7 gün stabil çalışması ve **kendi enerji tüketiminin hedef bound altında kalması** ana kalite kriterleridir.
