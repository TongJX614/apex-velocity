// ace68_macos.c —— MCHOSE Ace68-II (VID 41E4 / PID 2116) macOS HID 读写 + 模拟量桥
//
// 协议来源：MCHOSE M HUB 固件静态分析（Ace68-II 1.21 = Jet 75 II 设计）：
//   · 配置接口：Usage Page 1 / Usage 0，64 字节 IN/OUT，无 report ID
//   · 命令帧：55 <op> <ck> <size> <off> ... 回复：AA <op> 00 <ck> <size> <off> ...
//     checksum = (byte[4] + byte[5..7+size-1]) & 0xFF
//   · 0x04 读 base（6 字节：current,count,table[4]）；Ace68-II 用 BoundedUnchecked 规则
//   · 0x05 读 settings（256 字节，flash 0x20100 + offset），每包 ≤56 字节
//   · 0x06 写 settings：size=1, offset=profile*64+7, payload=新值（bit3 = 模拟量上报开关）
//   · 0xA0 上报：byte0=0xA0, 1=0x10(type), 2=modifier, 3=HID code,
//     depth=BE(6,7), maximum=BE(14,15)，归一化 = depth/max
//
// 编译：clang -O2 -framework IOKit -framework CoreFoundation ace68_macos.c -o ace68_macos
//
// 用法：
//   ./ace68_macos --probe            只读：设备/固件/base/profile/开关状态
//   ./ace68_macos --enable           打开模拟量上报开关（写 profile byte7 bit3）
//   ./ace68_macos --disable          关闭模拟量上报开关
//   ./ace68_macos --capture 20       开开关并打印 20 秒原始 A0 帧（测试用，结束自动还原）
//   ./ace68_macos --stream           开开关 + UDP 桥接：W=油门 S=刹车 A/D=线性转向，
//                                    退出（Ctrl+C）时自动还原开关；--seconds N 自动退出
//   ./ace68_macos --stream --restore-off  退出时确保关闭（默认恢复进入前的状态）

#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define VID 0x41E4
#define PID 0x2116
#define REPORT_LEN 64
#define UDP_PORT 48255
#define QCAP 512
#define PIDFILE "/tmp/apex_ace68_bridge.pid"
#define ORIGINFILE "/tmp/apex_ace68_origin"
static pid_t g_parent_pid = 0;

// Ace68-II 固件 A0 描述符 key 表（67 HID keys + 0xE6，来自 HallJoy 固件分析）
static const uint8_t ACE68_KEYS[] = {
    4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,
    40,41,42,43,44,45,46,47,48,49,51,52,54,55,56,57,73,75,76,78,79,80,81,82,0xe0,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6
};

#define KEY_W 0x1A
#define KEY_A 0x04
#define KEY_S 0x16
#define KEY_D 0x07

typedef struct { uint8_t report[REPORT_LEN]; int len; } InReport;

static InReport g_queue[QCAP];
static int g_qhead = 0, g_qtail = 0;
static IOHIDDeviceRef g_dev = NULL;
static volatile sig_atomic_t g_stop = 0;
static uint8_t g_allowed[256];
static volatile sig_atomic_t g_removed = 0;

static void removal_cb(void *ctx, IOReturn result, void *sender) {
    (void)ctx; (void)result; (void)sender;
    g_removed = 1;
    g_stop = 1;
}

static void on_signal(int sig) { (void)sig; g_stop = 1; }

static void cleanup_pidfile(void) {
    FILE *f = fopen(PIDFILE, "r");
    if (!f) return;
    long pid = -1;
    if (fscanf(f, "%ld", &pid) == 1 && pid == (long)getpid()) unlink(PIDFILE);
    fclose(f);
}

static long read_pidfile(void) {
    FILE *f = fopen(PIDFILE, "r");
    if (!f) return -1;
    long pid = -1;
    if (fscanf(f, "%ld", &pid) != 1) pid = -1;
    fclose(f);
    return pid;
}

