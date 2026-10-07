"""Runs courier.sh against a fake code host and a local bare repo, one scenario at a time.

The script under test is run as shipped. Only curl, gh, gitleaks and (for pushes that must fail)
git are replaced, by the stubs in bin/. Needs python3, git and bash; nothing is installed and
nothing leaves the machine.

usage: harness.py [COURIER] [scenario ...]   COURIER defaults to ../courier.sh
       prints PASS/FAIL per scenario and exits 1 on any FAIL
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
BIN = HERE / "bin"
REAL_GIT = shutil.which("git")
X = "agent/loop-x"


def sh(*args, cwd=None, check=True, env=None):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, env=env)
    if check and r.returncode:
        raise RuntimeError(f"{args}: {r.stderr}")
    return r.stdout.strip()


class Box:
    def __init__(self, courier):
        self.courier = courier
        self.t = Path(tempfile.mkdtemp(prefix="courier-"))
        for d in ("etc", "state", "status", "outbox", "fake"):
            (self.t / d).mkdir()
        (self.t / "etc" / "ntfy.curl").write_text("x\n")
        (self.t / "etc" / "token").write_text("tok\n")
        (self.t / "fake" / "prs").write_text("")
        self.remote, self.local, self.seed = self.t / "remote.git", self.t / "local.git", self.t / "seed"
        sh("git", "init", "-q", "--bare", str(self.remote))
        sh("git", "init", "-q", "--bare", str(self.local))
        sh("git", "init", "-q", "-b", "main", str(self.seed))
        self.g("commit", "-q", "--allow-empty", "-m", "base")
        self.g("push", "-q", str(self.remote), "main:refs/heads/main")
        self.g("push", "-q", str(self.local), "main:refs/heads/main")
        sh("git", "clone", "-q", str(self.remote), str(self.t / "work"))

    def g(self, *args, check=True):
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        return sh("git", *args, cwd=self.seed, check=check, env=env)

    def commit(self, branch, fname, start="main"):
        """Add one commit touching `fname` on a seed branch (created from `start` if new)."""
        if self.g("rev-parse", "-q", "--verify", branch, check=False):
            self.g("checkout", "-q", branch)
        else:
            self.g("checkout", "-q", "-b", branch, start)
        f = self.seed / fname
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text((f.read_text() if f.exists() else "") + "x\n")
        self.g("add", "-A")
        self.g("commit", "-q", "-m", f"{branch}: {fname}")
        return self.g("rev-parse", "HEAD")

    def to_local(self, branch, as_name=None, force=False):
        self.g("push", "-q", *(["-f"] if force else []), str(self.local),
               f"{branch}:refs/heads/{as_name or 'agent/' + branch}")

    def merge_into_main(self, branch):
        """What the bot does: a merge commit on main, pushed to GitHub."""
        self.g("checkout", "-q", "main")
        self.g("merge", "-q", "--no-ff", "-m", f"Merge {branch}", branch)
        self.g("push", "-q", str(self.remote), "main:refs/heads/main")

    def pr(self, head, number, state):
        with open(self.t / "fake" / "prs", "a") as f:
            f.write(f"{head} {number} {state}\n")

    def set_pr(self, head, state):
        p = self.t / "fake" / "prs"
        p.write_text("".join(f"{h} {n} {state if h == head else s}\n"
                             for h, n, s in (l.split() for l in p.read_text().splitlines())))

    def run(self):
        env = {**os.environ, "PATH": f"{BIN}:{os.environ['PATH']}", "FAKE": str(self.t / "fake"),
               "COURIER_LOCAL": str(self.local), "COURIER_WORK": str(self.t / "work"),
               "COURIER_OUTBOX": str(self.t / "outbox"), "COURIER_ETC": str(self.t / "etc"),
               "COURIER_STATE": str(self.t / "state"), "COURIER_STATUS": str(self.t / "status"),
               "COURIER_PARKED": str(self.t / "parked"), "COURIER_REMOTE": str(self.remote),
               "REAL_GIT": REAL_GIT}
        r = subprocess.run(["bash", self.courier], env=env, capture_output=True, text=True)
        self.log = r.stdout + r.stderr
        return self.log

    def remote_ref(self, name):
        return sh("git", "--git-dir", str(self.remote), "rev-parse", "-q", "--verify",
                  f"refs/heads/{name}", check=False)

    def local_ref(self, name):
        return sh("git", "--git-dir", str(self.local), "rev-parse", "-q", "--verify",
                  f"refs/heads/{name}", check=False)

    def remote_branches(self):
        return sorted(sh("git", "--git-dir", str(self.remote), "for-each-ref",
                         "--format=%(refname:strip=2)", "refs/heads/agent/").split())

    def notes(self):
        f = self.t / "fake" / "notify"
        return [l for l in f.read_text().splitlines() if l] if f.exists() else []

    def prs_of(self, head):
        return [l.split()[1:] for l in (self.t / "fake" / "prs").read_text().splitlines()
                if l.split()[0] == head]

    def bodies(self):
        f = self.t / "fake" / "bodies"
        return f.read_text() if f.exists() else ""

    def done(self, name):
        f = self.t / "state" / name.removeprefix("agent/")
        return f.read_text().strip() if f.exists() else None

    def merged_with_late(self):
        """loop-x: PR #1 merged at its first commit; one more commit pushed after."""
        self.commit("loop-x", "a.txt")
        self.merge_into_main("loop-x")
        self.pr(X, 1, "MERGED")
        late = self.commit("loop-x", "late.txt")
        self.to_local("loop-x")
        return late

    def close(self):
        shutil.rmtree(self.t, ignore_errors=True)


