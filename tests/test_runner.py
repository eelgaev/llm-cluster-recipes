"""Offline behavioral checks; every cluster/network command is replaced by a stub."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
YQ = shutil.which("yq")
RECIPE_URL = "https://bfb.okoyl.xyz/llms/qwen3.8-27B"
REGISTER_URL = "https://rhllm.okoyl.xyz/register"

STUB = r'''
import json, os, pathlib, shutil, signal, subprocess, sys, time
root = pathlib.Path(os.environ["TEST_ROOT"])
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
command = [a for a in args if not a.startswith("--request-timeout=")]
record = {"tool": tool, "args": args, "command": command, "cwd": os.getcwd(),
          "kubeconfig": os.environ.get("KUBECONFIG")}
if tool == "oc" and args[0] == "apply":
    record["manifest"] = sys.stdin.read() if args[-1] == "-" else pathlib.Path(args[-1]).read_text()
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps(record) + "\n")
if tool == "git":
    shutil.copytree(os.environ["TEST_MANIFESTS"], pathlib.Path(args[-1]) / "manifests")
    shutil.copytree(os.environ["TEST_RUNTIME"], pathlib.Path(args[-1]) / "container")
elif tool == "sleep":
    time.sleep(0.02)
elif tool == "date":
    clock = root / "clock"
    now = int(clock.read_text()) + 1 if clock.exists() else 0
    clock.write_text(str(now))
    print(now)
elif tool == "curl":
    shutil.copyfile(os.environ["TEST_RECIPE"], args[args.index("-o") + 1])
elif tool == "wget":
    output = pathlib.Path(args[args.index("-O") + 1])
    if os.environ.get("TEST_DOWNLOAD_FAIL") == "true":
        output.write_text("partial")
        sys.exit(8)
    if output.exists():
        assert output.read_text() == "partial"
    output.write_text("complete")
elif tool == "oc":
    scenario = os.environ.get("TEST_SCENARIO", "render")
    if scenario.startswith("deploy"):
        args = command
        state_file = root / "cluster.json"
        state = json.loads(state_file.read_text()) if state_file.exists() else {}
        def save():
            state_file.write_text(json.dumps(state))
        def decode(text):
            output = subprocess.check_output([os.environ["TEST_YQ"], "-o=json", "-I=0", "."], input=text, text=True)
            return [json.loads(line) for line in output.splitlines() if line != "null"]
        if args[0] == "apply":
            for doc in decode(record["manifest"]):
                state[doc["kind"] + "/" + doc["metadata"]["name"]] = doc
            save()
        elif args[0] == "patch":
            patch = json.loads(args[args.index("-p") + 1])
            if args[1].startswith("daemonset"):
                operand = state.get("operand", {"spec":{"template":{"spec":{
                    "containers":[{"name":"device-plugin", "image":"test.invalid/device-plugin:v1"}]
                }}}})
                for operation in patch:
                    assert operation["op"] == "add"
                    path = operation["path"].strip("/").split("/")
                    target = operand
                    for segment in path[:-1]:
                        target = target[int(segment)] if isinstance(target, list) else target[segment]
                    target[path[-1]] = operation["value"]
                state["operand"] = operand
            save()
        elif args[0] == "whoami":
            print(os.environ.get("TEST_API_URL", "https://api.test.invalid:6443") if "--show-server" in args else "test-admin")
        elif args[:2] == ["get", "packagemanifest"]:
            print("stable")
        elif args[:2] == ["get", "crd"]:
            if os.environ.get("TEST_NFD_ERROR") == "crd":
                raise SystemExit("API unavailable")
            if os.environ.get("TEST_EXISTING_NFD") == "true" or os.environ.get("TEST_NFD_ERROR") == "instance":
                print("customresourcedefinition.apiextensions.k8s.io/nodefeaturediscoveries.nfd.openshift.io")
        elif args[:2] == ["get", "nodefeaturediscovery"]:
            if os.environ.get("TEST_NFD_ERROR") == "instance":
                raise SystemExit("API unavailable")
            if (os.environ.get("TEST_EXISTING_NFD") == "true" or
                (os.environ.get("TEST_NFD_DURING_INSTALL") == "true" and "Subscription/nfd" in state)):
                print("nodefeaturediscovery.nfd.openshift.io/nfd")
        elif args[:2] == ["get", "subscriptions"]:
            names = (["gpu-subscription"] if os.environ.get("TEST_EXISTING_GPU") == "true" else [])
            if os.environ.get("TEST_DUPLICATE_GPU") == "true":
                names = ["gpu-subscription", "gpu-operator-certified"]
            print(json.dumps({"items":[{"metadata":{"name":name,"namespace":"nvidia-gpu-operator"},
                "spec":{"name":"gpu-operator-certified"}} for name in names]}))
        elif args[:2] == ["get", "operatorgroups"]:
            names = (["existing-gpu-operator-group"] if os.environ.get("TEST_EXISTING_GPU") == "true"
                     or os.environ.get("TEST_EXISTING_GPU_OG") == "true" else [])
            if os.environ.get("TEST_DUPLICATE_GPU_OG") == "true":
                names = ["existing-gpu-operator-group", "nvidia-gpu-operator-group"]
            print(json.dumps({"items":[{"metadata":{"name":name,"namespace":"nvidia-gpu-operator"}}
                for name in names]}))
        elif args[:2] == ["get", "subscription"]:
            if os.environ.get("TEST_CSV_STUCK") == "true" and args[2] == "gpu-operator-certified":
                if "currentCSV" in args[-1]:
                    print("UpgradePending currentCSV=gpu-operator-certified.v1 installedCSV= installPlan=ip-test conditions=InstallPlanPending=True:Installing")
            elif args[-1] == "name":
                if os.environ.get("TEST_NFD_ERROR") == "subscription":
                    raise SystemExit("API unavailable")
                if "Subscription/nfd" in state:
                    print("subscription.operators.coreos.com/nfd")
            elif "-o" in args:
                print(args[2] + ".v1")
            elif args[2] == "nfd" and "Subscription/nfd" not in state:
                sys.exit(1)
        elif args[:2] == ["get", "csv"]:
            if "alm-examples" in args[-1]:
                print(json.dumps([{"apiVersion":"nvidia.com/v1", "kind":"ClusterPolicy",
                                   "metadata":{"name":"operator-example"}, "spec":{}}]))
            elif os.environ.get("TEST_CSV_FAILED") == "true" and args[2].startswith("gpu-operator-certified"):
                print("Failed")
            else:
                print("Succeeded")
        elif args[:2] == ["get", "clusterpolicy"]:
            name = os.environ.get("TEST_POLICY_NAME", "gpu-cluster-policy")
            if args[2] == "-o":
                print(name if os.environ.get("TEST_POLICY_NAME") or "ClusterPolicy/" + name in state else "")
            else:
                print(json.dumps({"metadata":{"name":name}, "spec":{"driver":{"enabled":False}}}))
        elif args[:2] == ["adm", "release"]:
            print("test.invalid/cli:latest")
        elif args[:2] == ["get", "daemonsets"]:
            print("daemonset.apps/nvidia-device-plugin-daemonset")
        elif args[:2] == ["get", "daemonset.apps/nvidia-device-plugin-daemonset"]:
            operand = state.get("operand", {"spec":{"template":{"spec":{
                "containers":[{"name":"device-plugin", "image":"test.invalid/device-plugin:v1"}]
            }}}})
            print(json.dumps(operand))
        elif args[:2] == ["get", "nodes"]:
            if "json" in args:
                print(json.dumps({"items":[{"metadata":{"name":"gpu-"+str(i)},
                    "status":{"nodeInfo":{"architecture":"amd64"}, "capacity":{"nvidia.com/gpu":"1"}}} for i in (1,2)]}))
            elif "name" in args:
                print("node/gpu-1\nnode/gpu-2")
            else:
                print("192.0.2.1\n192.0.2.2")
        elif args[:2] == ["get", "daemonset"]:
            state["reads"] = state.get("reads", 0) + 1
            save()
            template = state["ConfigMap/llm-recipe-reconciler-x86"]["data"]["daemonset.yaml"].replace("__GPU_COUNT__", "1")
            ds = decode(template)[0]
            ds["metadata"]["generation"] = 2
            ds["status"] = {"observedGeneration":2, "desiredNumberScheduled":2,
                "updatedNumberScheduled":2, "numberReady":2, "numberAvailable":2}
            if state["reads"] == 1:
                ds["spec"]["template"]["metadata"]["annotations"]["llm-recipes.openai.com/template-checksum"] = "previous-recipe"
            elif state["reads"] == 2 or scenario == "deploy-timeout":
                ds["status"]["numberReady"] = 1
                ds["status"]["numberAvailable"] = 1
            print(json.dumps(ds))
        elif args[0] == "get" and args[1] in ("ds", "deployment"):
            if os.environ.get("TEST_STALE_ARM") == "true":
                print("llm-recipe-arm" if args[1] == "ds" else "llm-recipe-reconciler-arm")
        elif args[:2] == ["get", "subscription,csv,installplan,pods"]:
            print("Subscription/gpu-operator-certified UpgradePending")
        elif args[:2] == ["describe", "subscription"]:
            print("Conditions: InstallPlanPending")
        elif args[:2] == ["describe", "csv"]:
            print("TooManyOperatorGroups")
        elif args[0] == "get" and args[1] in ("pods", "events", "deployments,daemonsets,pods"):
            print("gpu-2 Pending / registration not ready")
        elif args[0] == "logs":
            print("registration POST failed (HTTP 503); retrying")
        elif args[0] != "delete":
            raise SystemExit("Unexpected live oc call: " + repr(args))
        sys.exit(0)
    if "--watch-only" in args:
        if scenario == "node-event" and not (root / "event-sent").exists():
            (root / "event-sent").touch()
            print("node/gpu-worker", flush=True)
            # Keep the stream open: the reconciler must cancel after ONE event.
            signal.pause()
        print("Forbidden: cannot watch nodes", file=sys.stderr)
        sys.exit(1)
    elif args[0] == "whoami":
        print("https://api.test.invalid:6443" if "--show-server" in args else "test-admin")
    elif args[:2] == ["get", "packagemanifest"]:
        print("stable")
    elif args[:2] == ["get", "nodes"]:
        if scenario == "list-error":
            print("Cannot reach API", file=sys.stderr)
            sys.exit(1)
        print("4\n8" if (root / "event-sent").exists() else os.environ.get("TEST_CAPACITIES", "8\n<no value>"))
    elif args[0] not in ("apply", "delete"):
        raise SystemExit("Unexpected oc call: " + repr(args))
else:
    raise SystemExit("Unexpected command: " + tool)
'''


@unittest.skipUnless(YQ, "mikefarah yq v4 is required")
class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="llm-recipes-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.previews = []
        self.bin = self.path / "bin"
        self.bin.mkdir()
        for tool in ("oc", "git", "curl", "wget"):
            executable = self.bin / tool
            executable.write_text(f"#!{sys.executable}\n" + STUB)
            executable.chmod(0o755)
        self.env = dict(os.environ)
        for key in ("REPO_URL", "REPO_REF", "NS", "CSV_TIMEOUT", "RECONCILE_RESYNC",
                    "DRY_RUN", "MODEL_CACHE_ROOT", "BASH_ENV", "WAIT_FOR_READY", "DEPLOY_TIMEOUT",
                    "LLAMA_CPP_X86_IMAGE", "LLAMA_CPP_ARM_IMAGE"):
            self.env.pop(key, None)
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}", DRY_RUN="true",
                        TEST_ROOT=str(self.path), TEST_MANIFESTS=str(ROOT / "manifests"),
                        TEST_RUNTIME=str(ROOT / "container"), TEST_YQ=YQ,
                        TEST_RECIPE=str(ROOT / "recipes/qwen3.8-27B/recipe.yaml"))

    def calls(self, tool=None):
        log = self.path / "calls.jsonl"
        records = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return [r for r in records if tool is None or r["tool"] == tool]

    def run_script(self, path=None, env=None, extra_args=()):
        environment = env or self.env
        result = subprocess.run(["bash", str(path or ROOT / "run-recipe.sh"), RECIPE_URL,
                                 "--register-url", REGISTER_URL, *extra_args], cwd=self.path,
                                env=environment, text=True, capture_output=True, timeout=15)
        if environment.get("DRY_RUN") == "true" and result.returncode == 0:
            self.previews.extend(self.yaml_documents(result.stdout))
        return result

    def yaml_documents(self, text):
        result = subprocess.run([YQ, "-o=json", "-I=0", "."], input=text,
                                text=True, capture_output=True, check=True)
        return [json.loads(line) for line in result.stdout.splitlines() if line != "null"]

    def resources(self):
        return self.previews + [doc for call in self.calls("oc") if "manifest" in call
                for doc in self.yaml_documents(call["manifest"])]

    def test_local_render_grants_scc_and_watch_in_custom_namespace(self):
        self.env["NS"] = "inference-test"
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("git"), [])
        docs = self.resources()
        scc = next(d for d in docs if d["kind"] == "SecurityContextConstraints")
        binding = next(d for d in docs if d["kind"] == "RoleBinding"
                       and d["metadata"]["name"] == "llm-recipe-use-host-cache")
        # roleRef is immutable: preserve the existing binding on upgrades.
        self.assertEqual(binding["roleRef"], {
            "apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole",
            "name": "system:openshift:scc:llm-recipe-host-cache-inference-test"})
        role = next(d for d in docs if d["kind"] == binding["roleRef"]["kind"]
                    and d["metadata"]["name"] == binding["roleRef"]["name"])
        self.assertEqual(role["rules"][0]["resourceNames"], [scc["metadata"]["name"]])
        self.assertEqual(role["rules"][0]["verbs"], ["use"])
        self.assertEqual(binding["subjects"][0]["namespace"], "inference-test")
        node_role = next(d for d in docs if d["kind"] == "ClusterRole"
                         and "nodes" in d["rules"][0]["resources"])
        self.assertIn("watch", node_role["rules"][0]["verbs"])
        for doc in docs:
            if doc["kind"] in ("Role", "RoleBinding", "ServiceAccount", "ConfigMap", "Deployment"):
                self.assertEqual(doc["metadata"]["namespace"], "inference-test")
            elif doc["kind"] == "NodeFeatureRule":
                self.assertEqual(doc["metadata"]["namespace"], "openshift-nfd")
            elif doc["kind"] in ("Subscription", "OperatorGroup"):
                expected_ns = "openshift-nfd" if doc["metadata"]["name"].startswith("nfd") else "nvidia-gpu-operator"
                self.assertEqual(doc["metadata"]["namespace"], expected_ns)
        deployment = next(d for d in docs if d["kind"] == "Deployment")
        annotations = deployment["spec"]["template"]["metadata"]["annotations"]
        self.assertRegex(annotations["llm-recipes.openai.com/code-checksum"], r"^\d+-\d+$")
        self.assertTrue(any(d["kind"] == "NodeFeatureDiscovery" for d in docs))
        # Preview must work before operator CRDs exist: no API schema discovery
        # through oc apply, even with --dry-run=client.
        self.assertFalse(any(c["args"][0] in ("apply", "patch", "delete") for c in self.calls("oc")))

    def test_dpf_command_preserves_relative_kubeconfig_through_symlink(self):
        (self.path / "run-recipe.sh").symlink_to(ROOT / "run-recipe.sh")
        (self.path / "kubeconfig").write_text("test kubeconfig")
        self.env.update(KUBECONFIG="./kubeconfig", CUSTOM_POSTINSTALL_SCRIPT=(
            f"./run-recipe.sh {RECIPE_URL} --register-url {REGISTER_URL}"))
        # Same argv splitting and direct execution as DPF's custom-postinstall-script.sh.
        result = subprocess.run(["bash", "-c", 'read -r -a parts <<< "$CUSTOM_POSTINSTALL_SCRIPT"; "${parts[@]}"'],
                                cwd=self.path, env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("git"), [])
        for call in self.calls("oc"):
            self.assertEqual(Path(call["cwd"]).resolve(), self.path.resolve())
            self.assertEqual(call["kubeconfig"], "./kubeconfig")
        template = next(d["data"]["daemonset.yaml"] for d in self.yaml_documents(result.stdout)
                        if d["kind"] == "ConfigMap" and "daemonset.yaml" in d.get("data", {}))
        ds = self.yaml_documents(template)[0]
        variables = ds["spec"]["template"]["spec"]["containers"][0]["env"]
        values = {e["name"]: e.get("value") for e in variables}
        self.assertEqual(values["RECIPE_BASE_URL"], RECIPE_URL)
        self.assertEqual(values["REGISTER_URL"], REGISTER_URL)

    def test_standalone_and_streamed_runners_clone_manifests(self):
        standalone = self.path / "run-recipe.sh"
        shutil.copyfile(ROOT / "run-recipe.sh", standalone)
        # A copy in openshift-dpf's root must not pick up DPF's manifests/.
        (self.path / "manifests").mkdir()
        (self.path / "manifests" / "parent-only.yaml").write_text("kind: ConfigMap\n")
        result = self.run_script(standalone)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(["bash", "-s", "--", RECIPE_URL, "--register-url", REGISTER_URL],
                                input=standalone.read_text(), cwd=self.path, env=self.env,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("git")), 2)

    def test_explicit_ref_clones_and_code_changes_roll_reconciler(self):
        manifests = self.path / "manifests"
        shutil.copytree(ROOT / "manifests", manifests)
        self.env.update(REPO_REF="test-ref", TEST_MANIFESTS=str(manifests))
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        code = manifests / "reconciler-code.yaml"
        code.write_text(code.read_text() + "    # changed controller\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        checksums = [d["spec"]["template"]["metadata"]["annotations"]["llm-recipes.openai.com/code-checksum"]
                     for d in self.resources() if d["kind"] == "Deployment"]
        self.assertNotEqual(checksums[0], checksums[1])
        for call in self.calls("git"):
            self.assertEqual(call["args"][call["args"].index("--branch") + 1], "test-ref")

    def test_uninstall_dry_run_never_deletes(self):
        result = subprocess.run(["bash", str(ROOT / "run-recipe.sh"), "uninstall"],
                                cwd=self.path, env=self.env, text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no resources deleted", result.stderr)
        self.assertFalse(any(c["args"][0] == "delete" for c in self.calls("oc")))

    def test_uninstall_removes_both_roles_for_selected_namespace(self):
        self.env.update(DRY_RUN="false", NS="inference-test")
        result = subprocess.run(["bash", str(ROOT / "run-recipe.sh"), "uninstall"],
                                cwd=self.path, env=self.env, text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        deleted = [c["args"][1:3] for c in self.calls("oc") if c["args"][0] == "delete"]
        self.assertIn(["clusterrole", "system:openshift:scc:llm-recipe-host-cache-inference-test"], deleted)
        self.assertIn(["clusterrole", "llm-recipe-node-reader-inference-test"], deleted)
        self.assertIn(["namespace", "inference-test"], deleted)

    def test_interrupted_download_resumes_partial_file(self):
        download = self.path / "download.sh"
        shutil.copyfile(ROOT / "recipes/qwen3.8-27B/download.sh", download)
        self.env.update(HF_TOKEN="dummy-test-token", TEST_DOWNLOAD_FAIL="true")
        failed = subprocess.run(["bash", str(download)], env=self.env, text=True, capture_output=True, timeout=5)
        self.assertNotEqual(failed.returncode, 0)
        model = self.path / "Qwen3.8-27B-UD-Q4_K_XL.gguf"
        self.assertFalse(model.exists())
        self.assertTrue(Path(str(model) + ".part").exists())
        self.env["TEST_DOWNLOAD_FAIL"] = "false"
        resumed = subprocess.run(["bash", str(download)], env=self.env, text=True, capture_output=True, timeout=5)
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertEqual(model.read_text(), "complete")
        self.assertFalse(Path(str(model) + ".part").exists())

    def live_environment(self, scenario="deploy-success"):
        self.env.update(DRY_RUN="false", TEST_SCENARIO=scenario, DEPLOY_TIMEOUT="20")
        for tool in ("date", "sleep"):
            executable = self.bin / tool
            executable.write_text(f"#!{sys.executable}\n" + STUB)
            executable.chmod(0o755)

    def test_full_install_bootstraps_nfd_and_waits_for_current_recipe_on_all_nodes(self):
        self.live_environment()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        docs = self.resources()
        self.assertTrue(any(d["kind"] == "NodeFeatureDiscovery" for d in docs))
        policy = next(d for d in docs if d["kind"] == "ClusterPolicy")
        self.assertEqual(policy["metadata"]["name"], "gpu-cluster-policy")
        state = json.loads((self.path / "cluster.json").read_text())
        self.assertEqual(state["reads"], 3, "Must reject old templates and partial readiness")
        self.assertIn("healthy and registered on every detected GPU node", result.stdout)
        self.assertNotIn("Unexpected", result.stderr)
        runtime = next(d for d in docs if d["metadata"]["name"] == "llm-recipe-runtime")
        self.assertIn("/certs/registered", runtime["data"]["healthcheck.sh"])
        template = state["ConfigMap/llm-recipe-reconciler-x86"]["data"]["daemonset.yaml"]
        pod = self.yaml_documents(template)[0]["spec"]["template"]["spec"]
        self.assertEqual(pod["containers"][0]["command"], ["/bin/bash", "/runtime/entrypoint.sh"])
        self.assertIn("ready", pod["containers"][0]["readinessProbe"]["exec"]["command"])
        self.assertIn("chcon", pod["initContainers"][0]["command"][-1])
        self.assertFalse(pod["automountServiceAccountToken"])
        operand = state["operand"]["spec"]["template"]["spec"]
        self.assertNotIn("initContainers", operand)
        self.assertEqual(operand["containers"][0]["image"], "test.invalid/device-plugin:v1")
        self.assertTrue(operand["hostNetwork"])
        self.assertEqual(operand["dnsPolicy"], "Default")
        self.assertTrue(any(c["command"][:2] == ["patch", "daemonset.apps/nvidia-device-plugin-daemonset"]
                            and "--type=json" in c["command"] for c in self.calls("oc")))

    def test_csv_wait_reports_olm_progress_and_timeout_diagnostics(self):
        self.live_environment()
        self.env.update(TEST_EXISTING_NFD="true", TEST_CSV_STUCK="true", CSV_TIMEOUT="2")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gpu-operator-certified OLM status: UpgradePending", result.stdout)
        self.assertIn("Subscription/gpu-operator-certified UpgradePending", result.stderr)
        self.assertIn("Conditions: InstallPlanPending", result.stderr)
        self.assertIn("timed out waiting for gpu-operator-certified CSV Succeeded", result.stderr)
        csv_reads = [call for call in self.calls("oc") if call["command"][:2] == ["get", "subscription"]
                     and call["command"][2] == "gpu-operator-certified"]
        self.assertTrue(all("--request-timeout=30s" in call["args"] or
                            "--request-timeout=15s" in call["args"] for call in csv_reads))

    def test_failed_csv_exits_without_waiting_for_timeout(self):
        self.live_environment()
        self.env.update(TEST_EXISTING_NFD="true", TEST_CSV_FAILED="true")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gpu-operator-certified CSV failed", result.stderr)
        self.assertIn("TooManyOperatorGroups", result.stderr)

    def test_existing_gpu_operator_subscription_and_group_are_preserved(self):
        self.live_environment()
        self.env.update(TEST_EXISTING_NFD="true", TEST_EXISTING_GPU="true")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Reusing existing GPU Operator subscription gpu-subscription", result.stdout)
        self.assertFalse(any(doc["kind"] in ("Subscription", "OperatorGroup") and
                             doc["metadata"]["namespace"] == "nvidia-gpu-operator"
                             for doc in self.resources()))
        calls = [call["command"] for call in self.calls("oc")]
        self.assertTrue(any(call[:3] == ["get", "subscription", "gpu-subscription"] for call in calls))

    def test_duplicate_gpu_operator_resources_fail_before_gpu_mutations(self):
        self.live_environment()
        self.env.update(TEST_EXISTING_NFD="true", TEST_DUPLICATE_GPU="true")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("multiple GPU Operator subscriptions", result.stderr)
        self.assertFalse(any(doc["kind"] in ("Subscription", "OperatorGroup") and
                             doc["metadata"]["namespace"] == "nvidia-gpu-operator"
                             for doc in self.resources()))

    def test_rerun_preserves_nfd_policy_and_stops_obsolete_controller(self):
        self.live_environment()
        self.env.update(TEST_EXISTING_NFD="true", TEST_POLICY_NAME="custom-policy", TEST_STALE_ARM="true",
                        TEST_API_URL="https://[2001:db8::1]:6443")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(d["kind"] in ("NodeFeatureDiscovery", "ClusterPolicy") for d in self.resources()))
        calls = [c["command"] for c in self.calls("oc")]
        patch = next(c for c in calls if c[:2] == ["patch", "clusterpolicy"])
        self.assertEqual(patch[2], "custom-policy")
        envs = json.loads(patch[patch.index("-p") + 1])["spec"]["driver"]["manager"]["env"]
        self.assertIn({"name":"KUBERNETES_SERVICE_HOST", "value":"2001:db8::1"}, envs)
        deletes = [c for c in calls if c[0] == "delete"]
        self.assertEqual([c[1] for c in deletes], ["deployment", "configmap", "ds"])
        self.assertIn("--cascade=foreground", deletes[0])

    def test_nfd_api_errors_stop_before_cluster_mutations(self):
        self.live_environment()
        for resource in ("crd", "instance", "subscription"):
            with self.subTest(resource=resource):
                self.env["TEST_NFD_ERROR"] = resource
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("API unavailable", result.stderr)
                self.assertFalse(any(c["command"][0] in ("apply", "patch", "delete")
                                     for c in self.calls("oc")))

    def test_nfd_created_during_operator_startup_is_preserved(self):
        self.live_environment()
        self.env["TEST_NFD_DURING_INSTALL"] = "true"
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any(d["kind"] == "Subscription" and d["metadata"]["name"] == "nfd"
                            for d in self.resources()))
        self.assertFalse(any(d["kind"] == "NodeFeatureDiscovery" for d in self.resources()))

    def test_failed_deployment_returns_nonzero_with_diagnostics(self):
        self.live_environment("deploy-timeout")
        self.env["DEPLOY_TIMEOUT"] = "2"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not healthy and registered on every GPU node", result.stderr)
        self.assertIn("registration POST failed", result.stdout)
        self.assertNotIn("healthy and registered on every detected", result.stdout)

    def test_no_wait_is_explicit_and_does_not_report_readiness(self):
        self.live_environment()
        result = self.run_script(extra_args=("--no-wait",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("readiness and registration have not been verified", result.stdout)
        self.assertNotIn("reads", json.loads((self.path / "cluster.json").read_text()))

    def test_unknown_runtime_fails_before_cluster_mutations(self):
        recipe = self.path / "recipe.yaml"
        recipe.write_text((ROOT / "recipes/qwen3.8-27B/recipe.yaml").read_text().replace("type: llama-cpp", "type: unsupported"))
        self.env["TEST_RECIPE"] = str(recipe)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported recipe type", result.stderr)
        self.assertFalse(any(c["args"][0] in ("apply", "patch", "delete") for c in self.calls("oc")))

    def start_reconciler(self, scenario):
        script = subprocess.check_output([YQ, "-r", '.data."reconcile.sh"',
                                          str(ROOT / "manifests/reconciler-code.yaml")], text=True)
        template = self.path / "daemonset.yaml"
        shutil.copyfile(ROOT / "manifests/workload-daemonset.yaml", template)
        script = script.replace("/template/daemonset.yaml", str(template))
        executable = self.path / "reconcile.sh"
        executable.write_text(script)
        self.env.update(TEST_SCENARIO=scenario, K8S_ARCH="amd64", TARGET_NAMESPACE="llm-recipes",
                        DS_NAME="llm-recipe-x86", RECONCILE_RESYNC="300")
        output = (self.path / "controller.log").open("w")
        process = subprocess.Popen(["bash", str(executable)], env=self.env, cwd=self.path,
                                   stdout=output, stderr=output, start_new_session=True)

        def stop():
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            output.close()
        self.addCleanup(stop)
        return process

    def wait_until(self, predicate):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail("Controller did not reach expected state: " + (self.path / "controller.log").read_text())

    def test_ready_node_deploys_and_single_event_reconciles(self):
        self.start_reconciler("node-event")
        self.wait_until(lambda: len([c for c in self.calls("oc") if c["args"][0] == "apply"]) >= 2)
        applied = [self.yaml_documents(c["manifest"])[0] for c in self.calls("oc") if "manifest" in c]
        limits = [d["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]["nvidia.com/gpu"]
                  for d in applied]
        self.assertEqual(limits[:2], ["8", "4"])

    def test_no_capacity_waits_without_creating_workload(self):
        self.env["TEST_CAPACITIES"] = "0\n<no value>"
        self.start_reconciler("watch-error")
        self.wait_until(lambda: any("--watch-only" in c["args"] for c in self.calls("oc")))
        self.assertFalse(any(c["args"][0] == "apply" for c in self.calls("oc")))

    def test_watch_and_list_errors_back_off(self):
        for scenario in ("watch-error", "list-error"):
            with self.subTest(scenario=scenario):
                process = self.start_reconciler(scenario)
                if scenario == "watch-error":
                    self.wait_until(lambda: any("--watch-only" in c["args"] for c in self.calls("oc")))
                else:
                    self.wait_until(lambda: any(c["args"][:2] == ["get", "nodes"] for c in self.calls("oc")))
                time.sleep(0.25)
                lists = [c for c in self.calls("oc") if c["args"][:2] == ["get", "nodes"]]
                self.assertEqual(len(lists), 1)
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=3)
                (self.path / "calls.jsonl").unlink()


if __name__ == "__main__":
    unittest.main()