static int read_origin(int *val) {
    FILE *f = fopen(ORIGINFILE, "r");
    if (!f) return 0;
    int v = -1;
    int ok = fscanf(f, "%d", &v) == 1;
    fclose(f);
    if (ok && v >= 0 && v <= 255) { *val = v; return 1; }
    return 0;
}

static void write_origin(int val) {
    FILE *f = fopen(ORIGINFILE, "w");
    if (!f) return;
    fprintf(f, "%d\n", val);
    fclose(f);
}

static void remove_origin(void) { unlink(ORIGINFILE); }

static void write_pidfile(void) {
    FILE *f = fopen(PIDFILE, "w");
    if (!f) return;
    fprintf(f, "%ld\n", (long)getpid());
    fclose(f);
    atexit(cleanup_pidfile);
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// kill(pid,0) 对僵尸进程也返回成功；用 sysctl 排除 SZOMB(5)，避免把已死的桥当活的
static int proc_alive(pid_t pid) {
    if (pid <= 0 || kill(pid, 0) != 0) return 0;
    struct kinfo_proc info;
    size_t len = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &info, &len, NULL, 0) != 0 || len == 0) return 0;
    return info.kp_proc.p_stat != 5;
}

static uint8_t checksum(const uint8_t *p) {
    unsigned sum = p[4];
    if (p[4] > 56) return 0;
    for (unsigned i = 5; i < 8u + p[4]; ++i) sum += p[i];
    return (uint8_t)sum;
}

static int reply_ok(const uint8_t *req, const uint8_t *rep) {
    if (rep[0] != 0xAA || rep[1] != req[1] || rep[2] != 0) return 0;
    if (rep[4] > 56 || rep[4] != req[4]) return 0;
    for (int i = 5; i < 8; ++i) if (rep[i] != req[i]) return 0;
    return rep[3] == checksum(rep);
}

static void drain(void) { g_qhead = g_qtail = 0; }

static int dequeue(InReport *out) {
    if (g_qhead == g_qtail) return 0;
    *out = g_queue[g_qhead];
    g_qhead = (g_qhead + 1) % QCAP;
    return 1;
}

static void enqueue(const uint8_t *report, int len) {
    int idx = (g_qtail + 1) % QCAP;
    if (idx == g_qhead) { g_qhead = (g_qhead + 1) % QCAP; } // 满：丢最旧
    memset(g_queue[g_qtail].report, 0, REPORT_LEN);
    memcpy(g_queue[g_qtail].report, report, len > REPORT_LEN ? REPORT_LEN : len);
    g_queue[g_qtail].len = len > REPORT_LEN ? REPORT_LEN : len;
    g_qtail = idx;
}

static void input_cb(void *ctx, IOReturn result, void *sender,
                     IOHIDReportType type, uint32_t reportID,
                     uint8_t *report, CFIndex reportLength) {
    (void)ctx; (void)result; (void)sender; (void)type; (void)reportID;
    if (reportLength > 0) enqueue(report, (int)reportLength);
}

static int exchange(const uint8_t *req, uint8_t *reply, int timeout_ms) {
    drain();
    IOReturn rc = IOHIDDeviceSetReport(g_dev, kIOHIDReportTypeOutput, 0, req, REPORT_LEN);
    if (rc != kIOReturnSuccess) {
        fprintf(stderr, "[ace68] SetReport failed: 0x%08x\n", rc);
        return 0;
    }
    long long deadline = now_ms() + timeout_ms;
    while (now_ms() < deadline && !g_stop) {
        InReport r;
        if (dequeue(&r)) {
            if (reply_ok(req, r.report)) { memcpy(reply, r.report, REPORT_LEN); return 1; }
            if (r.report[0] == 0xA0) continue;
            if (r.report[0] == 0xAA || r.report[0] == 0xAB) return 0;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, false);
    }
    return 0;
}

static int read_bytes(uint8_t op, uint8_t *dst, int size) {
    int pos = 0;
    while (pos < size) {
        int count = size - pos; if (count > 56) count = 56;
        uint8_t req[REPORT_LEN] = {0}, rep[REPORT_LEN] = {0};
        req[0] = 0x55; req[1] = op; req[4] = (uint8_t)count; req[5] = (uint8_t)pos;
        req[3] = checksum(req);
        if (!exchange(req, rep, 500)) return 0;
        memcpy(dst + pos, rep + 8, count);
        pos += count;
    }
    return 1;
}

