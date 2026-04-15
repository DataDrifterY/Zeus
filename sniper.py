import time
import requests
import threading
import queue
import ntplib
import pytz
import json
import logging
from datetime import datetime, timezone, timedelta

# =====================================================================
# PROD SETTINGS (v8 — dynamic cascade, NTP compensation, improved warmup)
# =====================================================================
TARGET_URL = "https://sgp-api.buy.mi.com/bbs/api/global/apply/bl-auth"
STATUS_URL = "https://sgp-api.buy.mi.com/bbs/api/global/user/bl-switch/state"

# Cascade offset pool (ms before Beijing midnight).
# Threads with successful Keep-Alive get the largest (best) offsets.
CASCADE_POOL_MS = [3000, 2200, 1400, 700]

MAX_ATTEMPTS = 5
REQUEST_TIMEOUT = (5, 60)       # (connect, read) for the main request
VALIDATE_TIMEOUT = (3, 5)       # for token validation

# Manual RTT in ms (measure during the day!). None = measure automatically.
MANUAL_RTT_MS = 320

# NTP compensation: subtract half of the RTT to the NTP server from the NTP offset
# to remove network latency from the measurement.
NTP_COMPENSATE = True

NTP_SERVERS = [
    "ntp4.ntp-servers.net", "ntp5.ntp-servers.net", "ntp6.ntp-servers.net",
    "ntp0.ntp-servers.net", "ntp1.ntp-servers.net", "ntp2.ntp-servers.net",
    "ntp3.ntp-servers.net", "0.ru.pool.ntp.org", "1.ru.pool.ntp.org",
    "ntp.ix.ru"
]

