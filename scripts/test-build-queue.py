#!/usr/bin/env python3
"""Exercise concurrency and recovery using disposable repositories only."""

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("build-queue.py")


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("remote", "add", "origin", "https://github.com/example/app.git")
        self.git("-c", "user.name=Queue Test", "-c", "user.email=queue@example.invalid",
                 "commit", "--allow-empty", "-qm", "fixture")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.call("configure", "--builder-thread", "builder")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True)

    def call(self, *args, actor="builder", cwd=None, ok=True):
        result = subprocess.run(["python3", str(SCRIPT), "--actor", actor, *args],
                                cwd=cwd or self.repo, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return json.loads(result.stdout if ok else result.stderr)

    def enqueue(self, pr=1, head=None, session="worker", cwd=None, ok=True):
        return self.call("enqueue", "--pr", f"https://github.com/example/app/pull/{pr}",
                         "--head", head or self.head, "--title", "Fixture change",
                         "--checks", "Isolated test checks", "--acceptance", "Fixture acceptance",
                         "--session", session, cwd=cwd, ok=ok)

    def update(self, ticket, status):
        return self.call("set", "--ticket", str(ticket), "--status", status,
                         "--note", "Test evidence")

    def test_fifo_and_pending_install_does_not_block_next_work(self):
        first = self.enqueue()["ticket"]["id"]
        second = self.enqueue(2)["ticket"]["id"]
        self.assertEqual(self.call("claim")["ticket"]["id"], first)
        self.assertFalse(self.call("claim")["claimed"])
        self.update(first, "pending_install")
        self.assertEqual(self.call("claim")["ticket"]["id"], second)
        self.assertEqual(self.call("status")["tickets"][0]["status"], "pending_install")

    def test_simultaneous_submissions_are_idempotent(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.enqueue(), range(16)))
        self.assertEqual(sum(r["created"] for r in results), 1)
        self.assertEqual(len({r["ticket"]["id"] for r in results}), 1)

    def test_simultaneous_claims_have_one_winner(self):
        for pr in range(1, 5):
            self.enqueue(pr)
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.call("claim"), range(8)))
        self.assertEqual(sum(r["claimed"] for r in results), 1)

    def test_worktrees_share_queue_and_installed_helper(self):
        worktree = Path(self.temp.name) / "worker"
        self.git("worktree", "add", "--detach", "-q", str(worktree), "HEAD")
        self.enqueue(cwd=worktree)
        self.assertEqual(len(self.call("status")["tickets"]), 1)
        installed = self.call("install")["helper"]
        result = subprocess.check_output(["python3", installed, "status"], cwd=worktree)
        self.assertEqual(len(json.loads(result)["tickets"]), 1)

    def test_only_builder_can_claim_update_or_ack(self):
        ticket = self.enqueue()["ticket"]["id"]
        for args in (("claim",), ("set", "--ticket", str(ticket), "--status", "cancelled",
                                  "--note", "test"), ("ack", "--event", "1")):
            self.call(*args, actor="worker", ok=False)
        self.assertEqual(self.call("claim")["ticket"]["id"], ticket)

    def test_crash_does_not_expire_claim_and_retry_goes_to_back(self):
        first = self.enqueue()["ticket"]["id"]
        second = self.enqueue(2)["ticket"]["id"]
        self.call("claim")
        # Every call is a separate exited process; no TTL can reclaim active work.
        self.assertFalse(self.call("claim")["claimed"])
        self.update(first, "blocked")
        self.update(first, "queued")
        self.assertEqual(self.call("claim")["ticket"]["id"], second)

    def test_new_commit_supersedes_queued_request_but_not_active_candidate(self):
        first = self.enqueue()["ticket"]["id"]
        self.git("-c", "user.name=Queue Test", "-c", "user.email=queue@example.invalid",
                 "commit", "--allow-empty", "-qm", "new reviewed fixture")
        new_head = self.git("rev-parse", "HEAD").strip()
        new = self.enqueue(head=new_head)["ticket"]["id"]
        self.assertNotEqual(new, first)
        self.assertEqual(self.call("status")["tickets"][0]["status"], "superseded")
        self.call("claim")
        self.git("-c", "user.name=Queue Test", "-c", "user.email=queue@example.invalid",
                 "commit", "--allow-empty", "-qm", "third fixture")
        self.enqueue(head=self.git("rev-parse", "HEAD").strip(), ok=False)
        self.assertEqual(self.call("status")["tickets"][1]["head"], new_head)

    def test_resubmission_cannot_redirect_callback(self):
        self.enqueue()
        self.enqueue(session="other-worker", ok=False)
        self.assertEqual(self.call("status")["tickets"][0]["session"], "worker")

    def test_repository_rename_cannot_create_duplicate_pr_requests(self):
        self.git("remote", "set-url", "origin", "git@github.com:AbsoluteMode/whytap.git")
        def submit(repository):
            return self.call("enqueue", "--pr", f"https://github.com/AbsoluteMode/{repository}/pull/1",
                             "--head", self.head, "--title", "Fixture", "--checks", "Fixture checks",
                             "--acceptance", "Fixture acceptance", "--session", "worker")
        first = submit("exodia")
        second = submit("whytap")
        self.assertEqual(first["ticket"]["id"], second["ticket"]["id"])
        self.assertFalse(second["created"])
        self.enqueue(ok=False)

    def test_worker_cannot_change_builder_callback_host(self):
        self.call("configure", "--builder-thread", "builder", "--host", "different",
                  actor="worker", ok=False)
        self.assertEqual(self.call("status")["builder"]["builder_host"], "local")

    def test_notification_outbox_survives_restart_and_ack(self):
        self.enqueue()
        self.call("claim")
        pending = self.call("events", "--pending")
        self.assertEqual([e["status"] for e in pending], ["queued", "in_progress"])
        self.call("ack", "--event", str(pending[0]["id"]))
        self.assertEqual(len(self.call("events", "--pending")), 1)
        self.assertEqual(len(self.call("events", "--ticket", "1")), 2)

    def test_terminal_ticket_cannot_be_requeued(self):
        self.enqueue()
        self.call("claim")
        self.update(1, "done")
        self.call("set", "--ticket", "1", "--status", "queued", "--note", "test", ok=False)
        self.assertIsNone(self.call("claim")["active"])


if __name__ == "__main__":
    unittest.main()
