#!/usr/bin/env python3
"""Verify claims against a codebase directory using structured matching and grep."""

import argparse
import json
import os
import re
import subprocess
import sys

ACTION_VERBS_REMOVE = {
    "removed", "deleted", "dropped", "stripped", "eliminated",
    "remove", "delete", "drop", "strip", "eliminate",
}
ACTION_VERBS_ADD = {
    "added", "implemented", "created", "introduced", "built", "wrote",
    "modified", "updated", "changed", "add", "implement", "create",
    "introduce", "build", "write", "modify", "update", "change",
}
STOPWORDS = {
    "with", "from", "that", "this", "into", "have", "been", "will",
    "should", "would", "could", "also", "then", "than", "when", "what",
    "which", "their", "there", "here", "were", "some", "each", "every",
    "both", "only", "just", "more", "most", "such", "very", "much",
    "like", "over", "make", "made", "does", "done", "about", "after",
    "before", "between", "through", "under", "again", "further",
    "once", "during", "while", "where", "these", "those", "other",
    "same", "different", "first", "last", "next", "back", "still",
    "well", "used", "using", "uses", "need", "needs", "file",
    "function", "method", "class", "module", "package",
}
KNOWN_EXTENSIONS = {
    ".js", ".py", ".json", ".html", ".css", ".ts", ".tsx", ".jsx",
    ".sh", ".md", ".txt", ".yml", ".yaml", ".toml", ".cfg", ".ini",
    ".rs", ".go", ".java", ".rb", ".php", ".c", ".h", ".cpp",
}
EXCLUDE_DIRS = {".git", "node_modules", "dist", "build", "__MACOSX"}


def parse_claims(claims_file):
    """Parse claims file. Supports plan.md and freeform formats."""
    claims = []
    with open(claims_file, "r") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("- "):
                continue
            text = line[2:]

            checked = False
            m = re.match(r"\[([xX ])\]\s*(.*)", text)
            if m:
                checked = m.group(1).lower() == "x"
                text = m.group(2)

            claim = parse_single_claim(text)
            claim["checked"] = checked
            claim["raw"] = line
            claims.append(claim)
    return claims


def parse_single_claim(text):
    """Parse a single claim into structured form."""
    result = {
        "id": None,
        "text": text,
        "action": None,
        "target": None,
        "pattern": None,
    }

    # **ID** prefix (plan.md format)
    m = re.match(r"\*\*(\S+?)\*\*\s*(.*)", text)
    if m:
        result["id"] = m.group(1)
        text = m.group(2)
        result["text"] = text

    # [TODO ID] prefix
    m = re.match(r"\[TODO\s+(\S+)\]\s*(.*)", text, re.IGNORECASE)
    if m:
        result["id"] = m.group(1)
        text = m.group(2)
        result["text"] = text

    # Structured: "add file X" / "remove file X"
    m = re.match(r"(add|remove|delete|create)\s+file\s+(\S+)", text, re.I)
    if m:
        action_word = m.group(1).lower()
        result["action"] = "remove" if action_word in ("remove", "delete") else "add"
        result["target"] = m.group(2).strip("`")
        return result

    # Structured: must contain "X" in Y (literal substring by default)
    m = re.match(r'must\s+contain\s+"([^"]+)"\s+in\s+(\S+)', text, re.I)
    if m:
        result["action"] = "contains"
        result["pattern"] = m.group(1)
        result["target"] = m.group(2).strip("`")
        return result

    # Freeform: detect action from verbs
    words = text.lower().split()
    for w in words:
        bare = w.strip(".,;:!?`'\"")
        if bare in ACTION_VERBS_REMOVE:
            result["action"] = "remove"
            break
        elif bare in ACTION_VERBS_ADD:
            result["action"] = "add"
            break

    return result


def extract_tokens(text):
    """Extract meaningful search tokens from claim text.
    Preserves original case for grep accuracy."""
    words = re.findall(r"[\w.\-/]+", text)
    tokens = []
    file_patterns = []

    for word in words:
        bare = word.strip(".,;:!?`'\"")
        if not bare or len(bare) <= 3:
            continue
        lower = bare.lower()
        if lower in STOPWORDS:
            continue
        if lower in ACTION_VERBS_ADD | ACTION_VERBS_REMOVE:
            continue

        ext = os.path.splitext(bare)[1]
        if ext in KNOWN_EXTENSIONS or "/" in bare:
            file_patterns.append(bare)
        else:
            tokens.append(bare)

    return tokens, file_patterns


