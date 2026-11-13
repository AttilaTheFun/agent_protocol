#!/usr/bin/env python3
"""agent_protocol's proof (AttilaTheFun/reviews' docs/PROOF_FORMAT.md, format 2):
its tests' results, a `tests` item for each test target, each with its
log. A library has no screens; agent-wrapper's static binaries' SHA-256 go
in the release's notes and SHA256SUMS instead.

    tools/ci/tests_proof.py <proof dir> <version> <id>=<title>=<log> ...

Each log is a `swift test --filter` run of one target: its last
"Executed N tests, with [S tests skipped and] F failures" line counts it.
GITHUB_REPOSITORY, GITHUB_SHA and GITHUB_RUN_ID name what it is a proof of.
"""
import datetime
import json
import os
import re
import shutil
import sys

EXECUTED = re.compile(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?")


def counts(log):
    """The tests and failures of every bundle the run went through, summed:
    each bundle's "All tests" ("Selected tests", filtered) suite ends with
    its totals. A filtered run
    goes through every bundle, those its filter left empty with 0."""
    tests = failures = 0
    seen = False
    closing = False
    with open(log, errors="replace") as text:
        for line in text:
            # "All tests", or "Selected tests" for a filtered run.
            if re.search(r"Test Suite '(All|Selected) tests' (passed|failed) at ", line):
                closing = True
                continue
            match = EXECUTED.search(line)
            if closing and match:
                tests += int(match.group(1))
                failures += int(match.group(3))
                seen = True
                closing = False
    return (tests, failures) if seen else None


def main(argv):
    if len(argv) < 4:
        raise SystemExit(__doc__)
    folder, version, specs = argv[1], argv[2], argv[3:]
    os.makedirs(os.path.join(folder, "logs"), exist_ok=True)
    items = []
    for spec in specs:
        item_id, title, log = spec.split("=", 2)
        name = "logs/%s.txt" % item_id.replace("/", "-")
        shutil.copyfile(log, os.path.join(folder, name))
        found = counts(log)
        tests, failures = found if found else (0, 1)
        # None run is no pass: a filter that matched nothing proves nothing.
        items.append({"id": item_id, "kind": "tests", "title": title,
                      "result": "passed" if found and failures == 0 and tests > 0 else "failed",
                      "tests": tests, "failures": failures, "log": name})
    proof = {
        "format": 2,
        "app": "agent_protocol",
        "version": version,
        "repository": os.environ.get("GITHUB_REPOSITORY", "AttilaTheFun/agent_protocol"),
        "commit": os.environ.get("GITHUB_SHA", ""),
        "run": int(os.environ.get("GITHUB_RUN_ID", "0") or 0),
        "made": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "items": items,
    }
    with open(os.path.join(folder, "proof.json"), "w") as out:
        json.dump(proof, out, indent=2)
        out.write("\n")
    for item in items:
        print("%s: %s, %d tests, %d failures" % (item["id"], item["result"], item["tests"], item["failures"]))
    return 0 if all(item["result"] == "passed" for item in items) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