def s_merged_then_late(b):
    late = b.merged_with_late()
    b.run()
    assert b.remote_ref(f"{X}-late") == late, b.log
    assert b.remote_ref(X) == "", "the merged branch itself must not be pushed again"
    assert b.prs_of(f"{X}-late") == [["2", "OPEN"]], b.prs_of(f"{X}-late")
    assert "Commits pushed to agent/loop-x after #1 merged." in b.bodies()
    assert b.notes() == [], b.notes()
    assert b.local_ref(f"{X}-late") == late, "the loop needs the follow-up branch locally"
    assert b.done(X) == late and b.done(f"{X}-late") == late


def s_merged_nothing_new(b):
    b.commit("loop-x", "a.txt")
    b.merge_into_main("loop-x")
    b.pr(X, 1, "MERGED")
    b.to_local("loop-x")
    b.run()
    assert b.remote_branches() == [] and b.notes() == [], (b.remote_branches(), b.notes())
    assert b.done(X)


def s_closed_stays_closed(b):
    tip = b.commit("loop-x", "a.txt")
    b.pr(X, 1, "CLOSED")
    b.to_local("loop-x")
    b.run()
    assert b.remote_branches() == []
    assert len(b.notes()) == 1 and "closed" in b.notes()[0]
    assert b.done(X) == tip


def s_late_pr_open_fast_forwards(b):
    b.merged_with_late()
    b.run()
    more = b.commit("loop-x", "more.txt")
    b.to_local("loop-x")
    b.run()
    assert b.remote_ref(f"{X}-late") == more, b.log
    assert b.remote_branches() == [f"{X}-late"]
    assert b.prs_of(f"{X}-late") == [["2", "OPEN"]], "no second PR"
    assert b.notes() == []


def s_late_pr_merged_goes_to_late2(b):
    b.merged_with_late()
    b.run()
    b.merge_into_main("loop-x")
    b.set_pr(f"{X}-late", "MERGED")
    more = b.commit("loop-x", "more.txt")
    b.to_local("loop-x")
    b.run()
    assert b.remote_ref(f"{X}-late2") == more, b.log
    assert b.prs_of(f"{X}-late2") == [["3", "OPEN"]]
    assert b.notes() == []