static int write_setting_byte(uint8_t offset, uint8_t value) {
    uint8_t req[REPORT_LEN] = {0}, rep[REPORT_LEN] = {0};
    req[0] = 0x55; req[1] = 0x06; req[4] = 1; req[5] = offset; req[8] = value;
    req[3] = checksum(req);
    return exchange(req, rep, 600);
}

static IOHIDDeviceRef find_config_interface(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int vid = VID, pid = PID;
    CFNumberRef cfv = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef cfp = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *keys[2] = { CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey) };
    const void *vals[2] = { cfv, cfp };
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    IOHIDDeviceRef found = NULL;
    CFSetRef devices = IOHIDManagerCopyDevices(mgr);
    if (devices) {
        CFIndex n = CFSetGetCount(devices);
        IOHIDDeviceRef *arr = calloc((size_t)n, sizeof(IOHIDDeviceRef));
        CFSetGetValues(devices, (const void **)arr);
        for (CFIndex i = 0; i < n && !found; ++i) {
            IOHIDDeviceRef d = arr[i];
            int pg = 0, us = 0, inmax = 0;
            CFNumberRef v;
            v = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDPrimaryUsagePageKey));
            if (v) CFNumberGetValue(v, kCFNumberIntType, &pg);
            v = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDPrimaryUsageKey));
            if (v) CFNumberGetValue(v, kCFNumberIntType, &us);
            v = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDMaxInputReportSizeKey));
            if (v) CFNumberGetValue(v, kCFNumberIntType, &inmax);
            if (pg == 1 && us == 0 && inmax >= REPORT_LEN) found = d;
        }
        free(arr);
        CFRelease(devices);
    }
    if (found) CFRetain(found);
    IOHIDManagerClose(mgr, kIOHIDOptionsTypeNone);
    CFRelease(mgr);
    CFRelease(match); CFRelease(cfv); CFRelease(cfp);
    return found;
}

static int open_config(IOHIDDeviceRef dev) {
    IOReturn rc = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    if (rc != kIOReturnSuccess) {
        fprintf(stderr, "[ace68] IOHIDDeviceOpen failed: 0x%08x\n", rc);
        fprintf(stderr, "[ace68] 若被 TCC 拦截：系统设置→隐私与安全性→输入监控，给终端/DSH 授权后重试。\n");
        return 0;
    }
    static uint8_t buf[REPORT_LEN];
    IOHIDDeviceRegisterInputReportCallback(dev, buf, REPORT_LEN, input_cb, NULL);
    IOHIDDeviceRegisterRemovalCallback(dev, removal_cb, NULL);
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    return 1;
}

static int read_state(uint8_t *base, uint8_t *settings, unsigned *profile) {
    if (!read_bytes(0x04, base, 6)) return 0;
    if (!read_bytes(0x05, settings, 256)) return 0;
    unsigned current = base[0] > 3 ? 0 : base[0]; // BoundedUnchecked（Ace68-II）
    unsigned entry = base[2 + current];
    if (entry > 3) return 0;
    *profile = entry;
    return settings[(*profile) * 64 + 2] == 0xAA && settings[(*profile) * 64 + 3] == 0xBB;
}

