#!/usr/bin/env python3
"""Build a reassignment plan that raises a topic's replication factor.

Kafka has no command that sets a replication factor. The replication factor is the length of
each partition's replica list, so raising it means reassigning every partition with extra
replicas appended.

Usage:
  kafka-topics --bootstrap-server <broker>:9092 --describe --topic <topic> \
    | kafka-plan-replication-factor.py <target_rf> <broker_ids> <out_prefix>

  e.g.  ... | kafka-plan-replication-factor.py 3 0,1,2,3,4 my-topic

Writes two files:
  <out_prefix>-rf<target_rf>.json   the plan, for kafka-reassign-partitions --execute
  <out_prefix>-before.json          the current assignment, to roll back with

Placement: existing replicas are kept in their current order, so the current leader stays the
preferred leader and no leadership moves when the plan runs. Missing replicas are appended from
the brokers not already holding the partition, least loaded first.
"""
import json
import re
import sys

target_rf = int(sys.argv[1])
brokers = [int(b) for b in sys.argv[2].split(",")]
out = sys.argv[3]

parts = []
topic = None
for line in sys.stdin:
    m = re.search(r"Topic:\s*(\S+)\s+Partition:\s*(\d+)\s+Leader:\s*(-?\d+)\s+Replicas:\s*([\d,]+)\s+Isr:", line)
    if not m:
        continue
    topic = m.group(1)
    parts.append((int(m.group(2)), [int(r) for r in m.group(4).split(",")]))

if not parts:
    sys.exit("no partition lines parsed from stdin")
parts.sort()

load = {b: 0 for b in brokers}
for _, reps in parts:
    for r in reps:
        if r in load:
            load[r] += 1

before = {"version": 1, "partitions": [{"topic": topic, "partition": p, "replicas": reps} for p, reps in parts]}
plan = {"version": 1, "partitions": []}
for p, reps in parts:
    new = list(reps)
    while len(new) < target_rf:
        candidates = [b for b in brokers if b not in new]
        if not candidates:
            sys.exit(f"partition {p}: not enough brokers for replication factor {target_rf}")
        pick = min(candidates, key=lambda b: (load[b], b))
        new.append(pick)
        load[pick] += 1
    plan["partitions"].append({"topic": topic, "partition": p, "replicas": new})

with open(f"{out}-before.json", "w") as f:
    json.dump(before, f, indent=1)
with open(f"{out}-rf{target_rf}.json", "w") as f:
    json.dump(plan, f, indent=1)

changed = sum(1 for a, b in zip(before["partitions"], plan["partitions"]) if a["replicas"] != b["replicas"])
print(f"{topic}: {len(parts)} partitions, {changed} change, target replication factor {target_rf}")
print("replicas per broker after:", {b: load[b] for b in brokers})
print(f"wrote {out}-before.json and {out}-rf{target_rf}.json")
