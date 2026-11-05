#!/usr/bin/env python3
"""Weekly-usage sentinel decision core (ops/usage-sentinel.sh is the thin wrapper).

Incident 2026-10-26: the old watcher read ~/.claude/usage-snapshot.json, which only the statusline writes; under Remote
Control nothing refreshed it, it went 115,616 s stale, and the weekly limit was hit with no warning.

SOURCES (honest status, 2026-10-26): no TUI-independent reader is PROVEN. `claude -p --output-format json` carries no
rate-limit fields, and the Usage-page number could not be compared with any machine-readable value. So:
  1. manual.json  - Ahmad feeds the Usage-page number (`usage-sentinel.sh calibrate <n>`, Telegram /usage <n>)
  2. usage-snapshot.json (statusline) - only when younger than USAGE_MAX_AGE (15 min)
  3. UNKNOWN - stale/missing/out-of-range/pre-reset input is never "low", it alerts.
Status: ok (0) / act (1: checkpoint crossed or STOP held) / unknown (3).
"""
import json, os, subprocess, sys, time

HOME = os.path.expanduser("~")
STATE = os.environ.get("USAGE_STATE", f"{HOME}/.whisky-os-state/usage")
SNAPSHOT = os.environ.get("USAGE_SNAPSHOT", f"{HOME}/.claude/usage-snapshot.json")
NOTIFY = os.environ.get("USAGE_NOTIFY", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "notify.sh"))
MAX_AGE = int(os.environ.get("USAGE_MAX_AGE", "900"))
MANUAL_MAX_AGE = int(os.environ.get("USAGE_MANUAL_MAX_AGE", "3600"))
STOP_PCT = float(os.environ.get("USAGE_STOP_PCT", "80"))
CHECKPOINTS = [int(x) for x in os.environ.get("USAGE_CHECKPOINTS", "40 60 75 80 90").split()]
UNKNOWN_REPEAT = int(os.environ.get("USAGE_UNKNOWN_REPEAT", "21600"))
NOW = int(os.environ.get("USAGE_NOW", str(int(time.time()))))
ACTIONS = os.environ.get("OS_ACTIONS_LOG", f"{HOME}/.whisky-os-state/actions.jsonl")


def read_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return None


def num(v):
    # bool is an int subclass: True must not read as 1 %
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return float(v) if 0 <= v <= 100 else None


def candidate(name, raw, max_age):
    """-> (candidate|None, why-unusable). A candidate is {src,pct,t,age,resets_at}."""
    if raw is None:
        return None, f"{name}: missing or unreadable"
    t = raw.get("t")
    if isinstance(t, bool) or not isinstance(t, (int, float)):
        return None, f"{name}: no timestamp"
    if name == "snapshot":
        sd = (raw.get("rl") or {}).get("seven_day") or {}
        pct, resets = num(sd.get("used_percentage")), sd.get("resets_at")
        fh = num(((raw.get("rl") or {}).get("five_hour") or {}).get("used_percentage"))
    else:
        pct, resets = num(raw.get("pct")), raw.get("resets_at")
        fh = num(raw.get("five_hour"))
    age = NOW - int(t)
    if pct is None:
        return None, f"{name}: weekly percentage missing or outside 0-100"
    if age < -300:
        return None, f"{name}: timestamp is {-age}s in the future"
    if age > max_age:
        return None, f"{name}: {age}s old (limit {max_age}s)"
    if isinstance(resets, (int, float)) and not isinstance(resets, bool) and NOW >= resets:
        return None, f"{name}: weekly window reset at {int(resets)}, reading is pre-reset"
    return {"src": name, "pct": pct, "t": int(t), "age": max(age, 0), "resets_at": resets, "five_hour": fh}, ""


def log_action(what, why, evidence=""):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)), "who": "usage-sentinel",
           "what": what, "why": why, "evidence": evidence}
    try:
        os.makedirs(os.path.dirname(ACTIONS), exist_ok=True)
        with open(ACTIONS, "a") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass


def notify(title, body):
    try:
        subprocess.run([NOTIFY, title, body], timeout=30, capture_output=True)
        return True
    except Exception:
        return False


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)


