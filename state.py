#!/usr/bin/env python3
"""Which Claude Code sessions are alive, what each is doing, and what is blocked.

Three modes:

    state.py            one JSON blob on stdout -- handy for debugging
    state.py --serve    a JSON line per change, which is what the surface reads

Sessions are discovered from transcript files rather than only from SessionStart,
because a session that began before the hook was installed never registers -- and
that was under-reporting 2 of 3 live sessions. Transcripts also carry the pieces
that make a session recognisable: aiTitle and lastPrompt.

Transcripts run to megabytes, so only the tail is read and the parse is cached on
disk by (version, mtime, size). ai-title and last-prompt are appended, so the
last occurrence of each is always near the end anyway.
"""
import json, os, sys, time, pathlib, glob

HOME = os.path.expanduser("~")
ROOT = pathlib.Path(os.environ.get("XDG_STATE_HOME", HOME + "/.local/state")) / "claude-approve"
SESS, REQS, DECS = ROOT / "sessions", ROOT / "requests", ROOT / "decisions"
LIVE = ROOT / "live"          # status.sh writes <session-id>.json here
CACHE = ROOT / "titles.json"
ORDER = ROOT / "order.json"   # session id -> when it started, so lanes hold still
# Usage limits are OPTIONAL and come from somebody else's cache. claude-pulse
# polls https://api.anthropic.com/api/oauth/usage and caches the result here with
# a 30s TTL; reading that avoids a second poller, duplicate API calls, and any
# OAuth token handling of our own -- none of which belongs in a status bar.
# Without it the surface simply omits the limits row. Point CA_USAGE_CACHE at any
# JSON file of the same shape to use something else.
PULSE_CACHE = pathlib.Path(os.environ.get(
    "CA_USAGE_CACHE",
    pathlib.Path(os.environ.get("XDG_CACHE_HOME", HOME + "/.cache")) / "claude-status" / "cache.json"))
PROJECTS = pathlib.Path(HOME) / ".claude" / "projects"
IDLE_AFTER = int(os.environ.get("CA_IDLE_AFTER", 90))   # no transcript activity for N seconds -> idle
TAIL = 512 * 1024
# Bump when scan_transcript's output shape changes, otherwise cached entries from
# an older build are served back missing the new keys.
SCAN_VERSION = 2

for d in (SESS, REQS, DECS, LIVE):
    d.mkdir(parents=True, exist_ok=True)


def alive(pid):
    try:
        return pathlib.Path(f"/proc/{int(pid)}").exists()
    except (TypeError, ValueError):
        return False


def iso_ts(v):
    if not v:
        return 0.0
    try:
        from datetime import datetime
        return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def status_of(info, pending, mtime, feed):
    """(status, since, source) -- since is when the state began, for the timer.

    The hook feed (status.sh) is authoritative when present: the transcript is
    written after the fact, so an in-progress answer or an in-flight thought is
    simply not in it yet. The transcript path below is the fallback for sessions
    that started before the hooks were installed -- it can only really
    distinguish "a tool result just came back" from "nothing happened lately".
    """
    info = info or {}
    ets = info.get("ets", 0)
    if pending:
        # An approve.sh request outranks everything: the session is blocked on us.
        return "waiting", pending.get("ts", time.time()), "hook"
    if feed:
        st, ts = feed.get("status"), feed.get("ts", 0)
        # A terminal prompt we did not serve. Notification/permission_prompt
        # tells us Claude Code is asking, but nothing tells us it stopped: if the
        # user answers in the terminal there is no event to clear this, and the
        # session sat on a dead "waiting" forever. The transcript is the proof --
        # it only moves once the tool has actually run or been refused.
        if st == "waiting" and not pending and ets > feed.get("since", ts):
            st = None
        if st and ts >= ets - 2:
            # Only trust the feed while it is at least as current as the
            # transcript. A session whose hooks are not loaded leaves a file from
            # a previous run, which would otherwise pin it to a stale state.
            if st != "idle" and time.time() - ts > IDLE_AFTER:
                return "idle", ts, "live"
            return st, feed.get("since", ts), "live"
    evt = info.get("evt")
    age = time.time() - max(ets, mtime or 0)
    if not evt or age > IDLE_AFTER:
        return "idle", ets, "transcript"
    if evt["role"] == "assistant":
        if evt["tools"]:
            return "running " + evt["tools"][0], ets, "transcript"
        if evt["stop"] == "end_turn":
            return "idle", ets, "transcript"
        if "thinking" in evt["kinds"]:
            return "thinking", ets, "transcript"
        if "text" in evt["kinds"]:
            return "responding", ets, "transcript"
        return "thinking", ets, "transcript"
    # A user turn: either a tool result going back to the model, or a fresh
    # prompt. Both mean the model is working -- the prompt is not sitting in a
    # queue, it is the thing being answered.
    return "thinking", ets, "transcript"


