#!/usr/bin/env python3
"""
Archive, then delete, every audit document of one domain indexed before a cutoff.

  1. Lists the domain's indices and counts matching documents per index.
  2. Exports them to a zip (one NDJSON file per index + mappings/settings + manifest), then
     checks the zip's CRCs and that the exported count equals the counted one.
     Skipped with --no-archive (delete only, nothing recoverable).
  3. Asks for confirmation, then runs _delete_by_query per index with the SAME query.

Documents are selected by `@timestamp < cutoff` AND `domain == <domain>`. @timestamp is the
indexing time set by the audit stream (OpensearchIndexer), so nothing new can start matching
between the export and the delete - the delete removes exactly what was archived.

Python 3.9+ standard library only. No authentication (plain HTTP endpoint).

Examples:
  # 1. See what would be affected - touches nothing
  ./opensearch_archive_and_delete_domain.py --host http://localhost:9200 --domain wcbno \\
      --before "2026-09-30 12:15" --dry-run

  # AWS VPC domain through an SSM tunnel (see --insecure)
  ./opensearch_archive_and_delete_domain.py --host https://localhost:9200 --insecure --domain wcbno \\
      --before "2026-09-30 12:15" --dry-run

  # 2. Archive then delete (asks for confirmation before deleting)
  ./opensearch_archive_and_delete_domain.py --host http://localhost:9200 --domain wcbno \\
      --before "2026-09-30 12:15"

Restore (per index file):  each line is {"_index", "_id", "_source"}; replay it with _bulk.
"""
import argparse
import json
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

PARIS = ZoneInfo("Europe/Paris")


class OpenSearch:
    def __init__(self, host, timeout, insecure=False):
        self.host = host.rstrip("/")
        self.timeout = timeout
        # For tunnels (SSM port forwarding to https://localhost:<port>), where the domain's
        # certificate can't match the host we connect to.
        self.ssl_context = ssl._create_unverified_context() if insecure else None

    def request(self, method, path, body=None, params=None):
        url = self.host + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout, context=self.ssl_context) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raise SystemExit(f"❌ {method} {path} -> HTTP {e.code}: {e.read().decode(errors='replace')[:2000]}")
        except urllib.error.URLError as e:
            raise SystemExit(f"❌ {method} {path} -> {e.reason}")


def parse_cutoff(value):
    # Naive values are Paris local time (DST handled by zoneinfo); explicit offsets are kept.
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=PARIS)
    return dt


def build_query(domain, cutoff_ms, time_field):
    return {"bool": {"filter": [
        {"term": {"domain": domain}},
        {"range": {time_field: {"lt": cutoff_ms, "format": "epoch_millis"}}},
    ]}}


def list_indices(os_, pattern):
    rows = os_.request("GET", f"/_cat/indices/{urllib.parse.quote(pattern, safe='*,')}",
                       params={"format": "json", "expand_wildcards": "all",
                               "h": "index,status,docs.count,store.size"})
    closed = [r["index"] for r in rows if r.get("status") == "close"]
    if closed:
        print(f"⚠️  {len(closed)} closed index(es) skipped (cannot be read): {', '.join(sorted(closed))}")
    return sorted((r for r in rows if r.get("status") != "close"), key=lambda r: r["index"])