def s_late_pr_closed_stops(b):
    b.merged_with_late()
    b.run()
    b.set_pr(f"{X}-late", "CLOSED")
    more = b.commit("loop-x", "more.txt")
    b.to_local("loop-x")
    before = b.remote_ref(f"{X}-late")
    b.run()
    assert b.remote_ref(f"{X}-late") == before and b.remote_ref(f"{X}-late2") == "", b.log
    assert len(b.notes()) == 1 and "closed" in b.notes()[0]
    assert b.done(X) == more


def s_protected_path_goes_to_outbox(b):
    b.commit("loop-x", "a.txt")
    b.merge_into_main("loop-x")
    b.pr(X, 1, "MERGED")
    b.commit("loop-x", ".github/workflows/x.yml")
    b.to_local("loop-x")
    b.run()
    assert b.remote_branches() == [], b.log
    assert len(list((b.t / "outbox").glob("*.patch"))) == 1
    assert any("protected" in n for n in b.notes())


def s_a_runner_label_edit_goes_to_outbox(b):
    """A pull request run uses the workflow from the PR head, so a branch that points a job at
    another runner label must never reach GitHub."""
    wf = b.seed / ".github" / "workflows" / "deploy.yml"
    b.g("checkout", "-q", "main")
    wf.parent.mkdir(parents=True, exist_ok=True)
    wf.write_text("jobs:\n  test:\n    runs-on: [self-hosted, runner-a]\n")
    b.g("add", "-A")
    b.g("commit", "-q", "-m", "workflow")
    b.g("push", "-q", str(b.remote), "main:refs/heads/main")
    b.g("push", "-q", str(b.local), "main:refs/heads/main")
    b.g("checkout", "-q", "-b", "loop-relabel", "main")
    wf.write_text("jobs:\n  test:\n    runs-on: [self-hosted, runner-b]\n")
    (b.seed / "src.txt").write_text("an ordinary change alongside\n")
    b.g("add", "-A")
    b.g("commit", "-q", "-m", "relabel")
    b.to_local("loop-relabel")
    b.run()
    assert b.remote_branches() == [], b.log
    assert b.prs_of("agent/loop-relabel") == []
    assert len(list((b.t / "outbox").glob("*.patch"))) == 1
    assert any("protected" in n for n in b.notes()), b.notes()


SERVER_ERROR = """remote: Internal Server Error
remote: Request ID 0000:00000:0000000:0000000:00000000
remote: Time 2026-01-01T00:00:00Z
To github.com:o/r.git
 ! [remote rejected] refs/courier/agent/loop-x -> agent/loop-x (Internal Server Error)
error: failed to push some refs to 'github.com:o/r.git'
"""
RULE_REJECTION = """remote: error: GH013: Repository rule violations found for refs/heads/agent/loop-x.
To github.com:o/r.git
 ! [remote rejected] refs/courier/agent/loop-x -> agent/loop-x (push declined due to repository rule violations)
error: failed to push some refs to 'github.com:o/r.git'
"""


def s_a_github_server_error_is_retried_not_refused(b):
    tip = b.commit("loop-x", "a.txt")
    b.to_local("loop-x")
    (b.t / "fake" / "push_error").write_text(SERVER_ERROR)
    b.run()
    assert b.remote_branches() == [] and b.notes() == [], (b.notes(), b.log)
    assert b.done(X) is None, "marked handled, so it would never be forwarded"
    (b.t / "fake" / "push_error").unlink()
    b.run()
    assert b.remote_ref(X) == tip and b.prs_of(X) == [["1", "OPEN"]], b.log


