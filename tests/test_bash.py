"""Offline Bash parity tests using fake Azure CLIs, HTTP, and delays."""
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts" / "bash"
ROLE = "b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b"


def local_path(value):
    if os.name == "nt" and value.startswith("/tmp/"):
        return Path(tempfile.gettempdir()) / value.removeprefix("/tmp/")
    if os.name == "nt" and re.match(r"^/[a-zA-Z]/", value):
        value = value[1] + ":" + value[2:]
    return Path(value)


def mock_command(tool, args):
    state_path = Path(os.environ["MOCK_STATE"])
    state = json.loads(state_path.read_text())
    state["calls"].append([tool, *args])
    scenario = state["scenario"]
    result = ""
    code = 0

    def option(name, default=""):
        return args[args.index(name) + 1] if name in args else default

    if tool == "readiness":
        code = 1 if scenario in ("startup_start_error", "readiness_failure") or (
            scenario == "workload_readiness_failure" and option("--stage") == "Workloads"
        ) else 0
        result = "Mocked shared readiness failure" if code else "Mocked shared readiness passed"
    elif tool == "azd":
        if args == ["env", "get-values"]:
            result = "\n".join(f'{key}="{value}"' for key, value in state["env"].items())
        elif args[:2] == ["env", "set"]:
            state["env"][args[2]] = args[3]
        elif args and args[0] == "provision":
            code = 1 if scenario == "startup_provision_error" else 0
        else:
            raise AssertionError(args)
    elif tool == "sleep":
        pass
    elif tool == "date":
        clock = dt.datetime.fromisoformat(state["clock"])
        if scenario != "recent_boundary":
            state["clock"] = (clock + dt.timedelta(minutes=3)).isoformat()
        result = clock.strftime("%Y-%m-%dT%H:%M:%SZ")
    elif tool == "az":
        if args[:2] == ["resource", "list"]:
            assert "--resource-type" not in args
            assert "type=='Microsoft.ContainerService/managedClusters'" in option("--query")
            code = 1 if scenario == "startup_discovery_error" else 0
            result = json.dumps([
                {"name": name, "resourceGroup": "rg-test",
                 "id": f"/subscriptions/test-sub/resourceGroups/rg-test/providers/Microsoft.ContainerService/managedClusters/{name}"}
                for name in state.get("cluster_states", {})
            ])
        elif args[:2] == ["aks", "show"]:
            if scenario == "startup_read_error":
                code = 1
            elif scenario == "startup_invalid_json":
                result = "invalid"
            else:
                name = option("--name")
                sequence = state["cluster_states"][name]
                stage = sequence[0]
                if len(sequence) > 1:
                    sequence.pop(0)
                provisioning, power = stage.split("/")
                result = json.dumps({"provisioningState": provisioning, "powerState": power})
        elif args[:2] == ["aks", "start"]:
            assert "--no-wait" in args
            code = 1 if scenario == "startup_start_error" else 0
        elif args[:3] == ["monitor", "metrics", "list"]:
            end = dt.datetime.fromisoformat(option("--end-time").replace("Z", "+00:00")).replace(second=0, microsecond=0)
            start = dt.datetime.fromisoformat(option("--start-time").replace("Z", "+00:00"))
            if (dt.datetime.fromisoformat(option("--end-time").replace("Z", "+00:00")) - start).total_seconds() < 60:
                state_path.write_text(json.dumps(state))
                print("BadRequest: metric query requires at least one minute", file=sys.stderr)
                return 1
            series = []
            for host in ("primary.regional.azure-api.net", "secondary.regional.azure-api.net"):
                series.append({
                    "metadatavalues": [
                        {"name": {"value": "Origin"}, "value": host + ":443"},
                        {"name": {"value": "OriginGroup"}, "value": state["env"].get("FRONT_DOOR_ORIGIN_GROUP", "regional-apis")},
                    ],
                    "data": [{"timeStamp": (end - dt.timedelta(minutes=i)).isoformat(), "minimum": 100} for i in (2, 1)],
                })
            if scenario == "missing_origin":
                series.pop()
            elif scenario == "unhealthy_origin" or (
                scenario == "unhealthy_recovery" and any(
                    "--command" in call and "--replicas=0" in call[call.index("--command") + 1]
                    for call in state["calls"]
                )
            ):
                series[-1]["data"][-1]["minimum"] = 0
            result = json.dumps({"value": [{"name": {"value": "OriginHealthPercentage"}, "timeseries": series}]})
        elif args[:2] == ["account", "show"]:
            result = json.dumps({"id": "test-sub", "state": "Enabled"})
        elif args[:3] == ["ad", "signed-in-user", "show"]:
            result = json.dumps({"id": "test-user", "userPrincipalName": "test@example.invalid"})
        elif args[:3] == ["role", "assignment", "list"]:
            if "--assignee" in args:
                result = json.dumps([{"roleDefinitionId": f"/roles/{ROLE}"}] if scenario == "existing" else [])
            else:
                scope = option("--scope")
                items = [item for item in state["assignments"] if item.startswith(scope + "/")]
                result = json.dumps([{"id": item} for item in items])
        elif args[:3] == ["role", "assignment", "create"]:
            scope = option("--scope")
            if scenario == "partial_grant" and scope.endswith("aks-secondary"):
                code = 1
            else:
                state["assignments"].append(f"{scope}/providers/Microsoft.Authorization/roleAssignments/{option('--name')}")
                result = "{}"
        elif args[:3] == ["role", "assignment", "delete"]:
            assignment = option("--ids")
            if scenario == "delete_failure" and "aks-primary/" in assignment:
                code = 1
            elif scenario != "delete_not_effective":
                state["assignments"] = [item for item in state["assignments"] if item != assignment]
        elif args[:2] == ["aks", "command"]:
            cluster = option("--name")
            if args[2] == "result":
                result = state["pending"]
            else:
                command = option("--command")
                for index, value in enumerate(args):
                    if value == "--file":
                        path = local_path(args[index + 1])
                        text = path.read_text()
                        state["attachments"].append(str(path))
                        if path.suffix == ".yaml":
                            assert "__REGION__" not in text and "__TLS_KEY__" not in text
                            assert re.search(r'checksum/lab-workload: "[a-f0-9]{64}"', text)
                            assert "loadBalancerSourceRanges:" in text
                        else:
                            assert "\r" not in text
                            assert "for i in" in text
                remote_code, logs = 0, "ready\n"
                if "auth can-i" in command:
                    state["probes"][cluster] = state["probes"].get(cluster, 0) + 1
                    if scenario == "denied":
                        remote_code, logs = 1, "Forbidden"
                    elif scenario == "auth_error":
                        remote_code, logs = 2, "Unexpected authorization error"
                    elif scenario == "propagation" and state["probes"][cluster] == 1:
                        remote_code, logs = 1, "RBAC propagation"
                elif "get deployment" in command:
                    logs = str(state["replicas"][cluster])
                elif "kubectl scale" in command:
                    count = int(re.search(r"--replicas=(\d+)", command)[1])
                    if count > 0 and scenario == "restore_failure" and cluster == "aks-primary":
                        remote_code, logs = 1, "restore failure"
                    else:
                        state["replicas"][cluster] = count
                    if count == 0 and scenario == "stop_failure":
                        remote_code, logs = 1, "scale applied but rollout failed"
                elif command.startswith("sh "):
                    logs = "Internal service ready"
                elif "kubectl apply" not in command and "rollout status" not in command:
                    raise AssertionError(command)
                response = {"exitCode": remote_code, "logs": logs}
                if scenario == "missing_exit":
                    response.pop("exitCode")
                result = json.dumps(response)
                if scenario == "pending" and not state.get("pending"):
                    state["pending"] = result
                    result = "command id: " + "a" * 32 + ", started at: now"
                elif scenario == "unexpected_result":
                    result = "unexpected CLI response"
        else:
            raise AssertionError(args)
    elif tool == "curl":
        disrupted = 0 in state["replicas"].values()
        if scenario == "timeouts" and disrupted and state["timeouts"] < 3:
            state["timeouts"] += 1
            code = 28
        else:
            if state["replicas"]["aks-secondary"] == 0:
                region = "westus3"
            else:
                region = "centralus"
            gateway = region
            if scenario == "locality_failure" and disrupted:
                gateway = "wrongregion"
            body = {"region": region, "cluster": "aks-" + ("primary" if region == "westus3" else "secondary"), "pod": "lab-api-test"}
            if scenario == "missing_body_field":
                del body["pod"]
            local_path(option("--dump-header")).write_text(f"HTTP/1.1 200 OK\r\nX-Lab-Gateway-Region: {gateway}\r\n\r\n")
            local_path(option("--output")).write_text(json.dumps(body))
            result = "503" if scenario == "http_failure" else "200"
    else:
        raise AssertionError(tool)
    state_path.write_text(json.dumps(state))
    if code:
        print(f"Simulated {tool} failure ({scenario})", file=sys.stderr)
    print(result, end="")
    return code


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "--mock":
    sys.exit(mock_command(sys.argv[2], sys.argv[3:]))