def search_in_dir(pattern, directory, file_glob=None):
    """Search for pattern using rg (fallback grep). Returns evidence list."""
    matches = []

    # Try rg
    try:
        args = ["rg", "-in", "--no-heading", "-m", "5"]
        if file_glob:
            args.extend(["-g", file_glob])
        args.extend([pattern, directory])
        result = subprocess.run(args, capture_output=True, text=True, timeout=10)
        if result.stdout.strip():
            for line in result.stdout.strip().split("\n")[:3]:
                matches.append(parse_grep_line(line))
            return matches
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # Fallback to grep
    try:
        args = ["grep", "-rin", "-m", "5"]
        if file_glob:
            args.extend(["--include", file_glob])
        args.extend([pattern, directory])
        result = subprocess.run(args, capture_output=True, text=True, timeout=10)
        if result.stdout.strip():
            for line in result.stdout.strip().split("\n")[:3]:
                matches.append(parse_grep_line(line))
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return matches


def parse_grep_line(line):
    """Parse grep output into structured evidence."""
    parts = line.split(":", 2)
    if len(parts) >= 3:
        return {
            "type": "grep_hit",
            "file": parts[0],
            "line": int(parts[1]) if parts[1].isdigit() else 0,
            "snippet": parts[2].strip()[:200],
        }
    return {"type": "grep_hit", "file": "", "line": 0, "snippet": line[:200]}


def check_file_exists(filename, directory):
    """Check if file exists. Returns full path or None."""
    for root, dirs, files in os.walk(directory):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for f in files:
            if f == filename or filename == os.path.relpath(os.path.join(root, f), directory):
                return os.path.relpath(os.path.join(root, f), directory)
    return None


def get_git_diff_info(ref, directory):
    """Get git diff data for --git-diff mode."""
    try:
        result = subprocess.run(
            ["git", "diff", "--name-status", ref],
            capture_output=True, text=True, cwd=directory, timeout=10,
        )
        name_status = {}
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                name_status[parts[1]] = parts[0]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None, None

    try:
        result = subprocess.run(
            ["git", "diff", ref],
            capture_output=True, text=True, cwd=directory, timeout=10,
        )
        diff_content = result.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        diff_content = ""

    return name_status, diff_content


def search_in_diff(pattern, diff_content):
    """Search for pattern in git diff added lines."""
    matches = []
    current_file = None
    current_line = 0
    pat_lower = pattern.lower()

    for line in diff_content.split("\n"):
        if line.startswith("+++ b/"):
            current_file = line[6:]
        elif line.startswith("@@ "):
            m = re.search(r"\+(\d+)", line)
            if m:
                current_line = int(m.group(1))
        elif line.startswith("+") and not line.startswith("+++"):
            if pat_lower in line.lower():
                matches.append({
                    "type": "diff_hit",
                    "file": current_file or "",
                    "line": current_line,
                    "snippet": line[1:].strip()[:200],
                })
            current_line += 1
        elif not line.startswith("-"):
            current_line += 1

    return matches[:3]


def dedup_evidence(evidence, limit=3):
    """Deduplicate and limit evidence list."""
    seen = set()
    unique = []
    for e in evidence:
        key = (e.get("file", ""), e.get("line", 0), e.get("snippet", ""))
        if key not in seen:
            seen.add(key)
            unique.append(e)
    return unique[:limit]


def collect_closest_hits(terms, directory, diff_content=None):
    """Collect closest grep hits for UNKNOWN verdicts."""
    hits = []
    for term in terms[:5]:
        if diff_content is not None:
            found = search_in_diff(term, diff_content)
        else:
            found = search_in_dir(term, directory)
        hits.extend(found)
    return dedup_evidence(hits, 3)