logging.basicConfig(
    filename='xiaomi_unlock_prod.log',
    level=logging.INFO,
    format='%(asctime)s.%(msecs)03d | %(levelname)s | %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

victory_event = threading.Event()
quota_dead_event = threading.Event()

# --- Asynchronous logging via queue ---
_log_queue = queue.Queue()
_log_stop = threading.Event()


def _log_worker():
    """Background worker: pulls messages from the queue and writes to file + console."""
    while not _log_stop.is_set() or not _log_queue.empty():
        try:
            msg, level = _log_queue.get(timeout=0.1)
            print(msg)
            if level == 'info': logging.info(msg)
            elif level == 'warning': logging.warning(msg)
            elif level == 'error': logging.error(msg)
        except queue.Empty:
            continue


_log_thread = threading.Thread(target=_log_worker, daemon=True)
_log_thread.start()


def log_and_print(msg, level='info'):
    _log_queue.put((msg, level))


def load_tokens(filename="tokens.txt"):
    try:
        with open(filename, "r", encoding="utf-8") as f:
            tokens = [line.strip() for line in f if line.strip()]
        if not tokens:
            log_and_print(f"[-] File {filename} is empty!", 'error')
            return []
        log_and_print(f"[+] Loaded tokens: {len(tokens)}")
        return tokens
    except FileNotFoundError:
        log_and_print(f"[-] File {filename} not found!", 'error')
        return []


def make_headers(token):
    return {
        "Cookie": f"new_bbs_serviceToken={token};versionCode=500411;versionName=5.4.11;",
        "User-Agent": "okhttp/4.12.0",
        "Connection": "keep-alive",
        "Accept-Encoding": "gzip, deflate, br",
        "Content-Type": "application/json; charset=utf-8"
    }


def validate_token(token, index):
    """Checks token via /bl-switch/state (GET). Returns True if alive."""
    try:
        resp = requests.get(STATUS_URL, headers=make_headers(token), timeout=VALIDATE_TIMEOUT)
        data = resp.json()

        if data.get("code") == 100004:
            log_and_print(f"[x] Token #{index+1}: DEAD (need login). Skipping.", 'error')
            return False

        inner = data.get("data", {})
        is_pass = inner.get("is_pass")
        button_state = inner.get("button_state")
        deadline = inner.get("deadline_format", "")

        if is_pass == 1:
            log_and_print(f"[★] Token #{index+1}: Application ALREADY APPROVED (until {deadline})!", 'info')
            return False
        if is_pass == 4 and button_state == 1:
            log_and_print(f"[+] Token #{index+1}: OK — submission possible.", 'info')
            return True
        if is_pass == 4 and button_state == 2:
            log_and_print(f"[~] Token #{index+1}: Blocked until {deadline}. Trying anyway.", 'warning')
            return True
        if is_pass == 4 and button_state == 3:
            log_and_print(f"[~] Token #{index+1}: Account < 30 days. Trying anyway.", 'warning')
            return True

        log_and_print(f"[?] Token #{index+1}: is_pass={is_pass}, button={button_state}", 'warning')
        return True
    except Exception as e:
        log_and_print(f"[!] Token #{index+1}: Validation error: {e}", 'warning')
        return True


def get_beijing_offset():
    """
    NTP Synchronization. Compensates for network delay:
    NTP offset contains ~RTT/2 error. We subtract it.
    """
    client = ntplib.NTPClient()
    beijing_tz = pytz.timezone("Asia/Shanghai")
    for server in NTP_SERVERS:
        try:
            req_start = time.perf_counter()
            response = client.request(server, version=3, timeout=3)
            ntp_rtt = (time.perf_counter() - req_start) * 1000  # RTT to NTP server in ms

            ntp_utc = datetime.fromtimestamp(response.tx_time, timezone.utc)
            beijing_now = ntp_utc.astimezone(beijing_tz).replace(tzinfo=None)
            local_now = datetime.now()
            raw_offset = beijing_now - local_now
            raw_offset_sec = raw_offset.total_seconds()

            # Compensation: NTP tx_time is the moment the server sent the response.
            # While the response traveled to us (~RTT/2), our local clock moved forward.
            # Therefore, raw_offset is overestimated by ~RTT/2.
            if NTP_COMPENSATE:
                compensation_sec = (ntp_rtt / 2) / 1000
                corrected_sec = raw_offset_sec - compensation_sec
                offset = timedelta(seconds=corrected_sec)
                log_and_print(f"[+] NTP via {server}. RTT to NTP: {ntp_rtt:.0f}ms")
                log_and_print(f"    Raw offset: {raw_offset_sec:.3f} sec")
                log_and_print(f"    Compensation: -{compensation_sec*1000:.0f}ms")
                log_and_print(f"    Final offset: {corrected_sec:.3f} sec")
            else:
                offset = raw_offset
                log_and_print(f"[+] NTP via {server}. Offset: {raw_offset_sec:.3f} sec.")

            beijing_corrected = local_now + offset
            return offset, beijing_corrected
        except Exception:
            log_and_print(f"[~] NTP {server} did not respond...", 'warning')
    log_and_print("[-] All NTP servers are unavailable!", 'error')
    return None, None


def measure_clean_ping(url, count=10):
    """Measures clean RTT. Returns one-way latency in ms."""
    log_and_print(f"\n[~] Measuring ping ({count} requests)...")
    latencies = []
    for _ in range(count):
        start = time.perf_counter()
        try:
            requests.head(url, timeout=3)
            latencies.append((time.perf_counter() - start) * 1000)
        except Exception:
            pass
        time.sleep(0.5)
    if latencies:
        avg_rtt = sum(latencies) / len(latencies)
        log_and_print(f"[+] RTT: {avg_rtt:.0f} ms, one-way: ~{avg_rtt/2:.0f} ms")
        return avg_rtt / 2
    log_and_print("[!] Ping failed, using 100 ms default", 'warning')
    return 100


# --- Dynamic Cascade Distribution ---
# Threads with Keep-Alive get better (larger) offsets.
_cascade_lock = threading.Lock()
_cascade_available = []  # populated in main()
_cascade_assignments = {}  # thread_index -> cascade_ms


def claim_cascade(thread_index, keepalive_ok):
    """
    Thread claims an offset from the pool.
    keepalive_ok=True — takes the largest available.
    keepalive_ok=False — takes the smallest available.
    """
    with _cascade_lock:
        if not _cascade_available:
            return None
        if keepalive_ok:
            # Best (largest) offset
            val = max(_cascade_available)
        else:
            # Worst (smallest) offset
            val = min(_cascade_available)
        _cascade_available.remove(val)
        _cascade_assignments[thread_index] = val
        return val


def worker(token, thread_index, one_way_ping_ms, global_offset):
    """
    Execution Thread v8.
    1) Keep-Alive warmup 10s before the earliest possible fire
    2) Based on warmup result — claims cascade from pool
    3) Calculates exact fire moment
    4) Busy-wait → POST
    """
    thread_name = f"Thread {thread_index+1}"
    session = requests.Session()
    session.headers.update(make_headers(token))
    payload = b'{"is_retry":true}'

    # Calculate Beijing midnight (in local time)
    beijing_now = datetime.now() + global_offset
    midnight_beijing = (beijing_now + timedelta(days=1)).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    midnight_local = midnight_beijing - global_offset
    midnight_ts = midnight_local.timestamp()

    # Earliest possible offset — max from pool + ping
    max_cascade = max(CASCADE_POOL_MS)
    earliest_fire_ts = midnight_ts - (max_cascade + one_way_ping_ms) / 1000

    # --- STEP 1: Keep-Alive warmup 10s before the earliest fire ---
    warmup_start_ts = earliest_fire_ts - 10.0
    warmup_deadline_ts = earliest_fire_ts - 3.0  # deadline for warmup completion

    warmup_ok = threading.Event()

    def do_warmup():
        # Wait for warmup start time
        while time.time() < warmup_start_ts:
            time.sleep(0.01)
        try:
            session.get(STATUS_URL, timeout=(2, 3))
            warmup_ok.set()
            log_and_print(f"[+] {thread_name} | Keep-Alive: OK")
        except Exception as e:
            log_and_print(f"[-] {thread_name} | Keep-Alive: FAIL ({e})", 'warning')

    warmup_thread = threading.Thread(target=do_warmup, daemon=True)
    warmup_thread.start()

    # Wait for warmup to complete before deadline
    wait_sec = max(0, warmup_deadline_ts - time.time())
    warmup_thread.join(timeout=wait_sec)

    if warmup_thread.is_alive():
        log_and_print(f"[!] {thread_name} | Warmup hung, continuing without it", 'warning')

    # --- STEP 2: Claim cascade from pool ---
    ka_ok = warmup_ok.is_set()
    cascade_ms = claim_cascade(thread_index, ka_ok)
    if cascade_ms is None:
        log_and_print(f"[!] {thread_name} | No available cascades, exiting", 'error')
        session.close()
        return

    # --- STEP 3: Calculate exact fire moment ---
    total_advance_ms = cascade_ms + one_way_ping_ms
    fire_timestamp = midnight_ts - total_advance_ms / 1000

    fire_time_beijing = midnight_beijing - timedelta(milliseconds=total_advance_ms)
    log_and_print(
        f"[{thread_name}] Cascade: {cascade_ms}ms (keepalive: {'OK' if ka_ok else 'FAIL'}) | "
        f"Fire: {fire_time_beijing.strftime('%H:%M:%S.%f')[:-3]} (Beijing)"
    )

    # --- STEP 4: Busy-wait until fire moment ---
    while time.time() < fire_timestamp:
        pass  # Pure busy-wait, no sleep for precision

    # === CRITICAL SECTION ===
    first_send_ts = time.perf_counter()
    first_result = None
    first_error = None
    try:
        first_result = session.post(TARGET_URL, data=payload, timeout=REQUEST_TIMEOUT)
    except Exception as e:
        first_error = e
    first_elapsed = (time.perf_counter() - first_send_ts) * 1000
    # === END CRITICAL SECTION ===

    fire_beijing_actual = datetime.now() + global_offset
    ka_status = 'OK' if ka_ok else 'FAIL'
    log_and_print(f"[{thread_name}] FIRE! keepalive: {ka_status}, "
                  f"Actual: {fire_beijing_actual.strftime('%H:%M:%S.%f')[:-3]} (Beijing)")

    # Handle first shot result
    if first_error:
        log_and_print(
            f"[!] {thread_name} Attempt 1/{MAX_ATTEMPTS} error ({first_elapsed:.0f}ms): {first_error}",
            'warning'
        )
    elif first_result:
        if _handle_response(thread_name, first_result, first_elapsed, 1, global_offset, session):
            return  # Thread finished (victory / quota / block / dead token)

    # --- Retries (2..MAX_ATTEMPTS) ---
    for attempt in range(2, MAX_ATTEMPTS + 1):
        if victory_event.is_set():
            log_and_print(f"[{thread_name}] Another thread won, stopping.")
            break
        if quota_dead_event.is_set():
            log_and_print(f"[{thread_name}] Quota exhausted (by another thread), stopping.")
            break

        send_beijing = datetime.now() + global_offset
        send_ts = time.perf_counter()
        log_and_print(f"-> {thread_name} | Attempt {attempt}/{MAX_ATTEMPTS} "
                      f"SENDING: {send_beijing.strftime('%H:%M:%S.%f')[:-3]} (Beijing)")

        try:
            resp = session.post(TARGET_URL, data=payload, timeout=REQUEST_TIMEOUT)
            elapsed = (time.perf_counter() - send_ts) * 1000
            if _handle_response(thread_name, resp, elapsed, attempt, global_offset, session):
                return
        except (requests.exceptions.ConnectTimeout, requests.exceptions.ConnectionError):
            elapsed = (time.perf_counter() - send_ts) * 1000
            log_and_print(f"[!] {thread_name} Reject/Disconnect ({elapsed:.0f}ms), instant retry!", 'warning')
            continue
        except requests.exceptions.ReadTimeout:
            elapsed = (time.perf_counter() - send_ts) * 1000
            log_and_print(f"[!] {thread_name} Read timeout ({elapsed:.0f}ms)", 'warning')
            continue
        except Exception as e:
            elapsed = (time.perf_counter() - send_ts) * 1000
            log_and_print(f"[!] {thread_name} Error ({elapsed:.0f}ms): {e}", 'warning')
            continue

    log_and_print(f"[x] {thread_name} finished work.")
    session.close()


def _handle_response(thread_name, resp, elapsed_ms, attempt, global_offset, session):
    """
    Processes server response. Returns True if the thread should terminate.
    """
    conn_time_ms = resp.elapsed.total_seconds() * 1000
    try:
        resp_data = resp.json()
    except ValueError:
        log_and_print(
            f"[!] {thread_name} Attempt {attempt}/{MAX_ATTEMPTS} not JSON ({elapsed_ms:.0f}ms): "
            f"{resp.text[:200]}", 'warning'
        )
        return False

    code = resp_data.get("code")
    inner = resp_data.get("data") or {}
    apply_result = inner.get("apply_result")
    server_ts = inner.get("ts")

    server_info = ""
    if server_ts:
        server_dt = datetime.fromtimestamp(server_ts, pytz.timezone("Asia/Shanghai"))
        server_info = f", server: {server_dt.strftime('%H:%M:%S')}"

    recv_beijing = datetime.now() + global_offset
    log_and_print(
        f"[{thread_name}] RESPONSE {attempt}/{MAX_ATTEMPTS}: "
        f"{recv_beijing.strftime('%H:%M:%S.%f')[:-3]} (Beijing) | "
        f"RTT: {elapsed_ms:.0f}ms (requests: {conn_time_ms:.0f}ms){server_info}\n"
        f"  └─ {json.dumps(resp_data, ensure_ascii=False)}"
    )

    if code == 0 and apply_result == 1:
        log_and_print(f"[★★★] {thread_name} VICTORY! Application approved!")
        victory_event.set()
        log_and_print(f"[x] {thread_name} finished work.")
        session.close()
        return True
    elif code == 0 and apply_result == 3:
        log_and_print(f"[-] {thread_name} Quota exhausted.", 'warning')
        quota_dead_event.set()
        log_and_print(f"[x] {thread_name} finished work.")
        session.close()
        return True
    elif code == 0 and apply_result == 4:
        log_and_print(f"[-] {thread_name} Submission blocked.", 'warning')
        log_and_print(f"[x] {thread_name} finished work.")
        session.close()
        return True
    elif code == 100004:
        log_and_print(f"[x] {thread_name} Token is dead!", 'error')
        log_and_print(f"[x] {thread_name} finished work.")
        session.close()
        return True

    # Unknown response — don't finish, let it retry
    log_and_print(f"[?] {thread_name} Unknown response, instant retry...", 'warning')
    return False


def main():
    log_and_print("=" * 60)
    log_and_print("  Xiaomi Bootloader Unlock Sniper v8")
    log_and_print("=" * 60)

    # 1. Load and validate tokens
    tokens = load_tokens()
    if not tokens:
        return

    log_and_print("\n[~] Checking tokens...")
    valid = []
    for i, t in enumerate(tokens):
        if validate_token(t, i):
            valid.append(t)

    if not valid:
        log_and_print("[-] No live tokens!", 'error')
        return

    log_and_print(f"[+] Live tokens: {len(valid)} out of {len(tokens)}")

    # 2. Ping
    if MANUAL_RTT_MS is not None:
        one_way_ping = MANUAL_RTT_MS / 2
        log_and_print(f"\n[+] Manual RTT: {MANUAL_RTT_MS} ms, one-way: {one_way_ping:.0f} ms")
    else:
        one_way_ping = measure_clean_ping(TARGET_URL)

    # 3. NTP sync (with network delay compensation)
    offset, _ = get_beijing_offset()
    if offset is None:
        return

    # 4. Populate cascade pool
    cascade_pool = CASCADE_POOL_MS[:len(valid)]
    _cascade_available.extend(cascade_pool)

    log_and_print("\n" + "=" * 60)
    log_and_print(f"  LAUNCH PARAMETERS:")
    log_and_print(f"  Tokens: {len(valid)}")
    log_and_print(f"  One-way ping: {one_way_ping:.0f} ms")
    if MANUAL_RTT_MS:
        log_and_print(f"  Manual RTT: {MANUAL_RTT_MS} ms")
    log_and_print(f"  NTP offset: {offset.total_seconds():.3f} sec")
    log_and_print(f"  NTP compensation: {'YES' if NTP_COMPENSATE else 'NO'}")
    log_and_print(f"  Cascade pool (ms): {cascade_pool}")
    log_and_print(f"  Cascade + Ping (ms): {[c + one_way_ping for c in cascade_pool]}")
    log_and_print(f"  Cascade Distribution: DYNAMIC (Keep-Alive → best positions)")
    log_and_print("=" * 60)

    # 5. Start threads — they handle warmup, claim cascade, and wait for fire
    log_and_print("\n[~] Threads started...")
    threads = []
    for i in range(len(cascade_pool)):
        t = threading.Thread(
            target=worker,
            args=(valid[i], i, one_way_ping, offset),
            daemon=True
        )
        threads.append(t)
        t.start()

    for t in threads:
        t.join(timeout=120)

    # Final cascade distribution
    log_and_print("\n[~] Final cascade distribution:")
    for idx in sorted(_cascade_assignments.keys()):
        log_and_print(f"    Thread {idx+1}: {_cascade_assignments[idx]}ms")

    log_and_print("\n[+] COMPLETED. Check log: xiaomi_unlock_prod.log")

    # Wait for logs to be written
    _log_stop.set()
    _log_thread.join(timeout=5)


if __name__ == "__main__":
    main()
