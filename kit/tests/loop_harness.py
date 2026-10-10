"""Runs loop.sh against a fake status file, fake pass and fake alerter, one scenario at a time.

usage: loop_harness.py LOOP_SH [scenario ...]; prints PASS/FAIL per scenario, exits 1 on any FAIL.
The script is run as shipped, through its LOOP_* overrides. Nothing leaves the machine.
"""
import json, os, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
BRANCH = "agent/loop-f001-thing"


def sh(*a, cwd=None):
    subprocess.run(a, cwd=cwd, check=True, capture_output=True)


class Box:
    def __init__(self, loop, prs, parked=(), pass_results=("ok",)):
        self.t = Path(tempfile.mkdtemp(prefix="loop-"))
        t = self.t
        for d in ("state", "status", "rec"):
            (t / d).mkdir()
        sh("git", "init", "-q", str(t / "mirror"))
        sh("git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "m", cwd=t / "mirror")
        sh("git", "update-ref", "refs/remotes/origin/main", "HEAD", cwd=t / "mirror")
        sh("git", "clone", "-q", "--bare", str(t / "mirror"), str(t / "origin.git"))
        sh("git", "--git-dir", str(t / "origin.git"), "branch", BRANCH)
        (t / "status" / "prs.json").write_text(json.dumps(prs))
        (t / "state" / "seen").write_text("")            # not a first run
        (t / "state" / "last_pass").write_text(str(int(time.time())) + "\n")   # not idle
        if parked:
            (t / "state" / "parked").write_text("\n".join(map(str, parked)) + "\n")
        (t / "rec" / "results").write_text("\n".join(pass_results) + "\n")
        fake = t / "pass.sh"
        fake.write_text(f"""#!/bin/bash
n=$(ls {t}/rec | grep -c '^prompt-')
cp "$2" {t}/rec/prompt-$n
r=$(sed -n "$((n + 1))p" {t}/rec/results); r=${{r:-ok}}
if [ "$r" = ok ]; then echo '{{"type": "result", "total_cost_usd": 0.01}}'; exit 0; fi
echo boom >&2; exit 1
""")
        fake.chmod(0o755)
        alert = t / "alert.sh"
        alert.write_text(f"#!/bin/bash\nprintf '%s %s\\n' \"$1\" \"$2\" >> {t}/rec/alerts\n")
        alert.chmod(0o755)
        self.env = {**os.environ, "LOOP_STATUS": str(t / "status" / "prs.json"), "LOOP_MIRROR": str(t / "mirror"),
                    "LOOP_STOPFILES": str(t / "STOP"), "LOOP_HC": str(t / "nohc"), "LOOP_ALERT": str(alert),
                    "LOOP_ORIGIN": str(t / "origin.git"), "LOOP_STATE": str(t / "state"), "LOOP_RUNNER": "direct",
                    "LOOP_PASS": str(fake), "LOOP_POLL": "1", "LOOP_BACKOFF": "1", "LOOP_CONF": str(t / "noconf"),
                    "LOOP_PATH": f"{HERE / 'shim'}:/usr/sbin:/usr/bin:/sbin:/bin:/opt/homebrew/bin:/usr/local/bin"}
        self.loop = loop

    def run(self, seconds):
        p = subprocess.Popen(["bash", self.loop], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, start_new_session=True)
        time.sleep(seconds)
        os.killpg(p.pid, signal.SIGTERM)
        self.log = p.communicate()[0]
        rec = self.t / "rec"
        self.prompts = [f.read_text() for f in sorted(rec.glob("prompt-*"), key=lambda f: int(f.name.split("-")[1]))]
        self.alerts = (rec / "alerts").read_text().splitlines() if (rec / "alerts").exists() else []
        st = self.t / "state"
        self.parked = (st / "parked").read_text().split() if (st / "parked").exists() else []
        self.rebuild = (st / "rebuild").exists()
        shutil.rmtree(self.t, ignore_errors=True)
        return self


def pr(number=7, branch=BRANCH, state="OPEN", text="", **kw):
    return {"number": number, "branch": branch, "state": state, "isDraft": False, "url": "u",
            "last_comment": text, "last_review": "", **kw}


def is_rebuild(prompt):
    return f"Loop PR #7 ({BRANCH}) cannot merge" in prompt and "Rebuild it on a new branch" in prompt


def s_a_conflicting_pr_is_parked_at_once_and_rebuilt_once(loop):
    b = Box(loop, [pr(mergeable="CONFLICTING")]).run(7)
    assert b.parked == ["7"], b.parked
    assert len(b.alerts) == 1 and "PR #7 parked: it conflicts with main" in b.alerts[0], b.alerts
    assert len(b.prompts) == 1 and is_rebuild(b.prompts[0]), (len(b.prompts), b.prompts[:1])
    assert "(rebuild #7) ended: ok" in b.log, b.log
    assert not b.rebuild


def s_a_conflicting_pr_with_a_review_is_rebuilt_not_fixed(loop):
    b = Box(loop, [pr(mergeable="CONFLICTING", text="HIGH: something")]).run(7)
    assert b.parked == ["7"] and len(b.prompts) == 1 and is_rebuild(b.prompts[0]), (b.parked, b.prompts[:1])


def s_a_mergeable_pr_waits_as_before(loop):
    b = Box(loop, [pr(mergeable="MERGEABLE")]).run(5)
    assert b.parked == [] and b.prompts == [] and b.alerts == [], (b.parked, b.prompts, b.alerts)


def s_an_unknown_or_missing_mergeable_is_not_a_conflict(loop):
    for extra in ({"mergeable": "UNKNOWN"}, {"mergeable": None}, {}):
        b = Box(loop, [pr(**extra)]).run(4)
        assert b.parked == [] and b.prompts == [], (extra, b.parked, b.prompts)


def s_a_pr_already_parked_is_left_alone(loop):
    b = Box(loop, [pr(mergeable="CONFLICTING")], parked=[7]).run(5)
    assert b.parked == ["7"] and b.prompts == [] and b.alerts == [], (b.parked, b.prompts, b.alerts)


def s_another_agents_conflicting_branch_is_ignored(loop):
    b = Box(loop, [pr(branch="agent/other", mergeable="CONFLICTING")]).run(5)
    assert b.parked == [] and b.prompts == [], (b.parked, b.prompts)


def s_a_failed_rebuild_is_tried_again_and_only_success_clears_it(loop):
    b = Box(loop, [pr(mergeable="CONFLICTING")], pass_results=("fail", "ok")).run(11)
    assert len(b.prompts) == 2 and all(map(is_rebuild, b.prompts)), (len(b.prompts), b.log)
    assert "(rebuild #7) ended: fail" in b.log and "(rebuild #7) ended: ok" in b.log, b.log
    assert not b.rebuild
    stuck = Box(loop, [pr(mergeable="CONFLICTING")], pass_results=("fail", "fail", "fail", "fail")).run(6)
    assert stuck.rebuild and stuck.prompts and all(map(is_rebuild, stuck.prompts)), stuck.log


def s_with_no_pr_open_the_ordinary_pass_is_unchanged(loop):
    b = Box(loop, [pr(state="MERGED", text="merged")]).run(5)   # one new event, no open PR
    assert len(b.prompts) == 1 and "Run /next" in b.prompts[0] and "cannot merge" not in b.prompts[0], b.prompts


SCENARIOS = {k[2:]: v for k, v in globals().items() if k.startswith("s_")}

if __name__ == "__main__":
    loop, names = sys.argv[1], sys.argv[2:] or list(SCENARIOS)
    bad = 0
    for name in names:
        try:
            SCENARIOS[name](loop); print("PASS", name)
        except AssertionError as e:
            bad = 1; print("FAIL", name, "|", str(e)[:300])
    sys.exit(bad)
