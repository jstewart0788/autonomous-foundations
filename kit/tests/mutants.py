"""Breaks courier.sh one rule at a time and checks the harness notices.

Every line must print RED. A GREEN means the harness would not catch that rule being removed,
and a mutant that no longer applies means the script changed and this list did not.

usage: mutants.py    -> exits 1 on any GREEN or unapplied mutant
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COURIER = os.path.join(os.path.dirname(HERE), "courier.sh")
src = open(COURIER).read()
M = [

 ("a closed follow-up does not stop the walk", '                *) verdict=closed; break ;;', '                *) ;;'),
 ("the original's PR list is reused for the target", '                "") target=$cand prs=""; break ;;', '                "") target=$cand; break ;;'),
 ("a failed listing reads as no PR", 'if ! cprs=$(list_prs "$cand"); then verdict=retry; break; fi', 'cprs=$(list_prs "$cand") || true'),
 ("a merged PR is treated as closed", '        if [[ "$newest" != *" MERGED" ]]; then', '        if true; then'),
 ("a closed PR is salvaged", '        if [[ "$newest" != *" MERGED" ]]; then', '        if false; then'),
 ("no local copy of the follow-up", '        if lerr=$(git -C "$WORK" push -q "$LOCAL" "refs/courier/${name}:refs/heads/${target}" 2>&1); then', '        if lerr=$(true); then'),
 ("the local copy is forced", 'push -q "$LOCAL" "refs/courier/${name}:refs/heads/${target}" 2>&1); then', 'push -q -f "$LOCAL" "refs/courier/${name}:refs/heads/${target}" 2>&1); then'),
 ("a local rejection is retried forever", """            refuse "$name" "$target is on GitHub, but the local repo holds a different $target"
""", """            refuse "$name" "$target is on GitHub, but the local repo holds a different $target"; continue
"""),
 ("the root is not recovered from a late branch", """        root=$(sed -E 's/-late[0-9]?$//' <<<"$name")""", '        root=$name'),
 ("late commits are pushed to the merged branch", '"refs/courier/${name}:refs/heads/${target}" 2>&1); then\n        perr', '"refs/courier/${name}:refs/heads/${name}" 2>&1); then\n        perr'),
 ("the follow-up PR does not say what it follows", """        [ -z "$late_of" ] || body="Commits pushed to $name after #$late_of merged."$'\\n\\n'"$body"\n""", ''),
 ("the PR is opened for the merged branch", '--head "$target" --title', '--head "$name" --title'),
 ("a branch that changes no file is forwarded", '    if [ "$same" -eq 0 ]; then', '    if false; then'),
 ("the tree is compared with the tip instead of the base", 'diff --quiet "$base" "refs/courier/${name}" || same=$?', 'diff --quiet "refs/courier/${name}" "refs/courier/${name}" || same=$?'),
 ("only the tip commit is compared", 'diff --quiet "$base" "refs/courier/${name}" || same=$?', 'diff --quiet "refs/courier/${name}~1" "refs/courier/${name}" || same=$?'),
 ("CI config is no longer a protected path", r"PROTECTED='^(\.github(/|$)|", r"PROTECTED='^(\.githubX(/|$)|"),
 ("a code-host server error is a final refusal", '''if grep -q 'rejected' <<<"$perr" && ! grep -Eqi "$SERVER_FAULT" <<<"$perr"; then''', '''if grep -q 'rejected' <<<"$perr"; then'''),
 ("no rejection is ever final", '''if grep -q 'rejected' <<<"$perr" && ! grep -Eqi "$SERVER_FAULT" <<<"$perr"; then''', '''if false; then'''),
 ("a parked PR is closed whether or not it conflicts", 'if str(p["number"]) in parked and p.get("mergeable") == "CONFLICTING":', 'if str(p["number"]) in parked:'),
 ("a conflicting PR is closed whether or not the loop parked it", 'if str(p["number"]) in parked and p.get("mergeable") == "CONFLICTING":', 'if p.get("mergeable") == "CONFLICTING":'),
 ("a parked conflicting PR is closed before its successor exists", 'successors = [p["number"] for p in opens', 'successors = [0] + [p["number"] for p in opens'),
]
tmp = os.path.join(HERE, "courier.mut.sh")


def run(path):
    r = subprocess.run([sys.executable, os.path.join(HERE, "harness.py"), path], capture_output=True, text=True)
    return r.returncode, [line.split()[1] for line in r.stdout.splitlines() if line.startswith(("FAIL", "ERROR"))]


rc, fails = run(COURIER)
print("BASE ", "green" if rc == 0 else f"RED {fails}")
bad = int(rc != 0)
try:
    for name, old, new in M:
        if src.count(old) != 1:
            print("UNAPPLIED", name)
            bad += 1
            continue
        open(tmp, "w").write(src.replace(old, new))
        rc, fails = run(tmp)
        print("RED  " if rc else "GREEN", name, "|", fails[:3])
        bad += rc == 0
finally:
    if os.path.exists(tmp):
        os.remove(tmp)
sys.exit(1 if bad else 0)