static int set_flag(int enabled, unsigned expect_profile, uint8_t *orig_out) {
    uint8_t base[6] = {0}, settings[256] = {0};
    unsigned profile = 0;
    if (!read_state(base, settings, &profile)) { fprintf(stderr, "[ace68] 读配置失败\n"); return 0; }
    if (profile != expect_profile) { fprintf(stderr, "[ace68] profile 变了（%u != %u）\n", profile, expect_profile); return 0; }
    uint8_t *p = settings + profile * 64;
    uint8_t orig = p[7];
    if (orig_out) *orig_out = orig;
    uint8_t want = enabled ? (uint8_t)(orig | 8) : (uint8_t)(orig & ~8u);
    // 关键：A0 深度流必须收到一次「写入」动作才会真正激活（键盘重新上电后，
    // 持久化配置里开关虽为开，但运行时流不会自动恢复）。因此即使目标值与当前值
    // 相同，也要强制写入一次，否则整个桥接会静默收不到任何深度帧（2026-11-07 排障结论）。
    printf("[ace68] 写 profile %u byte7: 0x%02X -> 0x%02X%s...\n", profile, orig, want,
           want == orig ? "（同值强制写入以激活 A0 流）" : "");
    int ack = write_setting_byte((uint8_t)(profile * 64 + 7), want);
    usleep(120000);
    uint8_t base2[6] = {0}, settings2[256] = {0};
    unsigned profile2 = 0;
    if (!read_state(base2, settings2, &profile2)) { fprintf(stderr, "[ace68] 写入后读回失败\n"); return -1; }
    uint8_t got = settings2[profile2 * 64 + 7];
    if (got != want) { fprintf(stderr, "[ace68] 写回校验失败: got 0x%02X want 0x%02X\n", got, want); return -1; }
    printf("[ace68] 开关已%s（读回校验通过，ack=%d）\n", enabled ? "开启" : "关闭", ack);
    return 1;
}

static void udp_bridge_once(int sock, struct sockaddr_in *addr, float steer, float throttle,
                            uint32_t *sent, uint32_t *packets) {
    static int dbg_once = 0;
    char buf[96];
    int n = snprintf(buf, sizeof(buf), "{\"steer\":%.4f,\"throttle\":%.4f,\"packets\":%u}",
                     (double)steer, (double)throttle, *packets);
    ssize_t r = sendto(sock, buf, (size_t)n, 0, (struct sockaddr *)addr, sizeof(*addr));
    if (r >= 0) (*sent)++;
    else { static int logged = 0; if (!logged) { logged = 1; perror("[ace68] sendto"); } }
    if (!dbg_once) {
        dbg_once = 1;
        char ip[64]; inet_ntop(AF_INET, &addr->sin_addr, ip, sizeof(ip));
        printf("[ace68] 首次 UDP: sock=%d dst=%s:%d ret=%zd\n", sock, ip, ntohs(addr->sin_port), r);
    }
}

static int decode_a0(const uint8_t *p, int len, unsigned *hid, float *norm_out) {
    if (len < 16 || p[0] != 0xA0) return 0;
    if (p[1] != 0x10) return 0;
    unsigned code;
    if (p[2] == 0) {
        if (p[3] < 4 || p[3] > 0x73) return 0;
        code = p[3];
    } else {
        if (p[3] != 0 || (p[2] & (p[2] - 1u)) != 0) return 0;
        int bit = 0; while (((p[2] >> bit) & 1u) == 0) ++bit;
        code = 0xE0u + (unsigned)bit;
    }
    unsigned depth = ((unsigned)p[6] << 8) | p[7];
    unsigned maximum = ((unsigned)p[14] << 8) | p[15];
    if (!g_allowed[code] || maximum < 200 || maximum > 600 || depth > maximum) return 0;
    *hid = code;
    *norm_out = (float)depth / (float)maximum;
    return 1;
}

static void run_capture(int seconds) {
    printf("[ace68] 采集原始 A0 帧 %d 秒（请在键盘上按 W/A/S/D，尽量按不同深浅）...\n", seconds);
    long long end = (long long)time(NULL) + seconds;
    int frames = 0;
    while ((long long)time(NULL) < end && !g_stop) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.004, false);
        InReport r;
        while (dequeue(&r)) {
            if (r.report[0] != 0xA0) continue;
            unsigned hid; float norm;
            if (!decode_a0(r.report, r.len, &hid, &norm)) continue;
            ++frames;
            printf("[A0] hid=0x%02X depth=%u/%u norm=%.3f raw=", hid,
                   ((unsigned)r.report[6] << 8) | r.report[7],
                   ((unsigned)r.report[14] << 8) | r.report[15], (double)norm);
            for (int i = 0; i < 16; ++i) printf("%02X", r.report[i]);
            printf("\n");
        }
    }
    printf("[ace68] 采集结束：%d 帧\n", frames);
}