def verify_claim(claim, directory, git_diff_info=None):
    """Verify a single claim. Returns (verdict, evidence)."""
    if claim.get("checked"):
        return "SKIP", [{"type": "skip", "file": "", "line": 0, "snippet": "Already checked in plan"}]

    name_status, diff_content = git_diff_info or (None, None)
    using_diff = name_status is not None

    # Structured: "must contain" (literal substring)
    if claim["action"] == "contains" and claim["pattern"] and claim["target"]:
        target = claim["target"]
        pattern = claim["pattern"]

        if using_diff:
            hits = search_in_diff(pattern, diff_content)
            if hits:
                return "PASS", hits
            target_changed = any(target in p for p in name_status)
            if target_changed:
                return "UNKNOWN", [{"type": "diff_hit", "file": target, "line": 0,
                    "snippet": "File changed but pattern not found in diff"}]

        target_path = os.path.join(directory, target)
        if os.path.isfile(target_path):
            hits = search_in_dir(pattern, directory, os.path.basename(target))
            if hits:
                return "PASS", hits
            return "FAIL", [{"type": "grep_hit", "file": target, "line": 0,
                "snippet": f"Pattern '{pattern}' not found in {target}"}]
        return "FAIL", [{"type": "file_exists", "file": target, "line": 0,
            "snippet": f"File {target} does not exist"}]

    # Structured: file add/remove
    if claim["target"] and claim["action"] in ("add", "remove"):
        target = claim["target"]

        if using_diff:
            for path, status in name_status.items():
                if target in path:
                    if claim["action"] == "add" and status in ("A", "M"):
                        return "PASS", [{"type": "diff_hit", "file": path, "line": 0,
                            "snippet": f"File status '{status}' in git diff"}]
                    elif claim["action"] == "remove" and status == "D":
                        return "PASS", [{"type": "diff_hit", "file": path, "line": 0,
                            "snippet": "File deleted in git diff"}]

        basename = os.path.basename(target)
        found = check_file_exists(basename, directory)

        if claim["action"] == "remove":
            if not found:
                return "PASS", [{"type": "file_exists", "file": target, "line": 0,
                    "snippet": f"{target} not found (expected for removal)"}]
            return "FAIL", [{"type": "file_exists", "file": found, "line": 0,
                "snippet": f"{target} still exists"}]

        if claim["action"] == "add":
            if found:
                return "PASS", [{"type": "file_exists", "file": found, "line": 0,
                    "snippet": f"{target} found"}]
            return "UNKNOWN", [{"type": "file_exists", "file": target, "line": 0,
                "snippet": f"{target} not found"}]

    # Freeform: token matching
    tokens, file_patterns = extract_tokens(claim["text"])
    evidence = []
    match_count = 0

    for fp in file_patterns:
        basename = os.path.basename(fp)
        found = check_file_exists(basename, directory)

        if claim["action"] == "remove":
            if not found:
                return "PASS", [{"type": "file_exists", "file": fp, "line": 0,
                    "snippet": f"{fp} not found (expected)"}]
            return "FAIL", [{"type": "file_exists", "file": found, "line": 0,
                "snippet": f"{fp} still exists"}]

        if found:
            match_count += 1
            evidence.append({"type": "file_exists", "file": found, "line": 0,
                "snippet": "File found"})

        if using_diff:
            hits = search_in_diff(fp, diff_content)
        else:
            hits = search_in_dir(fp, directory)
        if hits:
            match_count += 1
            evidence.extend(hits)

    for token in tokens:
        if using_diff:
            hits = search_in_diff(token, diff_content)
        else:
            hits = search_in_dir(token, directory)
        if hits:
            match_count += 1
            evidence.extend(hits)

    evidence = dedup_evidence(evidence, 3)

    if claim["action"] == "remove" and not file_patterns:
        return "UNKNOWN", evidence or [{"type": "grep_hit", "file": "", "line": 0,
            "snippet": "No file pattern to check for removal"}]

    if match_count >= 2:
        if not evidence:
            return "UNKNOWN", [{"type": "grep_hit", "file": "", "line": 0,
                "snippet": "Matches found but no anchored evidence"}]
        return "PASS", evidence

    # UNKNOWN: collect closest hits
    if not evidence:
        closest = collect_closest_hits(
            tokens + file_patterns, directory,
            diff_content if using_diff else None,
        )
        evidence = closest or [{"type": "grep_hit", "file": "", "line": 0,
            "snippet": "No matching evidence found"}]
    return "UNKNOWN", evidence


