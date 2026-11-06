#!/usr/bin/env python3
"""Bounded, allow-listed observer evidence for the two failover runners."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import sys
import time
import uuid

STAGES = (
    "readiness", "preflightOrigins", "rollouts", "baseline", "disruption",
    "availability", "restoration", "replicaVerification", "recoveryOrigins",
    "recoverySmoke",
)
ERRORS = ("none", "http", "transport", "timeout", "invalidResponse", "unexpected")
SAMPLE_LIMIT = 500


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def save(path, report):
    # Replace on the same filesystem: readers see either the previous or new JSON.
    pending = path.with_name(path.name + ".pending")
    try:
        with pending.open("w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        for attempt in range(6):
            try:
                pending.replace(path)
                break
            except PermissionError:
                if attempt == 5:
                    raise
                time.sleep(0.1)
    finally:
        pending.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("init", "clock", "stage", "replicas", "sample", "finish"))
    parser.add_argument("values", nargs="*")
    parser.add_argument("--path")
    args = parser.parse_args(argv)
    if args.command == "clock":
        print(now(), time.monotonic())
        return
    if args.command == "init":
        mode, target, target_location, survivor, survivor_location, timeout = args.values
        if mode not in ("private", "public") or target not in ("Primary", "Secondary") or survivor not in ("Primary", "Secondary"):
            parser.error("Invalid ingress mode or region key")
        run_id = str(uuid.uuid4())
        path = Path(args.path) if args.path else Path("test-results") / f"failover-{run_id}.json"
        path = path.resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            parser.error("Report path already exists; choose a new path")
        report = {
            "schemaVersion": 1, "runId": run_id, "startedAtUtc": now(),
            "completedAtUtc": None, "status": "running", "exitCode": None,
            "ingressMode": mode,
            "target": {"key": target, "location": target_location},
            "survivor": {"key": survivor, "location": survivor_location},
            "timeoutSeconds": int(timeout),
            "stages": {name: {"status": "notRun", "startedAtUtc": None, "completedAtUtc": None} for name in STAGES},
            "replicas": {"original": None, "stopped": None, "restored": None},
            "evidence": "NotProven", "lastBaselineRegion": None,
            "samples": [], "sampleCount": 0, "samplesTruncated": False,
            "failedSampleCount": 0,
            "timing": {
                "disruptionToAvailabilityObservedMs": None,
                "disruptionToFirstSurvivorObservedMs": None,
                "note": "Observer timings include Azure Run Command, polling, HTTP, validation and local reporting overhead. Samples are sequential, not continuous outage coverage; no exact RTO or outage duration is measured.",
            },
            "limitations": [
                "A successful five-sample survivor window does not prove all clients transitioned.",
                "ContinuedService means the last baseline response was already from the survivor.",
                "Recovery requires original replicas, fresh strict origin health and smoke checks, not client moveback.",
                "No HPA is present in the baseline; no autoscaler or routing configuration is changed.",
                "Only allow-listed status, region and error categories are stored; no URLs, bodies, headers, pod names or raw exceptions.",
                "Forced process termination, host loss or an unwritable report destination can prevent final cleanup/reporting.",
            ],
        }
        save(path, report)
        print(path)
        return
    if not args.path:
        parser.error("--path is required")
    path = Path(args.path)
    report = json.loads(path.read_text(encoding="utf-8"))
    timestamp = now()
    if args.command == "stage":
        name, state = args.values
        if name not in STAGES or state not in ("running", "passed", "failed"):
            parser.error("Invalid stage or state")
        stage = report["stages"][name]
        stage["status"] = state
        if state == "running":
            stage["startedAtUtc"] = timestamp
            if name == "disruption":
                report["timing"]["disruptionStartMonotonicSeconds"] = time.monotonic()
        else:
            stage["completedAtUtc"] = timestamp
        if name == "availability" and state == "passed":
            report["evidence"] = ("ObservedTransition" if report["lastBaselineRegion"] == report["target"]["location"] else "ContinuedService")
            report["timing"]["disruptionToAvailabilityObservedMs"] = round(
                (time.monotonic() - report["timing"]["disruptionStartMonotonicSeconds"]) * 1000, 3)
    elif args.command == "replicas":
        name, value = args.values
        if name not in report["replicas"] or not value.isdecimal():
            parser.error("Invalid replica evidence")
        report["replicas"][name] = int(value)
    elif args.command == "sample":
        phase, started, tick, status, region, error = args.values
        if phase not in ("baseline", "failover") or error not in ERRORS:
            parser.error("Invalid sample category")
        if region not in (report["target"]["location"], report["survivor"]["location"]):
            region = None
        status = int(status) if status.isdecimal() and 100 <= int(status) <= 599 else None
        report["sampleCount"] += 1
        if error != "none":
            report["failedSampleCount"] += 1
        if phase == "baseline" and error == "none":
            report["lastBaselineRegion"] = region
        if phase == "failover" and error == "none" and region == report["survivor"]["location"] and report["timing"]["disruptionToFirstSurvivorObservedMs"] is None:
            report["timing"]["disruptionToFirstSurvivorObservedMs"] = round(
                (time.monotonic() - report["timing"]["disruptionStartMonotonicSeconds"]) * 1000, 3)
        if len(report["samples"]) < SAMPLE_LIMIT:
            report["samples"].append({
                "phase": phase, "startedAtUtc": started, "completedAtUtc": timestamp,
                "observerLatencyMs": round((time.monotonic() - float(tick)) * 1000, 3),
                "status": status, "region": region, "error": None if error == "none" else error,
            })
        else:
            report["samplesTruncated"] = True
    elif args.command == "finish":
        code = int(args.values[0])
        for stage in report["stages"].values():
            if stage["status"] == "running":
                stage["status"], stage["completedAtUtc"] = "failed", timestamp
        passed = all(stage["status"] == "passed" for stage in report["stages"].values())
        report["status"] = "passed" if code == 0 and passed else ("interrupted" if code in (130, 143) else "failed")
        report["exitCode"] = code if code else (0 if passed else 1)
        report["completedAtUtc"] = timestamp
        report["timing"].pop("disruptionStartMonotonicSeconds", None)
    save(path, report)


if __name__ == "__main__":
    main()