def export(os_, indices, query, counts, zip_path, manifest, batch_size, scroll):
    exported = {}
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6,
                         allowZip64=True) as zf:
        for index in indices:
            if counts[index] == 0:
                continue
            meta = {
                "mappings": os_.request("GET", f"/{index}/_mapping"),
                "settings": os_.request("GET", f"/{index}/_settings"),
                "aliases": os_.request("GET", f"/{index}/_alias"),
            }
            zf.writestr(f"{index}/index_metadata.json", json.dumps(meta, indent=2))

            n = 0
            started = time.time()
            entry = zipfile.ZipInfo(f"{index}/documents.ndjson", date_time=time.localtime()[:6])
            entry.compress_type = zipfile.ZIP_DEFLATED
            with zf.open(entry, "w", force_zip64=True) as out:
                resp = os_.request("POST", f"/{index}/_search", params={"scroll": scroll},
                                   body={"size": batch_size, "sort": ["_doc"], "query": query})
                scroll_id = resp.get("_scroll_id")
                try:
                    while True:
                        hits = resp["hits"]["hits"]
                        if not hits:
                            break
                        for h in hits:
                            out.write(json.dumps({"_index": h["_index"], "_id": h["_id"],
                                                  "_source": h["_source"]},
                                                 ensure_ascii=False).encode() + b"\n")
                        n += len(hits)
                        rate = n / max(time.time() - started, 0.001)
                        print(f"\r   {index}: {n}/{counts[index]} ({rate:.0f} docs/s)", end="", flush=True)
                        resp = os_.request("POST", "/_search/scroll",
                                           body={"scroll": scroll, "scroll_id": scroll_id})
                        scroll_id = resp.get("_scroll_id", scroll_id)
                finally:
                    if scroll_id:
                        try:
                            os_.request("DELETE", "/_search/scroll", body={"scroll_id": scroll_id})
                        except SystemExit:
                            pass
            print()
            exported[index] = n

        manifest["exported"] = exported
        zf.writestr("manifest.json", json.dumps(manifest, indent=2))
    return exported


def verify_zip(zip_path):
    with zipfile.ZipFile(zip_path) as zf:
        bad = zf.testzip()
        if bad:
            raise SystemExit(f"❌ Archive corrupted (CRC mismatch on {bad}) - nothing deleted.")