def format_evidence_text(evidence):
    """Format evidence for markdown output."""
    lines = []
    for e in evidence:
        if e["file"] and e["line"]:
            lines.append(f"  - [{e['type']}] `{e['file']}:{e['line']}: {e['snippet']}`")
        elif e["file"]:
            lines.append(f"  - [{e['type']}] `{e['file']}: {e['snippet']}`")
        else:
            lines.append(f"  - [{e['type']}] `{e['snippet']}`")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Verify claims against a codebase.")
    parser.add_argument("claims_file", help="Path to claims file")
    parser.add_argument("--dir", required=True, help="Directory to verify against")
    parser.add_argument("--json", dest="json_out", help="Write JSON report to file")
    parser.add_argument("--quiet", action="store_true",
        help="No output; exit 0=all PASS, 1=any FAIL, 2=UNKNOWN only")
    parser.add_argument("--git-diff", dest="git_ref", nargs="?", const="HEAD~1",
        default=None, help="Verify against git diff (default ref: HEAD~1)")
    parser.add_argument("--gates", action="store_true", help="Append gate summary")
    args = parser.parse_args()

    if not os.path.isfile(args.claims_file):
        print(f"ERROR: '{args.claims_file}' not found", file=sys.stderr)
        sys.exit(1)
    if not os.path.isdir(args.dir):
        print(f"ERROR: '{args.dir}' is not a directory", file=sys.stderr)
        sys.exit(1)

    git_diff_info = None
    if args.git_ref:
        ns, dc = get_git_diff_info(args.git_ref, args.dir)
        if ns is None:
            print("ERROR: git diff failed (not a git repo?)", file=sys.stderr)
            sys.exit(1)
        git_diff_info = (ns, dc)

    claims = parse_claims(args.claims_file)
    if not claims:
        if not args.quiet:
            print("No claims found")
        sys.exit(0)

    results = []
    for claim in claims:
        verdict, evidence = verify_claim(claim, args.dir, git_diff_info)
        results.append({
            "claim_id": claim.get("id"),
            "claim": claim["text"],
            "verdict": verdict,
            "evidence": evidence,
        })

    has_fail = any(r["verdict"] == "FAIL" for r in results)
    has_unknown = any(r["verdict"] == "UNKNOWN" for r in results)

    if not args.quiet:
        print("# Claim Verification Report\n")
        for i, r in enumerate(results, 1):
            id_prefix = f"{r['claim_id']}: " if r["claim_id"] else ""
            icon = {"PASS": "[PASS]", "FAIL": "[FAIL]", "UNKNOWN": "[UNKNOWN]", "SKIP": "[SKIP]"}[r["verdict"]]
            print(f"## {i}. {icon} {id_prefix}{r['claim']}\n")
            evidence_text = format_evidence_text(r["evidence"])
            if evidence_text:
                print(f"Evidence:\n{evidence_text}")
            print()

        total = len(results)
        passed = sum(1 for r in results if r["verdict"] == "PASS")
        failed = sum(1 for r in results if r["verdict"] == "FAIL")
        unknown = sum(1 for r in results if r["verdict"] == "UNKNOWN")
        skipped = sum(1 for r in results if r["verdict"] == "SKIP")
        summary = f"**Summary:** {passed}/{total} PASS, {failed} FAIL, {unknown} UNKNOWN"
        if skipped:
            summary += f", {skipped} SKIP"
        print(f"---\n{summary}")

        if args.gates:
            print("\nGATES:")
            if failed == 0 and unknown == 0:
                print("  PASS: all claims verified")
            if failed > 0:
                print(f"  FAIL: {failed} claim(s) failed verification")
            if unknown > 0:
                print(f"  WARN: {unknown} claim(s) could not be verified")
            if failed == 0:
                print("  PASS: no contradictions found")

    if args.json_out:
        output = {
            "results": results,
            "summary": {
                "total": len(results),
                "pass": sum(1 for r in results if r["verdict"] == "PASS"),
                "fail": sum(1 for r in results if r["verdict"] == "FAIL"),
                "unknown": sum(1 for r in results if r["verdict"] == "UNKNOWN"),
                "skip": sum(1 for r in results if r["verdict"] == "SKIP"),
            },
        }
        if args.gates:
            gates = []
            gates.append({"gate": "no_failures", "status": "FAIL" if has_fail else "PASS"})
            gates.append({"gate": "all_verified", "status": "WARN" if has_unknown else "PASS"})
            output["gates"] = gates
        with open(args.json_out, "w") as f:
            json.dump(output, f, indent=2)
        if not args.quiet:
            print(f"\nJSON report written to: {args.json_out}")

    if has_fail:
        sys.exit(1)
    elif has_unknown:
        sys.exit(2)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
