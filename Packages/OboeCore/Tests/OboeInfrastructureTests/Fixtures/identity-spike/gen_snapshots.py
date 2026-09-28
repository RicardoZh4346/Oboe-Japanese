#!/usr/bin/env python3
"""identity-spike snapshot generator — two versions of one mini dictionary.

v0.7.5 S02 spike fixtures for SemanticFingerprint / alias rebinding
(docs/v0.7.5/decisions.md D01). Field names mirror the DictionarySense
contract consumed by SenseIdentitySpikeTests:
entry_id / sense_id / sense_order / glosses_en / glosses_zh / pos_codes /
restricted_forms / restricted_readings / tags + dataset_version.

sense_id is assigned by emission order (global ++ counter across entries),
mirroring Scripts/build_dictionary.py `sense_id += 1` — any insertion,
deletion or reorder of senses shifts later row ids, which is exactly the
instability the fingerprint must survive.

v1: 7 entries / 12 senses.  v2: 7 entries / 12 senses.
v2 vs v1 encoded deltas:
  (a) entry 100002 食べる: sense emission order swapped -> same senses,
      different row ids and sense_order;
  (b) entry 100003 行く: new sense inserted at order 1 -> the "to proceed"
      sense moves from (id=6, order=1) to (id=7, order=2);
  (c) entry 100004 見る: zh gloss rewritten, en gloss identical ->
      fingerprint must not change;
  (d) entry 100005 掛かる: two senses share identical en gloss + POS +
      restrictions + tags -> identical fingerprints (collision pair);
  (e) entry 100007 本: the "origin" sense is dropped upstream ->
      stale rebind path.
Entries 100001 上がる / 100006 水 are stable controls.

Run: python3 gen_snapshots.py  (writes snapshot-v1.json / snapshot-v2.json
next to this file; deterministic output)
"""
import json, os

def tag(category, code):
    return {"category": category, "code": code}

def sense(en, zh, pos, forms=None, readings=None, tags=None):
    return {
        "glosses_en": en,
        "glosses_zh": zh,
        "pos_codes": pos,
        "restricted_forms": forms or [],
        "restricted_readings": readings or [],
        "tags": tags or [],
    }

# ---- shared sense content -------------------------------------------------

# 100001 上がる — control entry, unchanged between snapshots.
AGARU_RISE = sense(
    ["to go up", "to rise"], ["上升；提高"], ["v1", "vi"])
AGARU_RAISED = sense(
    ["to be raised", "to be elevated"], ["被抬高；被提高"], ["v1", "vi"],
    forms=["上がる"], tags=[tag("misc", "uk")])

# 100002 食べる — (a) v2 swaps emission order -> row ids swap.
TABERU_EAT = sense(
    ["to eat"], ["吃"], ["v1", "vt"])
TABERU_LIVE = sense(
    ["to live on", "to subsist on"], ["靠……为生"], ["v1"])

# 100003 行く — (b) v2 inserts IKU_HELD between the two v1 senses.
IKU_GO = sense(
    ["to go", "to move"], ["去；走"], ["v5k-s", "vi"])
IKU_PROCEED = sense(
    ["to proceed", "to take place"], ["进行；举行"], ["v5k-s", "vi"],
    readings=["おこなう"])
IKU_HELD = sense(  # new in v2, distinct fingerprint
    ["to be held", "to be carried out"], ["被举行；被进行"],
    ["v5k-s", "vi"], tags=[tag("misc", "uk")])

# 100004 見る — (c) zh gloss rewritten between v1 and v2.
MIRU_V1 = sense(
    ["to see", "to watch"], ["看"], ["v1", "vt"])
MIRU_V2 = sense(
    ["to see", "to watch"], ["看见；观看；查看"], ["v1", "vt"])

# 100005 掛かる — (d) identical fingerprint pair.
KAKARU_COST_A = sense(
    ["to take (time)", "to cost"], ["花费（时间）"], ["v5r", "vi"],
    forms=["掛かる"], tags=[tag("misc", "uk")])
KAKARU_COST_B = sense(  # only zh differs -> same fingerprint
    ["to take (time)", "to cost"], ["耗费"], ["v5r", "vi"],
    forms=["掛かる"], tags=[tag("misc", "uk")])

# 100006 水 — control entry.
MIZU = sense(
    ["water", "cold water"], ["水；凉水"], ["n"], tags=[tag("misc", "uk")])

# 100007 本 — (e) HON_ORIGIN dropped in v2 -> stale path.
HON_BOOK = sense(
    ["book", "volume"], ["书；书籍"], ["n"])
HON_ORIGIN = sense(
    ["origin", "source", "basis"], ["根源；本原"], ["n", "pref"],
    tags=[tag("field", "ling")])

def entry(entry_id, senses):
    return {"entry_id": entry_id, "senses": senses}

V1 = [
    entry(100001, [AGARU_RISE, AGARU_RAISED]),
    entry(100002, [TABERU_EAT, TABERU_LIVE]),
    entry(100003, [IKU_GO, IKU_PROCEED]),
    entry(100004, [MIRU_V1]),
    entry(100005, [KAKARU_COST_A, KAKARU_COST_B]),
    entry(100006, [MIZU]),
    entry(100007, [HON_BOOK, HON_ORIGIN]),
]

V2 = [
    entry(100001, [AGARU_RISE, AGARU_RAISED]),
    entry(100002, [TABERU_LIVE, TABERU_EAT]),          # (a) swapped
    entry(100003, [IKU_GO, IKU_HELD, IKU_PROCEED]),    # (b) inserted
    entry(100004, [MIRU_V2]),                          # (c) zh rewrite
    entry(100005, [KAKARU_COST_A, KAKARU_COST_B]),     # (d) collision pair
    entry(100006, [MIZU]),
    entry(100007, [HON_BOOK]),                         # (e) dropped sense
]

def emit(entries, dataset_version):
    """Assign sense_id / sense_order by emission order (build_dictionary.py
    `sense_id += 1` semantics): id is a build artifact, not an identity."""
    sense_id = 0
    out_entries = []
    for e in entries:
        rows = []
        for order, s in enumerate(e["senses"]):
            sense_id += 1
            row = {"sense_id": sense_id, "sense_order": order}
            row.update(s)
            rows.append(row)
        out_entries.append({"entry_id": e["entry_id"], "senses": rows})
    return {"dataset_version": dataset_version, "entries": out_entries}

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    for name, snapshot in (
        ("snapshot-v1.json", emit(V1, "jmdict-spike-v1")),
        ("snapshot-v2.json", emit(V2, "jmdict-spike-v2")),
    ):
        path = os.path.join(here, name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(snapshot, f, ensure_ascii=False, indent=2,
                      sort_keys=False)
            f.write("\n")
        n = sum(len(e["senses"]) for e in snapshot["entries"])
        print(f"wrote {name}: {len(snapshot['entries'])} entries / {n} senses")

if __name__ == "__main__":
    main()