static int run_stream(int seconds, int restore_off, int udp_port) {
    uint8_t base[6] = {0}, settings[256] = {0};
    unsigned profile = 0;
    int read_ok = 0;
    for (int attempt = 0; attempt < 3 && !read_ok && !g_stop; ++attempt) {
        read_ok = read_state(base, settings, &profile);
        if (!read_ok) usleep(300000);
    }
    if (!read_ok) { fprintf(stderr, "[ace68] 读配置失败\n"); return 4; }
    uint8_t orig = settings[profile * 64 + 7];
    printf("[ace68] profile=%u 原始 byte7=0x%02X（模拟量开关 %s）\n", profile, orig, (orig & 8) ? "已开" : "关闭");
    // 还原目标：正常是进入前的值；若上次桥接被强杀，origin 文件里存着真正原始值
    int restore_val = -1;
    int leftover = 0;
    if (read_origin(&leftover)) {
        restore_val = leftover;
        printf("[ace68] 检测到上次未还原的开关值 0x%02X，退出时会还原它\n", leftover);
    } else if (!(orig & 8)) {
        restore_val = orig;
        write_origin(orig);
    }
    // 无论开关读出来是否为开，都强制写入一次：键盘重新上电后持久化开关虽为开，
    // 但 A0 深度流必须收到一次「写入」才会激活（同值写入也有效）。跳过这一步会
    // 导致整个桥接静默收不到任何深度帧（A0包=0，2026-11-08 线上复现）。
    int ok = set_flag(1, profile, &orig);
    if (ok != 1) { fprintf(stderr, "[ace68] 开启模拟量上报失败\n"); return 5; }
    usleep(150000);
    drain();

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in addr = {0};
    addr.sin_len = (uint8_t)sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)udp_port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    float depth[256] = {0};
    depth[KEY_W] = depth[KEY_A] = depth[KEY_S] = depth[KEY_D] = 0.0f;
    uint32_t packets = 0, sent = 0;
    long long t_end = seconds > 0 ? (long long)time(NULL) + seconds : 0;
    long long t_next_send = 0, t_next_log = 0;
    int a0_seen = 0;            // 是否收到过 A0 深度帧
    long long last_a0_ms = 0;   // 最近一次 A0 帧时间
    long long start_ms = now_ms();
    int activate_retries = 0;
    const long long A0_STALE_MS = 1500; // 超过此时长无 A0 帧 → 停发 UDP，让游戏回退数字输入
    printf("[ace68] 桥接中 → UDP 127.0.0.1:%d，W=油门 S=刹车 A/D=线性转向；Ctrl+C 结束\n", udp_port);
    while (!g_stop && (t_end == 0 || (long long)time(NULL) < t_end)) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.004, false);
        InReport r;
        while (dequeue(&r)) {
            unsigned hid; float norm;
            if (!decode_a0(r.report, r.len, &hid, &norm)) continue;
            depth[hid] = norm;
            a0_seen = 1;
            last_a0_ms = now_ms();
            ++packets;
        }
        // 兜底：激活写入偶尔会丢/被固件忽略，启动后每 6 秒无帧就重写一次（最多 2 次）
        if (!a0_seen && activate_retries < 2 && !g_stop
                && now_ms() - start_ms > 6000LL * (activate_retries + 1)) {
            ++activate_retries;
            printf("[ace68] 仍未收到 A0 深度帧，重新写入激活（第 %d 次）...\n", activate_retries);
            set_flag(1, profile, NULL);
            drain();
        }
        int fresh = a0_seen && (now_ms() - last_a0_ms) <= A0_STALE_MS;
        if (!fresh) { // 数据过期/从未到达：深度清零并暂停发送，游戏侧 380ms 后自动回退键盘
            depth[KEY_W] = depth[KEY_A] = depth[KEY_S] = depth[KEY_D] = 0.0f;
        }
        if (g_parent_pid > 0) {
            static long long last_pp = 0;
            long long now_s = (long long)time(NULL);
            if (now_s != last_pp) {
                last_pp = now_s;
                if (!proc_alive(g_parent_pid)) {
                    printf("[ace68] 父进程(%d)已退出，自动收尾\n", (int)g_parent_pid);
                    g_stop = 1;
                }
            }
        }
        static long long last_send_us = 0;
        struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
        long long now_us = (long long)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
        if (now_us - last_send_us >= 8000) { // ~125Hz
            last_send_us = now_us;
            if (fresh) { // 只在 A0 数据新鲜时发送；否则静默，保留键盘数字输入
                float steer = depth[KEY_D] - depth[KEY_A];
                float throttle = depth[KEY_W] - depth[KEY_S];
                udp_bridge_once(sock, &addr, steer, throttle, &sent, &packets);
            }
        }
        if ((long long)time(NULL) >= t_next_log) {
            t_next_log = (long long)time(NULL) + 1;
            printf("[ace68] W=%.2f A=%.2f S=%.2f D=%.2f | A0包=%u UDP=%u%s\n",
                   (double)depth[KEY_W], (double)depth[KEY_A], (double)depth[KEY_S], (double)depth[KEY_D],
                   packets, sent, fresh ? "" : "（A0 无数据/过期，暂停发送）");
        }
    }
    // 收尾：先让游戏收到归零，再还原开关
    if (a0_seen) udp_bridge_once(sock, &addr, 0.0f, 0.0f, &sent, &packets);
    else printf("[ace68] 警告：本次运行从未收到 A0 深度帧，未向游戏发送任何数据（键盘是否插好？固件是否为 1.21？）\n");
    close(sock);
    g_stop = 0;  // 还原阶段允许正常收发（SIGTERM/父进程退出时 g_stop 已置位）
    if (restore_off) {
        printf("[ace68] --restore-off：强制关闭模拟量开关\n");
        set_flag(0, profile, NULL);
        remove_origin();
    } else if (restore_val >= 0) {
        int want_on = (restore_val & 8) ? 1 : 0;
        printf("[ace68] 还原模拟量开关为进入前状态（%s）...\n", want_on ? "开启" : "关闭");
        int ok = set_flag(want_on, profile, NULL);
        if (ok == 1) remove_origin();
        else printf("[ace68] 还原失败，保留 %s 以便下次重试\n", ORIGINFILE);
    }
    if (g_removed) printf("[ace68] 注意：键盘在桥接过程中被移除，开关可能未还原；重新插上后运行 --disable 还原\n");
    printf("[ace68] 已退出：A0 包=%u UDP 包=%u\n", packets, sent);
    return 0;
}