def load(p):
    try:
        return json.loads(p.read_text())
    except Exception:
        return None


def started_at(path):
    """When this session began, from the first timestamp in its transcript.

    Used only to order the lanes. It has to be a property of the session itself
    rather than anything that moves -- ordering by recent activity meant a lane
    jumped position every time its session did something, which is the opposite
    of what a row of lanes is for.
    """
    try:
        with open(path, "rb") as f:
            head = f.read(64 * 1024).decode("utf-8", "replace")
    except OSError:
        return 0.0
    for line in head.splitlines():
        try:
            t = iso_ts(json.loads(line).get("timestamp"))
        except Exception:
            continue
        if t:
            return t
    return 0.0


def scan_transcript(path):
    """Pull title / last prompt / cwd / activity from the tail of the transcript."""
    out = {"title": None, "last": None, "cwd": None, "evt": None, "ets": 0.0,
           "pmode": None, "turn_ms": 0, "continued": None}
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > TAIL:
                f.seek(size - TAIL)
                f.readline()          # discard the partial line we landed in
            blob = f.read().decode("utf-8", "replace")
    except OSError:
        return out
    for line in blob.splitlines():
        try:
            d = json.loads(line)
        except Exception:
            continue
        t = d.get("type")
        if t == "ai-title":
            out["title"] = d.get("aiTitle")
        elif t == "last-prompt":
            out["last"] = d.get("lastPrompt")
        elif t == "permission-mode":
            out["pmode"] = d.get("permissionMode")
        elif t == "continued-in":
            # This session handed off to another (fork/compact); the successor is
            # the live one, so the predecessor must not also get a segment.
            out["continued"] = d.get("continuedInSessionId")
        elif t == "system" and d.get("subtype") == "turn_duration":
            out["turn_ms"] = d.get("durationMs") or 0
        elif t in ("user", "assistant"):
            # Last conversational turn decides the status: a tool_use with no
            # result yet means a tool is in flight, end_turn means the turn is
            # over, anything else means the model is mid-work.
            msg = d.get("message", {}) or {}
            content = msg.get("content")
            kinds, tools = [], []
            if isinstance(content, list):
                for part in content:
                    if not isinstance(part, dict):
                        continue
                    kinds.append(part.get("type"))
                    if part.get("type") == "tool_use":
                        tools.append(part.get("name"))
            elif isinstance(content, str):
                kinds = ["text"]
            out["evt"] = {"role": t, "kinds": kinds, "tools": tools,
                          "stop": msg.get("stop_reason")}
            out["ets"] = iso_ts(d.get("timestamp")) or out["ets"]
        if d.get("cwd"):
            out["cwd"] = d["cwd"]
    return out


cache = load(CACHE) or {}
new_cache = {}
watch_paths = []      # transcripts of the sessions currently shown