def s_a_genuine_rejection_is_final(b):
    tip = b.commit("loop-x", "a.txt")
    b.to_local("loop-x")
    (b.t / "fake" / "push_error").write_text(RULE_REJECTION)
    b.run()
    assert len(b.notes()) == 1 and "rule violations" in b.notes()[0], b.notes()
    assert b.done(X) == tip
    (b.t / "fake" / "push_error").unlink()
    b.run()
    assert b.remote_branches() == [] and len(b.notes()) == 1, "alerted once and not retried"


def s_secret_is_refused(b):
    b.merged_with_late()
    (b.t / "fake" / "leak").write_text("1")
    b.run()
    assert b.remote_branches() == [], b.log
    assert any("gitleaks" in n for n in b.notes())


def s_held_behind_another_loop_pr(b):
    late = b.merged_with_late()
    b.pr("agent/loop-other", 7, "OPEN")
    b.run()
    assert b.remote_branches() == [], "a new follow-up loop branch must wait its turn"
    assert b.done(X) is None and b.notes() == []
    b.set_pr("agent/loop-other", "MERGED")
    b.run()
    assert b.remote_ref(f"{X}-late") == late, b.log


def s_listing_failure_is_retried(b):
    late = b.merged_with_late()
    (b.t / "fake" / "fail_head").write_text(f"{X}-late\n")
    b.run()
    assert b.remote_branches() == [] and b.done(X) is None and b.notes() == [], (b.log, b.notes())
    (b.t / "fake" / "fail_head").unlink()
    b.run()
    assert b.remote_ref(f"{X}-late") == late


def s_diverged_local_target_is_final(b):
    late = b.merged_with_late()
    b.commit("mine", "mine.txt")
    b.to_local("mine", as_name=f"{X}-late")
    mine = b.local_ref(f"{X}-late")
    b.run()
    assert b.remote_ref(f"{X}-late") == late, b.log
    assert b.local_ref(f"{X}-late") == mine, "the agent's own local branch is not overwritten"
    assert any("local repo holds a different" in n for n in b.notes()), b.notes()
    assert b.done(X) == late
    n = len(b.notes())
    b.run()
    assert len([x for x in b.notes() if "local repo holds a different" in x]) == 1, "alerted once"
    assert n >= 1


def s_late_of_a_late_branch_keeps_the_root(b):
    b.merged_with_late()
    b.run()
    b.merge_into_main("loop-x")
    b.set_pr(f"{X}-late", "MERGED")
    b.g("checkout", "-q", "-b", "onlate", "loop-x")
    more = b.commit("onlate", "fix.txt")
    b.to_local("onlate", as_name=f"{X}-late")
    b.run()
    assert b.remote_ref(f"{X}-late2") == more, (b.remote_branches(), b.log)
    assert f"{X}-late-late" not in b.remote_branches()


def s_ordinary_branches_unchanged(b):
    new = b.commit("loop-new", "n.txt")
    b.to_local("loop-new")
    b.run()
    assert b.remote_ref("agent/loop-new") == new and b.prs_of("agent/loop-new") == [["1", "OPEN"]]
    upd = b.commit("loop-new", "n2.txt")
    b.to_local("loop-new")
    b.run()
    assert b.remote_ref("agent/loop-new") == upd and b.prs_of("agent/loop-new") == [["1", "OPEN"]]
    assert b.notes() == []


SCENARIOS = {k[2:]: v for k, v in globals().items() if k.startswith("s_")}

if __name__ == "__main__":
    args = sys.argv[1:]
    courier = args.pop(0) if args and args[0] not in SCENARIOS else str(HERE.parent / "courier.sh")
    names = args or list(SCENARIOS)
    failed = 0
    for name in names:
        box = Box(courier)
        try:
            SCENARIOS[name](box)
            print("PASS", name)
        except AssertionError as e:
            failed += 1
            print("FAIL", name, "|", str(e).replace("\n", " ")[:260])
        except Exception as e:  # noqa: BLE001
            failed += 1
            print("ERROR", name, "|", type(e).__name__, str(e)[:260])
        finally:
            box.close()
    sys.exit(1 if failed else 0)