def calibrate(arg):
    try:
        v = float(arg)
    except Exception:
        print("calibrate: expected a number 0-100", file=sys.stderr)
        return 2
    if num(v) is None:
        print("calibrate: expected a number 0-100", file=sys.stderr)
        return 2
    rec = {"pct": v, "t": NOW, "by": "manual"}
    if os.environ.get("USAGE_RESETS_AT"):
        rec["resets_at"] = int(os.environ["USAGE_RESETS_AT"])
    write_atomic(os.path.join(STATE, "manual.json"), json.dumps(rec))
    log_action("calibrate", f"manual weekly usage {v:g}%", os.path.join(STATE, "manual.json"))
    print(f"calibrated: weekly {v:g}% at {NOW}")
    return 0


def run(as_json):
    stop_path = os.path.join(STATE, "fanout-stop")
    state_path = os.path.join(STATE, "state.json")
    st = read_json(state_path) or {}
    cands, why = [], []
    for name, path, age in (("manual", os.path.join(STATE, "manual.json"), MANUAL_MAX_AGE), ("snapshot", SNAPSHOT, MAX_AGE)):
        c, w = candidate(name, read_json(path), age)
        (cands.append(c) if c else why.append(w))
    best = max(cands, key=lambda c: c["t"]) if cands else None

    out = {"status": "unknown", "pct": None, "source": None, "age_s": None, "stop": os.path.exists(stop_path),
           "alerts": [], "unusable": why, "note": "no TUI-independent source is proven; manual calibration + statusline only"}
    code = 3
    if best is None:
        last = max((c for c in (read_json(os.path.join(STATE, "manual.json")),) if c), key=lambda c: c.get("t", 0), default=None)
        last_txt = f" Last manual reading {last.get('pct')}% at {last.get('t')}." if last else ""
        due = NOW - int(st.get("unknown_alert_at", 0)) >= UNKNOWN_REPEAT
        if due:
            notify("usage UNKNOWN", "No fresh weekly-usage reading. " + "; ".join(why) + "." + last_txt +
                   " Send /usage <n> with the Usage-page number. UNKNOWN is never treated as low.")
            st["unknown_alert_at"] = NOW
            out["alerts"].append("unknown")
            log_action("alert", "usage UNKNOWN", "; ".join(why))
    else:
        pct = best["pct"]
        week = str(int(best["resets_at"])) if isinstance(best.get("resets_at"), (int, float)) else time.strftime("%G-W%V", time.gmtime(NOW))
        if st.get("week") != week:
            st["week"], st["alerted"] = week, []
        st.pop("unknown_alert_at", None)
        out.update(status="ok", pct=pct, source=best["src"], age_s=best["age"], five_hour=best["five_hour"])
        code = 0
        crossed = [c for c in CHECKPOINTS if pct >= c and c not in st["alerted"]]
        if crossed:
            top = max(crossed)
            st["alerted"] = sorted(set(st["alerted"]) | set(crossed))
            notify(f"weekly usage {pct:g}% (checkpoint {top}%)",
                   f"Source {best['src']}, {best['age']}s old. " + ("fanout-stop is written: no new agents until you resume. " if pct >= STOP_PCT else "") +
                   "Budget the fan-out: fewer agents, Opus only where required.")
            out["alerts"].append(f"checkpoint-{top}")
            log_action("alert", f"weekly usage {pct:g}% crossed {top}%", best["src"])
            code = 1
        if pct >= STOP_PCT:
            if not os.path.exists(stop_path):
                write_atomic(stop_path, f"by=usage-sentinel\npct={pct:g}\nat={NOW}\nweek={week}\n")
                log_action("write fanout-stop", f"weekly usage {pct:g}% >= {STOP_PCT:g}%", stop_path)
            code = 1
        elif os.path.exists(stop_path):
            body = open(stop_path).read()
            if "by=usage-sentinel" in body:
                os.remove(stop_path)
                log_action("remove fanout-stop", f"weekly usage back to {pct:g}% < {STOP_PCT:g}%", stop_path)
        out["status"] = "act" if code == 1 else "ok"
    out["stop"] = os.path.exists(stop_path)
    out["checked_at"] = NOW
    out["exit"] = code
    write_atomic(state_path, json.dumps(st))
    write_atomic(os.path.join(STATE, "status.json"), json.dumps(out))
    print(json.dumps(out) if as_json else f"usage-sentinel: {out['status']} pct={out['pct']} source={out['source']} stop={out['stop']} {'; '.join(why)}")
    return code


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "calibrate":
        sys.exit(calibrate(a[1] if len(a) > 1 else ""))
    sys.exit(run("--json" in a))