def delete(os_, indices, query, counts, poll_seconds):
    results = {}
    for index in indices:
        if counts[index] == 0:
            continue
        task = os_.request("POST", f"/{index}/_delete_by_query",
                           params={"conflicts": "proceed", "wait_for_completion": "false",
                                   "slices": "auto", "refresh": "true"},
                           body={"query": query})["task"]
        print(f"   {index}: task {task}")
        while True:
            t = os_.request("GET", f"/_tasks/{task}")
            status = t.get("task", {}).get("status", {})
            print(f"\r   {index}: deleted {status.get('deleted', 0)}/{status.get('total', counts[index])}",
                  end="", flush=True)
            if t.get("completed"):
                break
            time.sleep(poll_seconds)
        print()
        response = t.get("response", {})
        if t.get("error") or response.get("failures"):
            print(f"   ⚠️  {index}: errors: {json.dumps(t.get('error') or response.get('failures'))[:1000]}")
        results[index] = response.get("deleted", 0)
    return results


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", required=True, help="OpenSearch URL, e.g. http://10.0.0.1:9200")
    p.add_argument("--domain", required=True, help="Audit domain, e.g. wcbno")
    p.add_argument("--before", required=True,
                   help='Cutoff, exclusive. Paris time unless an offset is given, e.g. "2026-09-30 12:15"')
    p.add_argument("--index-pattern", help="Default: <domain>-auditdata-*")
    p.add_argument("--time-field", default="@timestamp",
                   help="Default @timestamp (indexing time). Use 'start' for the report's own event time.")
    p.add_argument("--output", help="Zip path. Default: <domain>-before-<cutoff>.zip")
    p.add_argument("--dry-run", action="store_true", help="Only list indices and counts")
    p.add_argument("--export-only", action="store_true", help="Archive, but do not delete")
    p.add_argument("--no-archive", action="store_true",
                   help="Delete WITHOUT archiving first - the documents are gone for good")
    p.add_argument("--yes", action="store_true", help="Do not ask for confirmation before deleting")
    p.add_argument("--batch-size", type=int, default=5000)
    p.add_argument("--scroll", default="10m")
    p.add_argument("--timeout", type=int, default=120, help="HTTP timeout in seconds")
    p.add_argument("--insecure", action="store_true",
                   help="Skip TLS certificate verification (e.g. https://localhost through an SSM tunnel)")
    args = p.parse_args()
    if args.no_archive and (args.export_only or args.output):
        p.error("--no-archive cannot be combined with --export-only or --output")

    os_ = OpenSearch(args.host, args.timeout, args.insecure)
    cutoff = parse_cutoff(args.before)
    cutoff_ms = int(cutoff.timestamp() * 1000)
    pattern = args.index_pattern or f"{args.domain}-auditdata-*"
    query = build_query(args.domain, cutoff_ms, args.time_field)

    print(f"Host     : {args.host}")
    print(f"Indices  : {pattern}")
    print(f"Filter   : domain = {args.domain} AND {args.time_field} < "
          f"{cutoff.astimezone(PARIS):%Y-%m-%d %H:%M:%S %Z} ({cutoff.astimezone(timezone.utc):%Y-%m-%dT%H:%M:%SZ}, {cutoff_ms})")

    rows = list_indices(os_, pattern)
    if not rows:
        raise SystemExit(f"No index matches {pattern}")
    indices = [r["index"] for r in rows]
    counts = {i: os_.request("POST", f"/{i}/_count", body={"query": query})["count"] for i in indices}
    total = sum(counts.values())

    print(f"\n{'index':<60} {'total docs':>12} {'size':>9} {'to delete':>12}")
    for r in rows:
        print(f"{r['index']:<60} {r['docs.count'] or 0:>12} {r['store.size'] or '':>9} {counts[r['index']]:>12}")
    print(f"{'TOTAL':<60} {'':>12} {'':>9} {total:>12}\n")

    if args.dry_run or total == 0:
        print("Dry run - nothing exported or deleted." if args.dry_run else "Nothing to do.")
        return

    if args.no_archive:
        print("⚠️  --no-archive: skipping the export, these documents will NOT be recoverable.")
    else:
        archive(os_, args, indices, query, counts, total, cutoff, cutoff_ms, pattern)
        if args.export_only:
            print("Export only - nothing deleted.")
            return

    if not args.yes:
        affected = sum(1 for c in counts.values() if c)
        backup = "WITHOUT any backup" if args.no_archive else "(archived)"
        try:
            answer = input(f"\nDelete these {total} documents {backup} from {affected} index(es) on {args.host}? "
                           f"Type the domain name ({args.domain}) to confirm: ")
        except EOFError:
            # No stdin (nohup, cron, piped): never delete without an explicit --yes.
            print("\nNo terminal to confirm from - nothing deleted. Re-run with --yes to delete non-interactively.")
            return
        if answer.strip() != args.domain:
            print("Aborted - nothing deleted.")
            return

    print("➡️  Deleting")
    deleted = delete(os_, indices, query, counts, poll_seconds=2)
    remaining = {i: os_.request("POST", f"/{i}/_count", body={"query": query})["count"]
                 for i in indices if counts[i]}
    print(f"\n✅ Deleted {sum(deleted.values())} of {total} documents.")
    left = {i: n for i, n in remaining.items() if n}
    if left:
        print(f"⚠️  Still matching after delete: {left}")
    print("Note: disk space is reclaimed progressively by segment merges, not immediately.")


def archive(os_, args, indices, query, counts, total, cutoff, cutoff_ms, pattern):
    zip_path = args.output or f"{args.domain}-before-{cutoff.astimezone(PARIS):%Y%m%d-%H%M}.zip"
    manifest = {
        "host": args.host, "domain": args.domain, "index_pattern": pattern,
        "cutoff": cutoff.isoformat(), "cutoff_epoch_ms": cutoff_ms, "time_field": args.time_field,
        "query": query, "counted": counts,
        "exported_at": datetime.now(timezone.utc).isoformat(),
    }
    print(f"➡️  Exporting {total} documents to {zip_path}")
    exported = export(os_, indices, query, counts, zip_path, manifest, args.batch_size, args.scroll)
    verify_zip(zip_path)

    mismatches = {i: (counts[i], exported.get(i, 0)) for i in indices if counts[i] != exported.get(i, 0)}
    if mismatches:
        for i, (c, e) in mismatches.items():
            print(f"❌ {i}: counted {c}, exported {e}")
        raise SystemExit("❌ Export incomplete - nothing deleted.")
    print(f"✅ Archive verified: {sum(exported.values())} documents in {zip_path}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\nInterrupted.")