def transcript_info(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    key = f"v{SCAN_VERSION}:{st.st_mtime_ns}:{st.st_size}"
    hit = cache.get(path)
    if hit and hit.get("key") == key:
        new_cache[path] = hit
        return hit
    info = scan_transcript(path)
    info["key"] = key
    new_cache[path] = info
    return info


def usage():
    """5h / 7d limits, or None when no usage cache is present.

    None is a normal state, not an error: the cache belongs to claude-pulse,
    which nobody is required to have installed. The surface drops the limits row
    and everything else works. The age rides along so the UI can say when the
    numbers went stale -- that cache only refreshes while a session renders its
    status line."""
    d = load(PULSE_CACHE)
    if not d:
        return None
    u = d.get("usage") or {}
    out = {"plan": d.get("plan"), "age": max(0, time.time() - d.get("timestamp", 0))}
    for key, label in (("five_hour", "session"), ("seven_day", "week")):
        blk = u.get(key) or {}
        if blk.get("utilization") is None:
            continue
        out[label] = {
            "pct": round(blk["utilization"]),
            "resets_at": blk.get("resets_at"),
            "resets_in": reset_delta(blk.get("resets_at")),
        }
    return out


def reset_delta(iso):
    t = iso_ts(iso)
    if not t:
        return ""
    secs = int(t - time.time())
    if secs <= 0:
        return "now"
    h, m = divmod(secs // 60, 60)
    return f"{h}h {m}m" if h else f"{m}m"


def compute():
    """One scan: returns the payload, and records what to watch for changes."""
    global cache, new_cache, watch_paths
    new_cache = {}

    # ---- pending requests -------------------------------------------------------
    pending = {}
    for f in REQS.glob("*.json"):
        r = load(f)
        if not r:
            f.unlink(missing_ok=True); continue
        if (DECS / f.stem).exists() or time.time() - r.get("ts", 0) > 900:
            f.unlink(missing_ok=True); continue
        pending[r.get("session_id", "")] = dict(r, id=f.stem)

    # ---- live status feed (hooks) -----------------------------------------------
    # SessionEnd removes a session's file, but it does not fire for every exit (a
    # killed terminal, `claude -p`), so anything untouched for a day is swept here.
    feeds = {}
    for f in LIVE.glob("*.json"):
        try:
            if time.time() - f.stat().st_mtime > 86400:
                f.unlink(missing_ok=True); continue
        except OSError:
            continue
        d = load(f)
        if d and d.get("session_id"):
            feeds[d["session_id"]] = d

    # ---- registered sessions (exact, pid-verified) ------------------------------
    registered = {}
    for f in SESS.glob("*"):
        s = load(f)
        if not s:
            f.unlink(missing_ok=True); continue
        if not alive(s.get("pid")):
            f.unlink(missing_ok=True); continue
        registered[s.get("session_id", f.name)] = s

    # ---- live sessions ----------------------------------------------------------
    # Transcript mtime is NOT liveness -- a closed session keeps its recent mtime, so
    # that approach listed dead sessions. Every source here is backed by a running
    # process instead:
    #   1. the SessionStart registry (exact session id, pid verified)
    #   2. `claude --resume <transcript>` on the cmdline (exact session id)
    #   3. a bare `claude` process, matched to the newest transcript under its cwd
    # Transcripts are still read, but only for the title and last prompt.
    now = time.time()


    def _argv(pid):
        try:
            a = open(f"/proc/{pid}/cmdline", "rb").read().decode("utf-8", "replace").split("\0")
            return [x for x in a if x]
        except OSError:
            return []


    def _ppid(pid):
        try:
            # stat field 4, read after the comm field so a space in comm cannot shift it
            data = open(f"/proc/{pid}/stat").read()
            return int(data[data.rindex(")") + 2:].split()[1])
        except (OSError, ValueError, IndexError):
            return 0


    BG_MARKERS = ("bg-pty-host", "bg-spare", "daemon", "mcp")


    def _backgrounded(pid, depth=4):
        """True if this claude sits under the background daemon tree.

        `claude --resume <transcript>` under a bg-pty-host parent is a background
        session the daemon spawned -- a real process, but not a terminal the user
        has open, so it must not get a dot.
        """
        cur = _ppid(pid)
        for _ in range(depth):
            if cur <= 1:
                return False
            argv = _argv(cur)
            if argv and "claude" in os.path.basename(argv[0]) and any(m in argv[1:4] for m in BG_MARKERS):
                return True
            if argv and any(m in " ".join(argv[:4]) for m in BG_MARKERS):
                return True
            cur = _ppid(cur)
        return False


    def claude_pids():
        """Interactive claude processes only -- not the daemon, pty hosts or spares."""
        out = []
        for entry in glob.glob("/proc/[0-9]*"):
            pid = os.path.basename(entry)
            try:
                argv = open(f"{entry}/cmdline", "rb").read().decode("utf-8", "replace").split("\0")
                argv = [a for a in argv if a]
                if not argv or "claude" not in os.path.basename(argv[0]):
                    continue
                if any(a in BG_MARKERS for a in argv[1:3]):
                    continue
                if _backgrounded(int(pid)):
                    continue
                cwd = os.readlink(f"{entry}/cwd")
            except (OSError, PermissionError, IndexError):
                continue
            resumed = None
            for i, a in enumerate(argv):
                if a == "--resume" and i + 1 < len(argv) and argv[i + 1].endswith(".jsonl"):
                    resumed = os.path.basename(argv[i + 1])[:-6]
            out.append({"pid": int(pid), "cwd": cwd, "resumed": resumed})
        return out


    def transcripts_for(cwd):
        """Transcripts under the project dir for this cwd, newest first.

        Matches on the project directory (which encodes the launch cwd, e.g.
        /home/you/src -> -home-you-src) rather than the transcript's own cwd field:
        that field tracks wherever the session has since cd'd to, so it drifts away
        from the process cwd and the session stops matching itself.
        """
        proj = PROJECTS / cwd.replace("/", "-")
        hits = [(os.path.getmtime(x), x) for x in glob.glob(str(proj / "*.jsonl"))]
        hits.sort(reverse=True)
        return [h[1] for h in hits]


    live = {}          # session id -> transcript path (or None)
    # session id -> the claude pid behind it. Click-to-focus walks up from here
    # to whichever process owns a window, so a session with no pid (a request
    # from something already gone) simply is not clickable.
    pids = {}
    claimed = set()

    claimed_pids = set()

    for sid, reg in registered.items():
        # The registry is not automatically interactive: SessionStart's parent-walk
        # can land on a bg-spare or bg-pty-host, so a background session registers
        # itself like any other. Apply the same filter here.
        rp = reg.get("pid")
        if rp and (_backgrounded(int(rp)) or any(m in _argv(int(rp))[1:4] for m in BG_MARKERS)):
            continue
        hit = glob.glob(str(PROJECTS / "*" / f"{sid}.jsonl"))
        live[sid] = hit[0] if hit else None
        if rp:
            pids[sid] = int(rp)
        claimed.add(sid)
        # A registered session already accounts for its process; without this the
        # same claude would also claim a transcript by cwd and show up twice.
        if reg.get("pid"):
            claimed_pids.add(int(reg["pid"]))

    procs = [p for p in claude_pids() if p["pid"] not in claimed_pids]
    for pr in procs:
        if pr["resumed"] and pr["resumed"] not in claimed:
            hit = glob.glob(str(PROJECTS / "*" / f"{pr['resumed']}.jsonl"))
            live[pr["resumed"]] = hit[0] if hit else None
            pids[pr["resumed"]] = pr["pid"]
            claimed.add(pr["resumed"])

    for pr in procs:
        if pr["resumed"]:
            continue
        for path in transcripts_for(pr["cwd"]):
            sid = os.path.basename(path)[:-6]
            if sid in claimed:
                continue
            live[sid] = path
            pids[sid] = pr["pid"]
            claimed.add(sid)
            break

    # A request from a session none of the above caught still deserves a dot.
    for sid in pending:
        if sid and sid not in live:
            hit = glob.glob(str(PROJECTS / "*" / f"{sid}.jsonl"))
            live[sid] = hit[0] if hit else None

    # Two routes can resolve to the same transcript (registry + cwd match); keep one.
    superseded = set()
    for sid, path in list(live.items()):
        if path:
            nxt = (transcript_info(path) or {}).get("continued")
            if nxt and nxt in live:
                superseded.add(sid)
    for sid in superseded:
        del live[sid]

    seen_paths = {}
    for sid, path in list(live.items()):
        if path and path in seen_paths:
            del live[sid]
        elif path:
            seen_paths[path] = sid

    found = {}
    for sid, path in live.items():
        info = transcript_info(path) if path else {}
        found[sid] = {"mtime": os.path.getmtime(path) if path else 0, "info": info or {}}

    sessions = []
    for sid in found:
        f = found.get(sid, {})
        info = f.get("info", {})
        reg = registered.get(sid, {})
        pend = pending.get(sid)
        cwd = reg.get("cwd") or info.get("cwd") or (pend or {}).get("cwd") or ""
        title = info.get("title") or (info.get("last") or "").strip().splitlines()[:1]
        if isinstance(title, list):
            title = title[0] if title else ""
        sessions.append({
            "id": sid,
            "short": sid[:6],
            "cwd": cwd,
            "dir": os.path.basename(cwd) or "~",
            "title": (title or "untitled")[:60],
            "last": (info.get("last") or "")[:180],
            "mtime": f.get("mtime", 0),
            "registered": sid in registered,
            "pid": pids.get(sid, 0),
            "pending": pend,
            **dict(zip(("status", "since", "src"),
                       status_of(info, pend, f.get("mtime", 0), feeds.get(sid)))),
            "pmode": info.get("pmode") or "",
            "turn_ms": info.get("turn_ms") or 0,
            # Only the hook feed knows these; a transcript-only session has neither.
            "agents": (feeds.get(sid) or {}).get("agents") or 0,
            "model": (feeds.get(sid) or {}).get("model") or "",
        })

    # Oldest session leftmost, newest appended on the right, and nothing moves
    # once it is placed. A pending request deliberately does NOT jump the queue:
    # it already has the heartbeat, the glow and a panel that opens itself, and
    # having the lane move as well means reaching for a target that just shifted.
    order = load(ORDER) or {}
    changed = False
    for sid, path in live.items():
        if sid not in order:
            order[sid] = started_at(path) if path else time.time()
            changed = True
    if changed or len(order) > 200:
        keep = {k: v for k, v in order.items()
                if k in live or time.time() - (v or 0) < 30 * 86400}
        try:
            ORDER.write_text(json.dumps(keep))
        except OSError:
            pass
        order = keep
    sessions.sort(key=lambda s: (order.get(s["id"]) or 0, s["id"]))


    cache = new_cache
    watch_paths = [p for p in live.values() if p]
    return {"sessions": sessions, "now": now, "usage": usage()}


def flush_cache():
    try:
        CACHE.write_text(json.dumps(new_cache))
    except OSError:
        pass


# ---- serve ------------------------------------------------------------------
# Spawning this script per frame cost 48ms of CPU a time, 16ms of it bare
# interpreter startup, which at 5Hz was a quarter of a core to redraw a 10px
# bar. Nothing needs polling at that rate: status.sh writes the moment a session
# changes state and approve.sh writes the moment a request arrives, so the work
# here is to notice a file landed and rescan. A tick is a handful of stat()
# calls; the scan only runs when one of them moved.
TICK      = float(os.environ.get("CA_TICK", 0.25))
# Process death has no hook behind it -- a killed terminal never sends
# SessionEnd -- so a full rescan still runs on this interval regardless.
HEARTBEAT = float(os.environ.get("CA_HEARTBEAT", 10))


def _mtime(p):
    try:
        return os.stat(p).st_mtime_ns
    except OSError:
        return 0


def trigger():
    """Cheap fingerprint of everything that can change what we draw."""
    sig = [_mtime(d) for d in (SESS, REQS, DECS, LIVE)]
    sig += [_mtime(f) for f in sorted(LIVE.glob("*.json"))]
    # Transcripts cover sessions whose hooks are not loaded, which have no live
    # file to announce themselves with.
    sig += [_mtime(p) for p in watch_paths]
    return tuple(sig)


def render_key(data):
    """What the surface actually draws, for deciding whether to emit.

    Two fields move on every single scan and would defeat the comparison
    entirely: `age`, which is a float seconds-since-the-usage-cache-was-written,
    and `mtime`, which advances as a transcript is appended. Neither is drawn --
    the surface ages the usage reading against its own clock, and mtime only
    breaks ties in the sort order.
    """
    ss = [{k: v for k, v in s.items() if k != "mtime"} for s in data["sessions"]]
    u = {k: v for k, v in (data["usage"] or {}).items() if k != "age"}
    return json.dumps([ss, u], sort_keys=True)


def serve():
    # approve.sh blocks a tool call waiting for a click, so it has to know this
    # is running -- otherwise a stopped daemon stalls every call for the full
    # timeout before deferring to the prompt it should have deferred to at once.
    ALIVE = ROOT / "alive"
    last_out = None
    last_sig = None
    last_full = 0.0
    while True:
        now = time.time()
        try:
            ALIVE.touch()
        except OSError:
            pass
        sig = trigger()
        if sig != last_sig or now - last_full >= HEARTBEAT:
            data = compute()
            out = json.dumps(data)
            key = render_key(data)
            if key != last_out:
                print(out, flush=True)
                last_out = key
                flush_cache()
            last_sig = sig if sig == trigger() else None   # a write mid-scan rescans
            last_full = now
        time.sleep(TICK)


if "--serve" in sys.argv:
    try:
        serve()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    sys.exit(0)

data = compute()
flush_cache()
print(json.dumps(data))
