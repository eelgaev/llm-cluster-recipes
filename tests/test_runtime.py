"""Exercise the real entrypoint and probes without GPUs or network access."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
KEY = "a" * 64
STUB = r'''
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ["TEST_ROOT"])
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if tool == "openssl":
    if args[0] == "rand":
        print("a" * 64)
    else:
        for option in ("-keyout", "-out"):
            pathlib.Path(args[args.index(option) + 1]).write_text("test certificate")
elif tool == "sleep":
    time.sleep(0.05)
elif tool == "curl":
    with (root / "curl.jsonl").open("a") as f:
        f.write(json.dumps(args) + "\n")
    if "POST" in args:
        status = (root / "registration-status").read_text()
        if status == "timeout":
            sys.exit(28)
        print(status, end="")
    else:
        if not (root / "healthy").exists():
            sys.exit(22)
        if "Authorization: Bearer " + "a" * 64 not in args:
            sys.exit(22)
'''


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="llm-runtime-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        for name in ("certs", "models", "recipe", "runtime", "bin"):
            (self.path / name).mkdir()
        self.env = dict(os.environ, TEST_ROOT=str(self.path),
                        PATH=f"{self.path / 'bin'}:{os.environ['PATH']}",
                        REGISTER_URL="https://register.test.invalid/register",
                        NODE_HOST_IP="192.0.2.1", NODE_NAME="gpu-1", PORT="52395")
        self.env.pop("API_KEY", None)
        self.env.pop("BASH_ENV", None)
        for tool in ("curl", "openssl", "sleep"):
            target = self.path / "bin" / tool
            target.write_text(f"#!{sys.executable}\n" + STUB)
            target.chmod(0o755)
        for name in ("entrypoint.sh", "healthcheck.sh"):
            source = (ROOT / "container" / name).read_text()
            for directory in ("certs", "models", "recipe", "runtime"):
                source = source.replace("/" + directory, str(self.path / directory))
            (self.path / "runtime" / name).write_text(source)
        (self.path / "recipe/script.sh").write_text(
            '#!/bin/bash\nwhile [ ! -f "$TEST_ROOT/stop" ]; do /bin/sleep 0.05; done\n')
        (self.path / "registration-status").write_text("503")

    def calls(self):
        log = self.path / "curl.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def start(self):
        output = (self.path / "runtime.log").open("w")
        process = subprocess.Popen(["bash", str(self.path / "runtime/entrypoint.sh")], env=self.env,
                                   stdout=output, stderr=output, start_new_session=True)
        def stop():
            (self.path / "stop").touch()
            process.wait(timeout=3)
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            output.close()
        self.addCleanup(stop)
        return process

    def wait_until(self, predicate):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail((self.path / "runtime.log").read_text())

    def probe(self, mode="ready"):
        return subprocess.run(["bash", str(self.path / "runtime/healthcheck.sh"), mode],
                              env=self.env, capture_output=True, timeout=3).returncode

    def test_readiness_requires_registration_and_current_health(self):
        # A container restart reuses emptyDir; old success must be invalidated.
        (self.path / "certs/registered").touch()
        (self.path / "healthy").touch()
        self.start()
        self.wait_until(lambda: any("POST" in args for args in self.calls()))
        self.assertFalse((self.path / "certs/registered").exists())
        self.assertEqual(self.probe("live"), 0)
        self.assertNotEqual(self.probe(), 0)
        for failure in ("302", "timeout"):
            (self.path / "registration-status").write_text(failure)
            time.sleep(0.12)
            self.assertFalse((self.path / "certs/registered").exists())
        (self.path / "registration-status").write_text("204")
        self.wait_until(lambda: (self.path / "certs/registered").exists())
        self.assertEqual(self.probe(), 0)
        (self.path / "healthy").unlink()
        self.assertNotEqual(self.probe(), 0)
        key_file = self.path / "certs/api-key"
        self.assertEqual(key_file.read_text(), KEY)
        self.assertEqual(key_file.stat().st_mode & 0o777, 0o600)
        posts = [args for args in self.calls() if "POST" in args]
        self.assertTrue(posts)
        for args in posts:
            self.assertIn("--max-time", args)
            self.assertNotIn("-k", args)
            self.assertNotIn("-L", args)
            payload = json.loads(args[args.index("-d") + 1])
            self.assertEqual(payload, {"host":"192.0.2.1", "port":52395, "api_key":KEY})

    def test_recipe_failure_is_container_failure(self):
        (self.path / "recipe/script.sh").write_text("exit 7\n")
        process = self.start()
        self.assertEqual(process.wait(timeout=3), 7)
        self.assertFalse((self.path / "certs/registered").exists())

    def test_missing_recipe_fails_before_starting_registration(self):
        (self.path / "recipe/script.sh").unlink()
        process = self.start()
        self.assertNotEqual(process.wait(timeout=3), 0)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