import unittest

BASH = shutil.which("bash")
if os.name == "nt":
    git_bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if git_bash.exists():
        BASH = str(git_bash)


@unittest.skipUnless(BASH, "Bash is required")
class BashTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lab-bash-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.state_path = self.directory / "state.json"
        self.initial = {
            "scenario": "happy", "calls": [], "assignments": [], "attachments": [],
            "clock": dt.datetime.now(dt.timezone.utc).isoformat(),
            "replicas": {"aks-primary": 2, "aks-secondary": 3}, "probes": {}, "timeouts": 0,
            "env": {
                "AZURE_ENV_NAME": "offline-test", "AZURE_SUBSCRIPTION_ID": "test-sub",
                "AZURE_RESOURCE_GROUP": "rg-test", "AZURE_LOCATION": "westus3",
                "AZURE_PRIMARY_LOCATION": "westus3", "AZURE_SECONDARY_LOCATION": "centralus",
                "AKS_PRIMARY_NAME": "aks-primary", "AKS_SECONDARY_NAME": "aks-secondary",
                "BACKEND_PRIMARY_IP": "10.10.2.10", "BACKEND_SECONDARY_IP": "10.20.2.10",
                "APIM_PRIMARY_SUBNET": "10.10.0.0/26", "APIM_SECONDARY_SUBNET": "10.20.0.0/26",
                "APIM_PUBLISHER_EMAIL": "test@example.invalid", "API_URL": "https://offline.invalid/lab",
                "AZURE_FRONT_DOOR_PROFILE": "afd-test",
                "APIM_PRIMARY_HOST": "primary.regional.azure-api.net",
                "APIM_SECONDARY_HOST": "secondary.regional.azure-api.net",
            },
        }

    def run_script(self, script, *args, scenario="happy", inline=None, success=True, script_directory=None):
        self.initial["scenario"] = scenario
        self.state_path.write_text(json.dumps(self.initial))
        env = os.environ.copy()
        env.update({
            "MOCK_STATE": str(self.state_path), "MOCK_TEST": Path(__file__).as_posix(),
            "MOCK_PYTHON": Path(sys.executable).as_posix(), "MOCK_SCRIPTS": (script_directory or SCRIPTS).as_posix(),
            "MOCK_SCENARIO": scenario,
        })
        harness = r'''
az() { MSYS2_ARG_CONV_EXCL='*' "$MOCK_PYTHON" "$MOCK_TEST" --mock az "$@"; }
azd() { MSYS2_ARG_CONV_EXCL='*' "$MOCK_PYTHON" "$MOCK_TEST" --mock azd "$@"; }
python3() {
    if [[ "${1##*/}" == lab_readiness.py ]]; then
        MSYS2_ARG_CONV_EXCL='*' "$MOCK_PYTHON" "$MOCK_TEST" --mock readiness "${@:2}"
    else
        command "$MOCK_PYTHON" "$@"
    fi
}
python() { python3 "$@"; }
curl() { MSYS2_ARG_CONV_EXCL='*' "$MOCK_PYTHON" "$MOCK_TEST" --mock curl "$@"; }
sleep() {
    if [[ "$MOCK_SCENARIO" == interrupt && "$1" == 5 && "${restore:-false}" == true ]]; then
        kill -TERM "$$"
    fi
    if [[ "$MOCK_SCENARIO" == startup_* && "$1" == 15 ]]; then
        SECONDS=$((SECONDS + 15))
    fi
    if [[ "$MOCK_SCENARIO" == deadline_boundary && "$1" == 5 ]]; then
        MOCK_SAMPLE_DELAY=$(( ${MOCK_SAMPLE_DELAY:-0} + 15 ))
        SECONDS=$((start + MOCK_SAMPLE_DELAY))
    fi
    MSYS2_ARG_CONV_EXCL='*' "$MOCK_PYTHON" "$MOCK_TEST" --mock sleep "$@"
}
date() { MSYS2_ARG_CONV_EXCL='*' "$MOCK_PYTHON" "$MOCK_TEST" --mock date "$@"; }
export -f az azd curl sleep date python3 python
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    openssl() {
        MSYS2_ARG_CONV_EXCL='/CN=' command openssl "$@"
    }
    export -f openssl
fi
'''
        if inline:
            harness += 'source "$MOCK_SCRIPTS/Lab.Common.sh"\n' + inline
        else:
            harness += 'bash "$MOCK_SCRIPTS/$1" "${@:2}"'
        result = subprocess.run(
            [BASH, "-c", harness, "--", script, *args], env=env, cwd=ROOT,
            text=True, capture_output=True, timeout=600,
        )
        self.state = json.loads(self.state_path.read_text())
        output = result.stdout + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        self.assertNotIn("command not found", output)
        return output

    def test_syntax(self):
        for path in SCRIPTS.glob("*.sh"):
            self.assertNotIn(b"\r", path.read_bytes(), f"Bash scripts must use LF: {path.name}")
            result = subprocess.run([BASH, "-n", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_smoke_contract_and_pending_result(self):
        self.run_script("Test-Lab.sh", "--samples", "2")
        requests = [call for call in self.state["calls"] if call[0] == "curl"]
        self.assertEqual(len(requests), 5)
        self.assertEqual(sum("--head" in call for call in requests), 1)
        output = self.run_script("", scenario="pending", inline='lab_load_environment; lab_regions; lab_aks aks-primary "kubectl rollout status deployment/lab-api -n apim-lab"')
        self.assertIn("ready", output)
        calls = [call for call in self.state["calls"] if call[:3] == ["az", "aks", "command"]]
        self.assertEqual([call[3] for call in calls], ["invoke", "result"])

    def test_smoke_rejects_bad_body_http_and_cli_results(self):
        for scenario in ("missing_body_field", "http_failure"):
            with self.subTest(scenario=scenario):
                self.run_script("Test-Lab.sh", scenario=scenario, success=False)
        for scenario in ("missing_exit", "unexpected_result"):
            with self.subTest(scenario=scenario):
                self.run_script("", scenario=scenario, inline='lab_load_environment; lab_regions; lab_aks aks-primary "kubectl rollout status deployment/lab-api"', success=False)

    def test_origins_fail_explicitly_when_evidence_is_missing_or_unhealthy(self):
        for scenario in ("missing_origin", "unhealthy_origin"):
            with self.subTest(scenario=scenario):
                output = self.run_script("Test-Origins.sh", "--wait-seconds", "0", scenario=scenario, success=False)
                self.assertIn("Regional origin health was not proven", output)
                self.assertFalse(any("--command" in call for call in self.state["calls"]))

    def test_recent_recovery_uses_valid_query_window_without_accepting_old_metrics(self):
        boundary = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
        self.initial["clock"] = boundary
        output = self.run_script("Test-Origins.sh", "--since", boundary, "--wait-seconds", "0", scenario="recent_boundary", success=False)
        self.assertIn("Regional origin health was not proven", output)
        self.assertNotIn("BadRequest", output)
        query = next(call for call in self.state["calls"] if call[:4] == ["az", "monitor", "metrics", "list"])
        start = dt.datetime.fromisoformat(query[query.index("--start-time") + 1].replace("Z", "+00:00"))
        end = dt.datetime.fromisoformat(query[query.index("--end-time") + 1].replace("Z", "+00:00"))
        self.assertGreaterEqual((end - start).total_seconds(), 60)

    def test_next_region_is_not_stopped_until_origin_recovery_is_proven(self):
        self.run_script("Test-EndToEnd.sh", "--temporary-cluster-admin", "--origin-wait-seconds", "0", "--yes", scenario="unhealthy_recovery", success=False)
        self.assertEqual(self.state["replicas"], self.initial["replicas"])
        self.assertEqual(self.state["assignments"], [])
        self.assertFalse(any("--command" in call and "aks-secondary" in call and "--replicas=0" in call[call.index("--command") + 1] for call in self.state["calls"]))

    def test_origin_preflight_failure_does_not_grant_roles_or_disrupt_workloads(self):
        self.run_script("Test-EndToEnd.sh", "--temporary-cluster-admin", "--origin-wait-seconds", "0", "--yes", scenario="missing_origin", success=False)
        self.assertEqual(self.state["replicas"], self.initial["replicas"])
        self.assertFalse(any(call[:3] == ["az", "role", "assignment"] or "--command" in call for call in self.state["calls"]))

    def test_five_responses_cannot_pass_at_or_after_the_failover_deadline(self):
        output = self.run_script("Test-Failover.sh", "--stop-region", "Secondary", "--timeout-seconds", "60", "--yes", scenario="deadline_boundary", success=False)
        self.assertIn("Failover did not stabilize within 60 seconds", output)
        self.assertNotIn("PASS availability", output)
        self.assertEqual(self.state["replicas"], self.initial["replicas"])

    def test_argument_validation(self):
        for args in (("--samples", "0"), ("--samples", "101"), ("--samples", "01"), ("--unknown",)):
            self.run_script("Test-Lab.sh", *args, success=False)
            self.assertEqual(self.state["calls"], [])
        self.run_script("Test-Failover.sh", "--stop-region", "Unknown", success=False)

    def test_what_if_never_contacts_azure_or_http(self):
        self.run_script("Test-EndToEnd.sh", "--temporary-cluster-admin", "--what-if")
        self.assertEqual([call[0] for call in self.state["calls"]], ["azd"])
        self.run_script("Test-Failover.sh", "--stop-region", "Primary", "--what-if")
        self.assertEqual([call[0] for call in self.state["calls"]], ["azd"])

    def test_prepare_and_deploy_in_isolated_project(self):
        project = self.directory / "isolated-project"
        script_directory = project / "scripts" / "bash"
        shutil.copytree(SCRIPTS, script_directory)
        workload = project / "src" / "lab-api"
        workload.mkdir(parents=True)
        shutil.copy(ROOT / "src" / "lab-api" / "workload.yaml", workload)
        self.run_script("Prepare-Lab.sh", script_directory=script_directory)
        self.initial["env"] = self.state["env"]
        tls = project / ".azure" / "offline-test" / "tls"
        self.assertEqual({p.name for p in tls.iterdir()}, {"root.cer", "tls.crt", "tls.key"})
        self.assertTrue(self.initial["env"]["LAB_ROOT_CERTIFICATE"])
        self.run_script("Deploy-LabApi.sh", script_directory=script_directory)
        self.assertEqual(len(self.state["attachments"]), 4)
        self.assertTrue(all(not Path(path).exists() for path in self.state["attachments"]))
        calls = [call for call in self.state["calls"] if "--command" in call and "kubectl apply" in call[call.index("--command") + 1]]
        self.assertEqual(len(calls), 2)
        self.initial["env"]["LAB_ROOT_CERTIFICATE"] = "different-ca"
        output = self.run_script("Deploy-LabApi.sh", script_directory=script_directory, success=False)
        self.assertIn("Local TLS CA differs", output)
        self.assertFalse(any(call[0] == "az" for call in self.state["calls"]))

    def test_startup_running_and_new_environment_never_start(self):
        for clusters in ({}, {"aks-primary": ["Succeeded/Running"], "aks-secondary": ["Succeeded/Running"]}):
            self.initial["cluster_states"] = clusters
            self.run_script("", scenario="startup_running", inline="lab_load_environment; lab_wait_clusters_running true 30")
            self.assertFalse(any(call[:3] == ["az", "aks", "start"] for call in self.state["calls"]))
            discovery = next(call for call in self.state["calls"] if call[:3] == ["az", "resource", "list"])
            self.assertIn("azd-env-name=offline-test", discovery)
            self.assertIn("test-sub", discovery)

    def test_startup_stopped_clusters_start_once_without_serial_wait(self):
        self.initial["cluster_states"] = {
            name: ["Succeeded/Stopped", "Succeeded/Stopped", "Starting/Running", "Succeeded/Running"]
            for name in ("aks-primary", "aks-secondary")
        }
        self.run_script("", scenario="startup_stopped", inline="lab_load_environment; lab_wait_clusters_running true 120")
        starts = [i for i, call in enumerate(self.state["calls"]) if call[:3] == ["az", "aks", "start"]]
        self.assertEqual(len(starts), 2)
        first_sleep = next(i for i, call in enumerate(self.state["calls"]) if call[0] == "sleep")
        self.assertLess(max(starts), first_sleep)
        for i in starts:
            self.assertIn("--no-wait", self.state["calls"][i])
            self.assertIn("rg-test", self.state["calls"][i])

    def test_startup_waits_for_stopping_before_start_and_for_existing_start(self):
        self.initial["cluster_states"] = {
            "aks-primary": ["Stopping/Running", "Succeeded/Stopped", "Succeeded/Running"],
            "aks-secondary": ["Starting/Running", "Starting/Running", "Succeeded/Running"],
        }
        self.run_script("", scenario="startup_transition", inline="lab_load_environment; lab_wait_clusters_running true 120")
        starts = [call for call in self.state["calls"] if call[:3] == ["az", "aks", "start"]]
        self.assertEqual(len(starts), 1)
        self.assertIn("aks-primary", starts[0])

    def test_startup_check_only_failures_and_timeout_are_explicit(self):
        cases = (
            ("startup_check", ["Succeeded/Stopped"], "false", 30, "not Running/Succeeded"),
            ("startup_failed", ["Failed/Running"], "true", 30, "unsupported state"),
            ("startup_invalid", ["Mystery/Running"], "true", 30, "unsupported state"),
            ("startup_invalid_json", ["Succeeded/Running"], "true", 30, "JSON"),
            ("startup_discovery_error", ["Succeeded/Running"], "true", 30, ""),
            ("startup_read_error", ["Succeeded/Running"], "true", 30, ""),
            ("startup_start_error", ["Succeeded/Stopped"], "true", 30, ""),
            ("startup_timeout", ["Starting/Running"], "true", 30, "within 30 seconds"),
        )
        for scenario, sequence, start, timeout, message in cases:
            with self.subTest(scenario=scenario):
                self.initial["cluster_states"] = {"aks-primary": sequence}
                output = self.run_script("", scenario=scenario, success=False,
                    inline=f"lab_load_environment; lab_wait_clusters_running {start} {timeout}")
                self.assertIn(message, output)
                if scenario != "startup_start_error":
                    self.assertFalse(any(call[:3] == ["az", "aks", "start"] for call in self.state["calls"]))
        self.assertEqual(sum(call[0] == "sleep" for call in self.state["calls"]), 2)

    def test_startup_scope_and_ambiguity_fail_before_start(self):
        self.initial["cluster_states"] = {"aks-primary": ["Succeeded/Stopped"]}
        self.initial["env"]["AZURE_RESOURCE_GROUP"] = "different-group"
        self.run_script("", scenario="startup_scope", success=False, inline="lab_load_environment; lab_wait_clusters_running true 30")
        self.assertFalse(any(call[:3] == ["az", "aks", "start"] for call in self.state["calls"]))
        self.initial["env"]["AZURE_RESOURCE_GROUP"] = "rg-test"
        self.initial["cluster_states"] = {name: ["Succeeded/Stopped"] for name in ("one", "two", "three")}
        self.run_script("", scenario="startup_ambiguous", success=False, inline="lab_load_environment; lab_wait_clusters_running true 30")
        self.assertFalse(any(call[:3] == ["az", "aks", "start"] for call in self.state["calls"]))

    def test_provision_wrapper_preview_and_failures_never_deploy_early(self):
        self.initial["cluster_states"] = {"aks-primary": ["Succeeded/Stopped"]}
        self.run_script("Provision-Lab.sh", "--preview", "--start-resources", scenario="startup_preview")
        self.assertEqual(self.state["calls"], [["azd", "provision", "--preview"]])
        project = self.directory / "provision-project"
        script_directory = project / "scripts" / "bash"
        shutil.copytree(SCRIPTS, script_directory)
        self.run_script("Provision-Lab.sh", "--start-resources", "--wait-seconds", "30",
            scenario="startup_start_error", success=False, script_directory=script_directory)
        self.assertFalse(any(call[:2] == ["azd", "provision"] for call in self.state["calls"]))
        self.initial["env"] = self.state["env"]
        self.initial["cluster_states"] = {"aks-primary": ["Succeeded/Stopped", "Succeeded/Running"]}
        self.run_script("Provision-Lab.sh", "--start-resources", "--wait-seconds", "60",
            scenario="startup_provision_error", success=False, script_directory=script_directory)
        provision_index = next(i for i, call in enumerate(self.state["calls"]) if call[:2] == ["azd", "provision"])
        readiness_index = next(i for i, call in enumerate(self.state["calls"]) if call[0] == "readiness")
        self.assertGreater(provision_index, readiness_index)
        self.assertIn("--start-resources", self.state["calls"][readiness_index])

    def test_readiness_default_is_readonly_and_failure_stops_http_and_mutations(self):
        self.initial["env"]["LAB_ROOT_CERTIFICATE"] = "mock-public-ca"
        for script, args in (
                ("Deploy-LabApi.sh", []), ("Test-Lab.sh", []), ("Test-Origins.sh", ["--wait-seconds", "0"]),
                ("Test-Failover.sh", ["--stop-region", "Primary", "--yes"]),
                ("Test-EndToEnd.sh", ["--temporary-cluster-admin", "--yes"])):
            with self.subTest(script=script):
                self.run_script(script, *args, scenario="readiness_failure", success=False)
                self.assertFalse(any(call[0] == "curl" or "scale" in " ".join(call)
                                     or call[:4] == ["az", "role", "assignment", "create"]
                                     for call in self.state["calls"]))
                self.assertFalse(any(call[:4] == ["az", "aks", "command", "invoke"]
                                     for call in self.state["calls"]))
                checks = [call for call in self.state["calls"] if call[0] == "readiness"]
                self.assertTrue(checks)
                self.assertTrue(all("--start-resources" not in call for call in checks))
        self.run_script("Test-Readiness.sh", "--stage", "Infrastructure")
        self.assertNotIn("--start-resources", next(call for call in self.state["calls"] if call[0] == "readiness"))
        self.run_script("Test-Readiness.sh", "--start-resources", "--wait-seconds", "60")
        self.assertIn("--start-resources", next(call for call in self.state["calls"] if call[0] == "readiness"))

    def test_workload_readiness_failure_removes_temporary_roles_without_disruption(self):
        self.run_script("Test-EndToEnd.sh", "--temporary-cluster-admin", "--samples", "1", "--yes",
                        scenario="workload_readiness_failure", success=False)
        self.assertEqual(self.state["assignments"], [])
        self.assertEqual(self.state["replicas"], self.initial["replicas"])
        self.assertFalse(any("--replicas=0" in " ".join(call) for call in self.state["calls"]))

    def test_prepare_rejects_invalid_configuration_before_azure_calls(self):
        self.initial["env"]["AZURE_SECONDARY_LOCATION"] = "westus3"
        self.run_script("Prepare-Lab.sh", success=False)
        self.assertFalse(any(call[0] == "az" for call in self.state["calls"]))
        self.initial["env"]["AZURE_SECONDARY_LOCATION"] = "centralus"
        self.initial["env"]["APIM_PUBLISHER_EMAIL"] = "invalid"
        self.run_script("Prepare-Lab.sh", success=False)
        self.assertEqual([call[0] for call in self.state["calls"]], ["azd"])

    def test_failover_records_transient_errors_and_restores(self):
        output = self.run_script("Test-Failover.sh", "--stop-region", "Secondary", "--yes", scenario="timeouts")
        self.assertIn("failed samples=3", output)
        self.assertIn("evidence=ObservedTransition", output)
        self.assertIn("PASS recovery:", output)
        self.assertEqual(self.state["replicas"], self.initial["replicas"])

    def test_failover_persists_bounded_sanitized_evidence_and_strict_recovery(self):
        path = self.directory / "evidence" / "success.json"
        self.run_script("Test-Failover.sh", "--stop-region", "Secondary", "--yes",
                        "--report-path", str(path), scenario="timeouts")
        report = json.loads(path.read_text())
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["evidence"], "ObservedTransition")
        self.assertEqual(report["replicas"], {"original": 3, "stopped": 0, "restored": 3})
        self.assertTrue(all(stage["status"] == "passed" for stage in report["stages"].values()))
        self.assertEqual(report["failedSampleCount"], 3)
        self.assertEqual(report["sampleCount"], 13)
        self.assertTrue(all(sample["observerLatencyMs"] >= 0 for sample in report["samples"]))
        self.assertTrue(report["completedAtUtc"].endswith("Z"))
        self.assertGreaterEqual(report["timing"]["disruptionToAvailabilityObservedMs"],
                                report["timing"]["disruptionToFirstSurvivorObservedMs"])
        self.assertNotRegex(path.read_text(), "offline.invalid|lab-api-test|X-Lab-Gateway|Simulated")

    def test_failover_failure_reports_always_attempt_restoration(self):
        for scenario in ("deadline_boundary", "locality_failure", "stop_failure", "restore_failure", "unhealthy_recovery"):
            with self.subTest(scenario=scenario):
                path = self.directory / f"{scenario}.json"
                output = self.run_script(
                    "Test-Failover.sh", "--stop-region", "Primary", "--timeout-seconds", "60",
                    "--origin-wait-seconds", "0", "--yes", "--report-path", str(path),
                    scenario=scenario, success=False)
                report = json.loads(path.read_text())
                self.assertEqual(report["status"], "failed")
                self.assertTrue(report["completedAtUtc"].endswith("Z"))
                self.assertIn("Restoring aks-primary to 2 replicas", output)
                self.assertTrue(any("--replicas=2" in " ".join(call) for call in self.state["calls"]))
                if scenario == "restore_failure":
                    self.assertEqual(report["stages"]["restoration"]["status"], "failed")
                    self.assertEqual(report["stages"]["replicaVerification"]["status"], "failed")
                    self.assertEqual(report["replicas"]["restored"], 0)
                    self.assertEqual(report["stages"]["recoveryOrigins"]["status"], "notRun")
                else:
                    self.assertEqual(self.state["replicas"], self.initial["replicas"])
                    self.assertEqual(report["stages"]["restoration"]["status"], "passed")
                if scenario in ("deadline_boundary", "locality_failure", "stop_failure"):
                    self.assertEqual(report["evidence"], "NotProven")
                if scenario == "unhealthy_recovery":
                    self.assertEqual(report["stages"]["recoveryOrigins"]["status"], "failed")
                if scenario == "locality_failure":
                    self.assertEqual(report["samples"][-1]["error"], "invalidResponse")

    def test_failover_readiness_failure_is_reported_without_disruption(self):
        path = self.directory / "readiness.json"
        self.run_script("Test-Failover.sh", "--stop-region", "Primary", "--yes",
                        "--report-path", str(path), scenario="readiness_failure", success=False)
        report = json.loads(path.read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["stages"]["readiness"]["status"], "failed")
        self.assertEqual(report["stages"]["restoration"]["status"], "notRun")
        self.assertFalse(any("--replicas=0" in " ".join(call) for call in self.state["calls"]))

    def test_failover_existing_report_is_not_overwritten_or_disruptive(self):
        path = self.directory / "existing.json"
        path.write_text('{"keep": true}')
        self.run_script("Test-Failover.sh", "--stop-region", "Primary", "--yes",
                        "--report-path", str(path), success=False)
        self.assertEqual(json.loads(path.read_text()), {"keep": True})
        self.assertFalse(any("--replicas=0" in " ".join(call) for call in self.state["calls"]))

    def test_failover_interrupt_reports_and_restores(self):
        path = self.directory / "interrupted.json"
        self.run_script("Test-Failover.sh", "--stop-region", "Primary", "--yes",
                        "--report-path", str(path), scenario="interrupt", success=False)
        report = json.loads(path.read_text())
        self.assertEqual(report["status"], "interrupted")
        self.assertEqual(report["exitCode"], 143)
        self.assertEqual(report["stages"]["availability"]["status"], "failed")
        self.assertEqual(report["stages"]["restoration"]["status"], "passed")
        self.assertEqual(self.state["replicas"], self.initial["replicas"])

    def test_private_failover_reports_continued_service_without_moveback(self):
        project = self.directory / "private-project"
        script_directory = project / "scripts" / "bash"
        shutil.copytree(SCRIPTS, script_directory)
        shutil.copy2(ROOT / "scripts" / "failover_report.py", script_directory.parent)
        common = script_directory / "Lab.Common.sh"
        with common.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write("\nlab_private_readiness() { :; }\n")
        self.initial["env"].update({
            "APP_INGRESS_MODE": "private",
            "FRONT_DOOR_PRIMARY_ORIGIN_HOST": "primary.regional.azure-api.net",
            "FRONT_DOOR_SECONDARY_ORIGIN_HOST": "secondary.regional.azure-api.net",
            "APP_GATEWAY_PRIMARY_HOST": "primary.regional.azure-api.net",
            "APP_GATEWAY_SECONDARY_HOST": "secondary.regional.azure-api.net",
            "FRONT_DOOR_ORIGIN_GROUP": "regional-apis-private",
        })
        path = self.directory / "private.json"
        self.run_script("Test-Failover.sh", "--stop-region", "Primary", "--yes",
                        "--report-path", str(path), script_directory=script_directory)
        report = json.loads(path.read_text())
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["ingressMode"], "private")
        self.assertEqual(report["evidence"], "ContinuedService")
        self.assertEqual(report["target"], {"key": "Primary", "location": "westus3"})
        self.assertEqual(report["survivor"], {"key": "Secondary", "location": "centralus"})

    def test_complete_workflow_creates_and_removes_only_own_roles(self):
        output = self.run_script("Test-EndToEnd.sh", "--temporary-cluster-admin", "--samples", "1", "--yes")
        self.assertIn("PASS: both failover directions", output)
        self.assertIn("evidence=ObservedTransition", output)
        self.assertIn("evidence=ContinuedService", output)
        self.assertEqual(self.state["assignments"], [])
        self.assertEqual(self.state["replicas"], self.initial["replicas"])
        grants = [call for call in self.state["calls"] if call[:4] == ["az", "role", "assignment", "create"]]
        self.assertEqual(len(grants), 2)
        for cluster in ("aks-primary", "aks-secondary"):
            self.assertTrue(any(cluster in call[call.index("--scope") + 1] for call in grants))
        final_curl = max(i for i, call in enumerate(self.state["calls"]) if call[0] == "curl")
        final_delete = max(i for i, call in enumerate(self.state["calls"]) if call[:4] == ["az", "role", "assignment", "delete"])
        self.assertGreater(final_curl, final_delete)

    def test_existing_inherited_group_access_is_preserved(self):
        self.run_script("Test-EndToEnd.sh", "--temporary-cluster-admin", "--samples", "1", "--yes", scenario="existing")
        self.assertFalse(any(call[:4] in (["az", "role", "assignment", "create"], ["az", "role", "assignment", "delete"]) for call in self.state["calls"]))
        lists = [call for call in self.state["calls"] if "--assignee" in call]
        self.assertTrue(all("--include-inherited" in call and "--include-groups" in call for call in lists))

    def test_no_role_mutations_without_opt_in_and_denied_access_fails(self):
        self.run_script("Test-EndToEnd.sh", "--yes", scenario="denied", success=False)
        self.assertFalse(any(call[:3] == ["az", "role", "assignment"] for call in self.state["calls"]))
        self.assertEqual(self.state["replicas"], self.initial["replicas"])

    def test_partial_grant_and_authorization_error_cleanup(self):
        for scenario in ("partial_grant", "auth_error"):
            with self.subTest(scenario=scenario):
                self.run_script("Test-EndToEnd.sh", "--temporary-cluster-admin", "--yes", scenario=scenario, success=False)
                self.assertEqual(self.state["assignments"], [])
                self.assertEqual(self.state["replicas"], self.initial["replicas"])

    def test_failure_after_disruption_restores_both_clusters_and_roles(self):
        self.run_script("Test-EndToEnd.sh", "--temporary-cluster-admin", "--samples", "1", "--yes", scenario="locality_failure", success=False)
        self.assertEqual(self.state["assignments"], [])
        self.assertEqual(self.state["replicas"], self.initial["replicas"])
        scales = [call for call in self.state["calls"] if "--command" in call and "kubectl scale" in call[call.index("--command") + 1]]
        self.assertTrue(any("aks-secondary" in call for call in scales))

    def test_restore_failure_still_attempts_other_cluster_and_role_cleanup(self):
        self.run_script("Test-EndToEnd.sh", "--temporary-cluster-admin", "--samples", "1", "--yes", scenario="restore_failure", success=False)
        self.assertEqual(self.state["assignments"], [])
        self.assertEqual(self.state["replicas"]["aks-secondary"], 3)
        self.assertTrue(any("--command" in call and "aks-secondary" in call and "--replicas=3" in call[call.index("--command") + 1] for call in self.state["calls"]))

    def test_cleanup_failure_is_not_reported_as_success(self):
        for scenario in ("delete_failure", "delete_not_effective"):
            with self.subTest(scenario=scenario):
                output = self.run_script("Test-EndToEnd.sh", "--temporary-cluster-admin", "--samples", "1", "--yes", scenario=scenario, success=False)
                self.assertNotIn("PASS: both failover directions", output)
                deletes = [call for call in self.state["calls"] if call[:4] == ["az", "role", "assignment", "delete"]]
                self.assertEqual(len(deletes), 2)

    def test_tls_manifest_and_multiline_attachment_cleanup(self):
        output = self.run_script("", inline=r'''
lab_require_tools openssl
tls="$LAB_TMP/material"
lab_new_tls "$tls"
lab_assert_tls "$tls"
lab_load_environment
lab_regions
lab_region Primary
lab_manifest "$tls" > "$LAB_TMP/workload.yaml"
lab_aks aks-primary "kubectl apply -f workload.yaml" "$LAB_TMP/workload.yaml"
lab_aks aks-primary $'for i in 1; do\n  echo ready\ndone'
''')
        self.assertIn("ready", output)
        self.assertEqual(len(self.state["attachments"]), 2)
        self.assertTrue(all(not Path(path).exists() for path in self.state["attachments"]))

    def test_tls_key_mismatch_and_unresolved_placeholders_fail(self):
        output = self.run_script("", inline=r'''
lab_new_tls "$LAB_TMP/tls"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$LAB_TMP/tls/tls.key"
lab_assert_tls "$LAB_TMP/tls"
''', success=False)
        self.assertIn("certificate and key do not match", output)
        self.run_script("", inline=r'''
lab_new_tls "$LAB_TMP/tls"
mkdir -p "$LAB_TMP/project/src/lab-api"
printf '__UNKNOWN__' > "$LAB_TMP/project/src/lab-api/workload.yaml"
LAB_ROOT="$LAB_TMP/project"
LAB_LOCATION=westus3 LAB_CLUSTER=aks-test LAB_BACKEND_IP=10.10.2.10 LAB_APIM_SUBNET=10.10.0.0/26
lab_manifest "$LAB_TMP/tls"
''', success=False)


if __name__ == "__main__":
    unittest.main()