static void print_hex(const char *label, const uint8_t *p, int n) {
    printf("%s", label);
    for (int i = 0; i < n; ++i) printf("%02X", p[i]);
    printf("\n");
}

static int probe(void) {
    uint8_t base[6] = {0}, settings[256] = {0};
    unsigned profile = 0;
    uint8_t req[REPORT_LEN] = {0}, rep[REPORT_LEN] = {0};
    req[0] = 0x55; req[1] = 0x03; req[4] = 22; req[3] = checksum(req);
    if (exchange(req, rep, 800)) {
        uint16_t ver = (uint16_t)(rep[8] | (rep[9] << 8));
        unsigned major = (ver >> 8) & 0xFF;
        unsigned minor = ((ver >> 4) & 0xF) * 10 + (ver & 0xF);
        printf("[ace68] 固件版本 = %u.%02u (raw 0x%04X)\n", major, minor, ver);
    }
    if (!read_state(base, settings, &profile)) { fprintf(stderr, "[ace68] 读配置失败\n"); return 4; }
    print_hex("[ace68] base = ", base, 6);
    printf("[ace68] 当前 profile = %u\n", profile);
    uint8_t *p = settings + profile * 64;
    printf("[ace68] profile 头 8 字节 = %02X%02X%02X%02X%02X%02X%02X%02X (magic %s)\n",
           p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7], (p[2]==0xAA && p[3]==0xBB) ? "OK" : "BAD");
    printf("[ace68] 模拟量上报开关(byte7 bit3) = %s (byte7=0x%02X)\n", (p[7] & 8) ? "已开启" : "关闭", p[7]);
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN); // 输出被管道关闭时不要直接死掉，保证能还原键盘开关
    memset(g_allowed, 0, sizeof(g_allowed));
    for (size_t i = 0; i < sizeof(ACE68_KEYS); ++i) g_allowed[ACE68_KEYS[i]] = 1;

    int mode_probe = 0, mode_enable = 0, mode_disable = 0, mode_stream = 0;
    int seconds = 0, restore_off = 0, udp_port = UDP_PORT;
    const char *log_file = NULL;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--probe") || argc == 1) mode_probe = 1;
        else if (!strcmp(argv[i], "--enable")) mode_enable = 1;
        else if (!strcmp(argv[i], "--disable")) mode_disable = 1;
        else if (!strcmp(argv[i], "--stream")) mode_stream = 1;
        else if (!strcmp(argv[i], "--restore-off")) restore_off = 1;
        else if (!strcmp(argv[i], "--capture") && i + 1 < argc) { seconds = atoi(argv[++i]); mode_stream = -1; }
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--udp-port") && i + 1 < argc) udp_port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--parent-pid") && i + 1 < argc) g_parent_pid = (pid_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--log-file") && i + 1 < argc) log_file = argv[++i];
    }

    if (log_file && log_file[0]) {
        if (!freopen(log_file, "a", stdout)) {}
        if (!freopen(log_file, "a", stderr)) {}
    }
    // 先占 pidfile 再找设备：等待键盘插入期间也要挡住第二个桥接实例
    if (mode_stream || mode_stream == -1) {
        long other = read_pidfile();
        if (other > 0 && other != (long)getpid() && proc_alive((pid_t)other)) {
            fprintf(stderr, "[ace68] 已有桥接在运行（pid=%ld），本次不重复启动\n", other);
            return 0;
        }
        write_pidfile();
    }
    g_dev = find_config_interface();
    if (!g_dev && mode_stream == 1) {
        printf("[ace68] 暂未找到 Ace68-II，等待键盘插入（切到有线模式并插好 USB）...\n");
        while (!g_dev && !g_stop) {
            if (g_parent_pid > 0 && !proc_alive(g_parent_pid)) {
                printf("[ace68] 父进程(%d)已退出，停止等待\n", (int)g_parent_pid);
                break;
            }
            sleep(2);
            g_dev = find_config_interface();
        }
        if (g_dev) printf("[ace68] 键盘已出现，继续启动桥接\n");
    }
    if (!g_dev) { fprintf(stderr, "[ace68] 未找到 Ace68-II 配置接口（VID 41E4 PID 2116 usage 1:0）\n"); return 2; }
    if (!open_config(g_dev)) return 3;
    usleep(120000);

    uint8_t base[6] = {0}, settings[256] = {0};
    unsigned profile = 0;
    int rc = 0;
    if (mode_probe) {
        rc = probe();
    } else if (mode_enable || mode_disable) {
        if (!read_state(base, settings, &profile)) { rc = 4; }
        else {
            uint8_t orig = 0;
            int ok = set_flag(mode_enable ? 1 : 0, profile, &orig);
            rc = ok == 1 ? 0 : 6;
            if (!mode_enable) remove_origin();
        }
    } else if (mode_stream == -1) {
        if (!read_state(base, settings, &profile)) { rc = 4; }
        else {
            uint8_t orig = settings[profile * 64 + 7];
            int ok = set_flag(1, profile, &orig); // 强制写入：同值也写，激活 A0 流
            if (ok != 1) rc = 5;
            else {
                run_capture(seconds);
                g_stop = 0;
                if (!(orig & 8)) set_flag(0, profile, NULL);
            }
        }
    } else if (mode_stream) {
        rc = run_stream(seconds, restore_off, udp_port);
    } else {
        rc = probe();
    }
    if (g_dev) IOHIDDeviceClose(g_dev, kIOHIDOptionsTypeNone);
    return rc;
}
