"""Offline management, startup and Kubernetes readiness contracts for both shells."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("lab_readiness", ROOT / "scripts" / "lab_readiness.py")
readiness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(readiness)
SCOPE = "/subscriptions/test-sub/resourceGroups/rg-test/providers/"


class Fixture:
    def __init__(self, mode="private"):
        self.env = {
            "AZURE_ENV_NAME": "offline-test", "AZURE_SUBSCRIPTION_ID": "test-sub",
            "AZURE_RESOURCE_GROUP": "rg-test", "APP_INGRESS_MODE": mode,
            "AZURE_LOCATION": "westus3", "AZURE_PRIMARY_LOCATION": "westus3",
            "AZURE_SECONDARY_LOCATION": "centralus", "APIM_NAME": "apim-test",
            "AZURE_FRONT_DOOR_PROFILE": "afd-test", "AZURE_FRONT_DOOR_ENDPOINT": "api-test",
        }
        self.resources = {}
        self.calls = []
        self.clock = 0
        self.health_state = "Healthy"
        self.health_payload = None
        self.sequences = {}
        self.auto_start = True
        self.nodes = [{"spec": {}, "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
                      for _ in range(2)]
        self.items = [
            {"kind": "Deployment", "metadata": {"name": "lab-api", "generation": 2},
             "spec": {"replicas": 2}, "status": {"observedGeneration": 2, "replicas": 2,
                                               "updatedReplicas": 2, "readyReplicas": 2, "availableReplicas": 2}},
            {"kind": "Service", "metadata": {"name": "lab-api"},
             "spec": {"type": "LoadBalancer", "ports": [{"port": 443}]},
             "status": {"loadBalancer": {"ingress": [{"ip": "10.10.2.10", "ipMode": "VIP"}]}}},
            {"kind": "EndpointSlice", "metadata": {"labels": {"kubernetes.io/service-name": "lab-api"}},
             "endpoints": [{"conditions": {"ready": True}, "addresses": [f"10.0.0.{i}"],
                            "targetRef": {"uid": f"pod-{i}"}} for i in (1, 2)]},
        ]
        for key, region, vip, backend in (
                ("PRIMARY", "westus3", "10.10.0.4", "10.10.2.10"),
                ("SECONDARY", "centralus", "10.20.0.4", "10.20.2.10")):
            name = f"aks-{key.lower()}"
            self.env[f"AKS_{key}_NAME"] = name
            self.env[f"BACKEND_{key}_IP"] = backend
            self.add(readiness.AKS, name, region, {
                "powerState": {"code": "Running"},
                "agentPoolProfiles": [{"name": "system", "mode": "System", "count": 2,
                                       "provisioningState": "Succeeded", "powerState": {"code": "Running"}}],
            })
            gateway = self.add(readiness.GATEWAY, f"agw-{key.lower()}", region, {
                "operationalState": "Running",
                "backendAddressPools": [{"name": "regional-apim",
                                        "id": f"{SCOPE}{readiness.GATEWAY}/agw-{key.lower()}/backendAddressPools/regional-apim",
                                        "properties": {"backendAddresses": [{"ipAddress": vip}]}}],
            })
            self.env[f"APP_GATEWAY_{key}_ID"] = gateway["id"]
            self.env[f"APP_GATEWAY_{key}_HOST"] = f"gw-{region}.owned-domain.org"
            self.env[f"APIM_{key}_HOST"] = f"apim-{region}.regional.azure-api.net"
        self.add("Microsoft.ApiManagement/service", "apim-test", "West US 3", {
            "virtualNetworkType": "Internal" if mode == "private" else "External",
            "privateIPAddresses": ["10.10.0.4"],
            "additionalLocations": [{"location": "Central US", "privateIPAddresses": ["10.20.0.4"]}],
        })
        self.profile = self.add("Microsoft.Cdn/profiles", "afd-test", "global", {})
        self.endpoint = self.add("Microsoft.Cdn/profiles/afdEndpoints", "api-test", "global",
                                 {"enabledState": "Enabled"}, self.profile["id"] + "/afdEndpoints/api-test")
        group_name = "regional-apis-private" if mode == "private" else "regional-apis"
        self.group = self.add("Microsoft.Cdn/profiles/originGroups", group_name, "global", {
            "healthProbeSettings": {"probePath": "/lab/health/ready", "probeProtocol": "Https",
                                    "probeRequestType": "HEAD"},
        }, self.profile["id"] + "/originGroups/" + group_name)
        self.route = self.add("Microsoft.Cdn/profiles/afdEndpoints/routes", "lab-api", "global", {
            "enabledState": "Enabled", "forwardingProtocol": "HttpsOnly", "httpsRedirect": "Enabled",
            "linkToDefaultDomain": "Enabled", "patternsToMatch": ["/*"], "originGroup": {"id": self.group["id"]},
        }, self.endpoint["id"] + "/routes/lab-api")
        for key, name in (("PRIMARY", "br"), ("SECONDARY", "us")):
            host = self.env[f"APP_GATEWAY_{key}_HOST" if mode == "private" else f"APIM_{key}_HOST"]
            self.add("Microsoft.Cdn/profiles/originGroups/origins", name, "global", {
                "enabledState": "Enabled", "httpsPort": 443, "hostName": host,
                "originHostHeader": host, "enforceCertificateNameCheck": True,
            }, self.group["id"] + "/origins/" + name)

    def add(self, kind, name, region, properties, identifier=None):
        resource = {"id": identifier or SCOPE + kind + "/" + name, "name": name, "type": kind,
                    "location": region, "resourceGroup": "rg-test", "tags": {"azd-env-name": "offline-test"},
                    "properties": {"provisioningState": "Succeeded", **properties}}
        self.resources[resource["id"].lower()] = resource
        return resource

    def resource(self, kind, name):
        return self.resources[(SCOPE + kind + "/" + name).lower()]

    def json_command(self, args, timeout=300):
        self.calls.append(args)
        if args[:2] == ["account", "show"]:
            return {"id": "test-sub", "state": "Enabled"}
        if args[:2] == ["resource", "list"]:
            return copy.deepcopy(list(self.resources.values()))
        if args[0] == "rest":
            identifier = args[args.index("--url") + 1].split("?")[0].lower()
            resource = copy.deepcopy(self.resources[identifier])
            if identifier in self.sequences:
                sequence = self.sequences[identifier]
                state, power = sequence[0]
                if len(sequence) > 1:
                    sequence.pop(0)
                resource["properties"]["provisioningState"] = state
                field = "powerState" if resource["type"] == readiness.AKS else "operationalState"
                resource["properties"][field] = {"code": power} if field == "powerState" else power
            return resource
        if args[:3] == ["network", "application-gateway", "show-backend-health"]:
            if self.health_payload is not None:
                return self.health_payload
            gateway = self.resource(readiness.GATEWAY, args[args.index("--name") + 1])
            pool = gateway["properties"]["backendAddressPools"][0]
            return {"backendAddressPools": [{"backendAddressPool": {"id": pool["id"]},
                    "backendHttpSettingsCollection": [{"servers": [
                        {"address": pool["properties"]["backendAddresses"][0]["ipAddress"],
                         "health": self.health_state}]}]}]}
        if args[:3] == ["aks", "command", "invoke"]:
            items = copy.deepcopy(self.items)
            name = args[args.index("--name") + 1]
            key = "PRIMARY" if name.endswith("primary") else "SECONDARY"
            items[1]["status"]["loadBalancer"]["ingress"][0]["ip"] = self.env[f"BACKEND_{key}_IP"]
            return {"exitCode": 0, "logs": json.dumps({"items": self.nodes})
                    + "\nLAB_WORKLOADS_JSON\n" + json.dumps({"items": items})}
        raise AssertionError(args)

    def command(self, program, args, timeout=300):
        if args[:3] == ["aks", "command", "invoke"]:
            return json.dumps(self.json_command(args))
        self.calls.append(args)
        self.assert_start(args)
        if self.auto_start:
            kind = readiness.AKS if args[0] == "aks" else readiness.GATEWAY
            target = self.resource(kind, args[args.index("--name") + 1])
            if kind == readiness.AKS:
                target["properties"]["powerState"]["code"] = "Running"
            else:
                target["properties"]["operationalState"] = "Running"

    @staticmethod
    def assert_start(args):
        assert "--no-wait" in args
        assert args[args.index("--subscription") + 1] == "test-sub"
        assert args[args.index("--resource-group") + 1] == "rg-test"

    def sleep(self, seconds):
        self.calls.append(["sleep"])
        self.clock += seconds

    def run(self, stage="Infrastructure", start=False, wait=30):
        with patch.object(readiness, "json_command", self.json_command), \
                patch.object(readiness, "command", self.command), \
                patch.object(readiness.time, "monotonic", lambda: self.clock), \
                patch.object(readiness.time, "sleep", self.sleep), \
                contextlib.redirect_stdout(io.StringIO()):
            readiness.Readiness(self.env).run(stage, start, wait)

    def starts(self):
        return [call for call in self.calls if call[:2] == ["aks", "start"]
                or call[:3] == ["network", "application-gateway", "start"]]


class ReadinessTests(unittest.TestCase):
    def report(self, fixture, extra=(), private_error=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(readiness, "environment", return_value=fixture.env), \
                patch.object(readiness, "json_command", fixture.json_command), \
                patch.object(readiness, "command", fixture.command), \
                patch.object(readiness, "private_access", side_effect=private_error) as access, \
                patch.object(readiness.sys, "argv", [
                    "lab_readiness.py", "--stage", "Infrastructure", "--format", "json", *extra]), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = readiness.main()
        return code, json.loads(stdout.getvalue()), stderr.getvalue(), access

    def test_json_report_contains_all_private_gates_timings_and_no_stdout_noise(self):
        for shell in ("powershell", "bash"):
            code, data, progress, access = self.report(Fixture(), ("--private-check-shell", shell))
            self.assertEqual(code, 0)
            self.assertEqual(data["status"], "passed")
            self.assertEqual(data["schemaVersion"], 1)
            self.assertTrue(all(item["status"] == "passed" for item in data["checks"]))
            self.assertTrue(all(item["durationSeconds"] >= 0 for item in data["checks"]))
            self.assertIn("START:", progress)
            self.assertIn("Certificate", data["checks"][-1]["name"])
            self.assertIn("Test-Origins", data["evidenceBoundary"])
            access.assert_called_once_with(shell)

    def test_private_gate_failure_produces_failed_json_and_nonzero_exit(self):
        code, data, progress, _ = self.report(
            Fixture(), ("--private-check-shell", "powershell"),
            readiness.ReadinessError("Injected private-access failure"))
        self.assertEqual(code, 1)
        self.assertEqual(data["status"], "failed")
        self.assertEqual(data["checks"][-1]["status"], "failed")
        self.assertIn("private-access failure", data["error"])
        self.assertIn("ERROR:", progress)

    def test_failed_runtime_state_in_json_stops_before_private_access(self):
        fixture = Fixture()
        fixture.resource(readiness.GATEWAY, "agw-primary")["properties"]["operationalState"] = "Stopped"
        code, data, _, access = self.report(fixture, ("--private-check-shell", "bash"))
        self.assertEqual(code, 1)
        self.assertEqual(data["checks"][-1]["status"], "failed")
        self.assertIn("Not Running", data["error"])
        access.assert_not_called()
        self.assertFalse(fixture.starts())

    def test_public_json_does_not_invoke_private_checks_and_private_requires_them(self):
        code, data, _, access = self.report(Fixture("public"))
        self.assertEqual(code, 0)
        self.assertEqual(data["status"], "passed")
        access.assert_not_called()
        code, data, _, _ = self.report(Fixture())
        self.assertEqual(code, 1)
        self.assertIn("--private-check-shell", data["error"])

    def test_azd_failure_is_json_and_no_environment_values_are_serialized(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(readiness, "environment", side_effect=readiness.ReadinessError("azd unavailable")), \
                patch.object(readiness.sys, "argv", ["lab_readiness.py", "--format", "json"]), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(readiness.main(), 1)
        data = json.loads(stdout.getvalue())
        self.assertEqual(data["checks"][0]["status"], "failed")
        self.assertNotIn("values", data)
        self.assertEqual(data["error"], "azd unavailable")

    def test_private_shell_command_errors_and_timeout_propagate(self):
        for shell in ("powershell", "bash"):
            with patch.object(readiness.shutil, "which", return_value="shell"), \
                    patch.object(readiness.subprocess, "run",
                                 return_value=subprocess.CompletedProcess("shell", 1)) as process:
                with self.assertRaisesRegex(readiness.ReadinessError, "Private Link validation failed"):
                    readiness.private_access(shell)
                self.assertEqual(process.call_args.kwargs["timeout"], 900)
            with patch.object(readiness.shutil, "which", return_value="shell"), \
                    patch.object(readiness.subprocess, "run",
                                 side_effect=subprocess.TimeoutExpired("shell", 900)):
                with self.assertRaisesRegex(readiness.ReadinessError, "timed out"):
                    readiness.private_access(shell)

    def test_running_infrastructure_and_workloads_pass_without_mutation(self):
        for stage in ("Prepare", "Infrastructure", "Workloads"):
            fixture = Fixture()
            fixture.run(stage)
            self.assertFalse(fixture.starts())
            self.assertEqual(any(call[:3] == ["aks", "command", "invoke"] for call in fixture.calls),
                             stage == "Workloads")

    def test_stopped_gateway_or_cluster_fails_before_backend_or_kubernetes_checks(self):
        for kind, name, field, value in (
                (readiness.GATEWAY, "agw-primary", "operationalState", "Stopped"),
                (readiness.AKS, "aks-secondary", "powerState", {"code": "Stopped"})):
            fixture = Fixture()
            fixture.resource(kind, name)["properties"][field] = value
            with self.assertRaisesRegex(readiness.ReadinessError, "Not Running/Succeeded.*StartResources"):
                fixture.run()
            self.assertFalse(fixture.starts())
            self.assertFalse(any("show-backend-health" in call or "invoke" in call for call in fixture.calls))

    def test_explicit_start_dispatches_all_four_before_sleep_and_never_duplicates(self):
        fixture = Fixture()
        for resource in fixture.resources.values():
            if resource["type"] == readiness.AKS:
                resource["properties"]["powerState"]["code"] = "Stopped"
            elif resource["type"] == readiness.GATEWAY:
                resource["properties"]["operationalState"] = "Stopped"
        fixture.run("Prepare", start=True)
        self.assertEqual(len(fixture.starts()), 4)
        self.assertLess(max(fixture.calls.index(call) for call in fixture.starts()), fixture.calls.index(["sleep"]))

    def test_timeout_and_transitions_do_not_resubmit_start(self):
        for starting in (False, True):
            fixture = Fixture()
            fixture.auto_start = False
            properties = fixture.resource(readiness.GATEWAY, "agw-primary")["properties"]
            properties["operationalState"] = "Starting" if starting else "Stopped"
            with self.assertRaisesRegex(readiness.ReadinessError, "timed out"):
                fixture.run("Prepare", start=True)
            self.assertEqual(len(fixture.starts()), 0 if starting else 1)

    def test_stopping_finishes_before_start(self):
        fixture = Fixture()
        target = fixture.resource(readiness.GATEWAY, "agw-primary")
        target["properties"]["operationalState"] = "Stopped"
        fixture.sequences[target["id"].lower()] = [("Succeeded", "Stopping"), ("Succeeded", "Stopped")]
        with self.assertRaisesRegex(readiness.ReadinessError, "timed out"):
            fixture.run("Prepare", start=True)
        self.assertEqual(len(fixture.starts()), 1)
        self.assertGreater(fixture.calls.index(fixture.starts()[0]), fixture.calls.index(["sleep"]))

    def test_failed_unknown_and_missing_states_never_start(self):
        for state, power in (("Failed", "Stopped"), ("Canceled", "Running"), ("Mystery", "Running"),
                             ("Succeeded", None), ("Succeeded", "Unknown")):
            fixture = Fixture()
            target = fixture.resource(readiness.GATEWAY, "agw-secondary")["properties"]
            target.update(provisioningState=state, operationalState=power)
            fixture.resource(readiness.AKS, "aks-primary")["properties"]["powerState"]["code"] = "Stopped"
            with self.assertRaisesRegex(readiness.ReadinessError, "failed/unsupported"):
                fixture.run("Prepare", start=True)
            self.assertFalse(fixture.starts())

    def test_first_provision_allows_missing_compute_but_tests_require_outputs(self):
        fixture = Fixture()
        fixture.resources = {}
        fixture.run("Prepare", start=True)
        self.assertFalse(fixture.starts())
        fixture.env.pop("AKS_PRIMARY_NAME")
        with self.assertRaisesRegex(readiness.ReadinessError, "AKS_PRIMARY_NAME"):
            fixture.run()

    def test_scope_tags_ambiguity_and_regional_drift_never_start(self):
        for mutation in ("tag", "group", "subscription", "duplicate-region", "extra"):
            fixture = Fixture()
            target = fixture.resource(readiness.GATEWAY, "agw-primary")
            if mutation == "tag":
                target["tags"]["azd-env-name"] = "another-env"
            elif mutation in ("group", "subscription"):
                target["id"] = target["id"].replace("rg-test" if mutation == "group" else "test-sub", "other")
            elif mutation == "duplicate-region":
                target["location"] = "centralus"
            else:
                fixture.add(readiness.GATEWAY, "extra", "westus3", {"operationalState": "Stopped"})
            with self.assertRaises(readiness.ReadinessError):
                fixture.run("Prepare", start=True)
            self.assertFalse(fixture.starts())

    def test_swapped_output_and_external_id_fail_before_mutation(self):
        fixture = Fixture()
        fixture.env["APP_GATEWAY_PRIMARY_ID"], fixture.env["APP_GATEWAY_SECONDARY_ID"] = (
            fixture.env["APP_GATEWAY_SECONDARY_ID"], fixture.env["APP_GATEWAY_PRIMARY_ID"])
        with self.assertRaisesRegex(readiness.ReadinessError, "swapped or stale"):
            fixture.run(start=True)
        fixture.env["APP_GATEWAY_PRIMARY_ID"] = "https://not-azure.invalid/"
        fixture.calls.clear()
        with self.assertRaisesRegex(readiness.ReadinessError, "outside"):
            fixture.run(start=True)
        self.assertFalse(fixture.starts())
        self.assertFalse(any("https://not-azure.invalid/" in argument for call in fixture.calls for argument in call))

    def test_mixed_case_arm_scope_is_valid(self):
        fixture = Fixture()
        for resource in fixture.resources.values():
            resource["id"] = resource["id"].replace("resourceGroups", "resourcegroups")
        fixture.run()

    def test_public_topology_does_not_require_or_start_retained_gateways(self):
        fixture = Fixture("public")
        for name in ("agw-primary", "agw-secondary"):
            fixture.resource(readiness.GATEWAY, name)["properties"]["operationalState"] = "Stopped"
        fixture.run("Workloads", start=True)
        self.assertFalse(fixture.starts())
        self.assertFalse(any("show-backend-health" in call for call in fixture.calls))

    def test_node_pool_state_and_capacity_are_required(self):
        for field, value in (("powerState", {"code": "Stopped"}), ("provisioningState", "Failed"),
                             ("mode", "User"), ("count", 0)):
            fixture = Fixture()
            fixture.resource(readiness.AKS, "aks-primary")["properties"]["agentPoolProfiles"][0][field] = value
            with self.assertRaises(readiness.ReadinessError):
                fixture.run()

    def test_management_and_route_failures_are_not_success_shaped(self):
        for target, field, value in (
                ("endpoint", "enabledState", "Disabled"), ("route", "enabledState", "Disabled"),
                ("route", "forwardingProtocol", "HttpOnly"), ("route", "originGroup", {"id": "/wrong"}),
                ("profile", "provisioningState", "Failed"), ("group", "healthProbeSettings", {})):
            fixture = Fixture()
            getattr(fixture, target)["properties"][field] = value
            with self.assertRaises(readiness.ReadinessError):
                fixture.run()

    def test_apim_topology_and_backend_health_are_mandatory(self):
        for mutation in ("network", "region", "vip", "backend", "unhealthy", "unknown", "empty"):
            fixture = Fixture()
            apim = fixture.resource("Microsoft.ApiManagement/service", "apim-test")
            if mutation == "network":
                apim["properties"]["virtualNetworkType"] = "External"
            elif mutation == "region":
                apim["properties"]["additionalLocations"] = []
            elif mutation == "vip":
                apim["properties"]["privateIPAddresses"] = []
            elif mutation == "backend":
                fixture.resource(readiness.GATEWAY, "agw-primary")["properties"]["backendAddressPools"] = []
            else:
                fixture.health_state = {"unhealthy": "Unhealthy", "unknown": "Unknown", "empty": None}[mutation]
            with self.assertRaises(readiness.ReadinessError):
                fixture.run()

    def test_disabled_origin_or_tls_name_check_is_rejected(self):
        for field, value in (("enabledState", "Disabled"), ("enforceCertificateNameCheck", False),
                             ("hostName", "stale.example.org"), ("originHostHeader", "wrong.example.org")):
            fixture = Fixture()
            fixture.resources[(fixture.group["id"] + "/origins/us").lower()]["properties"][field] = value
            with self.assertRaisesRegex(readiness.ReadinessError, "Host/TLS"):
                fixture.run()

    def test_kubernetes_nodes_must_be_ready_schedulable_and_present(self):
        for mutation in ("missing", "not-ready", "cordoned"):
            fixture = Fixture()
            if mutation == "missing":
                fixture.nodes.pop()
            elif mutation == "not-ready":
                fixture.nodes[0]["status"]["conditions"][0]["status"] = "False"
            else:
                fixture.nodes[0]["spec"]["unschedulable"] = True
            with self.assertRaisesRegex(readiness.ReadinessError, "nodes Ready"):
                fixture.run("Workloads")

    def test_workloads_require_current_rollout_ilb_and_all_ready_endpoints(self):
        for mutation in ("zero", "rollout", "generation", "ip", "endpoints", "missing", "terminating"):
            items = copy.deepcopy(Fixture().items)
            if mutation == "zero":
                items[0]["spec"]["replicas"] = 0
            elif mutation == "rollout":
                items[0]["status"]["readyReplicas"] = 1
            elif mutation == "generation":
                items[0]["status"]["observedGeneration"] = 1
            elif mutation == "ip":
                items[1]["status"]["loadBalancer"]["ingress"][0]["ip"] = "10.0.0.99"
            elif mutation == "endpoints":
                items[2]["endpoints"].pop()
            elif mutation == "missing":
                items.pop(1)
            else:
                items[2]["endpoints"][0]["conditions"]["terminating"] = True
            with self.assertRaises(readiness.ReadinessError):
                readiness.Readiness.workload(items, "10.10.2.10", "aks-test")

    def test_cli_errors_invalid_json_timeouts_and_empty_backend_health_fail(self):
        with patch.object(readiness, "command", return_value=""):
            with self.assertRaisesRegex(readiness.ReadinessError, "valid JSON"):
                readiness.json_command(["network", "application-gateway", "show-backend-health"])
        with patch.object(readiness.shutil, "which", return_value="az"), \
                patch.object(readiness.subprocess, "run", side_effect=subprocess.TimeoutExpired("az", 1)):
            with self.assertRaisesRegex(readiness.ReadinessError, "timed out"):
                readiness.command("az", ["account", "show"])
        with patch.object(readiness.shutil, "which", return_value="az"), \
                patch.object(readiness.subprocess, "run", return_value=subprocess.CompletedProcess("az", 1, "", "sensitive")):
            with self.assertRaisesRegex(readiness.ReadinessError, "scoped permissions") as error:
                readiness.command("az", ["account", "show"])
            self.assertNotIn("sensitive", str(error.exception))

    def test_pending_run_command_is_polled_without_reinvocation(self):
        fixture = Fixture()
        command_id = "0123456789abcdef0123456789abcdef"
        with patch.object(readiness, "command", return_value=f"command id: {command_id}, started at: now") as invoke, \
                patch.object(readiness, "json_command", side_effect=[
                    {"exitCode": None, "provisioningState": "Running"},
                    {"exitCode": 0, "logs": "{}"},
                ]) as result, patch.object(readiness.time, "sleep"):
            actual = readiness.Readiness(fixture.env).aks_query("aks-primary", "kubectl get nodes -o json")
        self.assertEqual(actual["exitCode"], 0)
        self.assertEqual(invoke.call_count, 1)
        self.assertEqual(result.call_count, 2)
        self.assertTrue(all(call.args[0][:3] == ["aks", "command", "result"] for call in result.call_args_list))
        self.assertTrue(all(command_id in call.args[0] for call in result.call_args_list))

    def test_failed_malformed_or_incomplete_run_command_is_not_health_evidence(self):
        for raw in ('{"exitCode":7}', '{"logs":"incomplete"}', '{"exitCode":false}', 'unexpected'):
            with patch.object(readiness, "command", return_value=raw):
                with self.assertRaises(readiness.ReadinessError):
                    readiness.Readiness(Fixture().env).aks_query("aks-primary", "kubectl get nodes -o json")

    def test_supported_node_pool_transition_is_awaited_only_with_opt_in(self):
        fixture = Fixture()
        pool = fixture.resource(readiness.AKS, "aks-primary")["properties"]["agentPoolProfiles"][0]
        pool["provisioningState"] = "Updating"
        with self.assertRaisesRegex(readiness.ReadinessError, "node pool"):
            fixture.run("Prepare")
        with self.assertRaisesRegex(readiness.ReadinessError, "timed out"):
            fixture.run("Prepare", start=True)
        self.assertFalse(fixture.starts())

    def test_partial_or_empty_backend_health_is_never_accepted(self):
        fixture = Fixture()
        pool_id = fixture.env["APP_GATEWAY_PRIMARY_ID"] + "/backendAddressPools/regional-apim"
        for health in ({}, [], {"backendAddressPools": []}, {"backendAddressPools": [
                {"backendAddressPool": {"id": pool_id}, "backendHttpSettingsCollection": []}]},
                {"backendAddressPools": [{"backendAddressPool": {"id": pool_id},
                                         "backendHttpSettingsCollection": [{"servers": []}]}]}):
            fixture.health_payload = health
            with self.assertRaises(readiness.ReadinessError):
                fixture.run()

    def test_duplicate_discovery_and_multi_group_new_environment_refuse_start(self):
        for duplicate in (True, False):
            fixture = Fixture()
            original = fixture.json_command
            if duplicate:
                def discover(args, timeout=300):
                    result = original(args, timeout)
                    if args[:2] == ["resource", "list"]:
                        result.append(copy.deepcopy(result[0]))
                    return result
                fixture.json_command = discover
            else:
                fixture.env.pop("AZURE_RESOURCE_GROUP")
                target = fixture.resource(readiness.GATEWAY, "agw-primary")
                target["id"] = target["id"].replace("rg-test", "rg-other")
                target["resourceGroup"] = "rg-other"
            with self.assertRaises(readiness.ReadinessError):
                fixture.run("Prepare", start=True)
            self.assertFalse(fixture.starts())

    def test_slow_state_query_cannot_pass_at_deadline_or_start_more_resources(self):
        fixture = Fixture()
        original = fixture.json_command
        def delayed(args, timeout=300):
            result = original(args, timeout)
            if args[0] == "rest":
                fixture.clock += 30
            return result
        fixture.json_command = delayed
        with self.assertRaisesRegex(readiness.ReadinessError, "timed out"):
            fixture.run("Prepare", start=True)
        self.assertFalse(fixture.starts())

    def test_failed_pool_is_not_hidden_by_another_pool_transition(self):
        fixture = Fixture()
        pools = fixture.resource(readiness.AKS, "aks-primary")["properties"]["agentPoolProfiles"]
        pools[0]["provisioningState"] = "Updating"
        pools.append({"name": "failed", "mode": "User", "count": 1,
                      "powerState": {"code": "Running"}, "provisioningState": "Failed"})
        with self.assertRaisesRegex(readiness.ReadinessError, "node pool failed"):
            fixture.run("Prepare", start=True)
        self.assertEqual(fixture.clock, 0)
        self.assertFalse(fixture.starts())

    def test_environment_switch_is_detected_before_azure_queries(self):
        with patch.object(readiness, "environment", return_value=Fixture().env), \
                patch.object(readiness.sys, "argv", ["lab_readiness.py", "--environment-name", "another-env"]), \
                patch.object(readiness, "json_command") as azure, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(readiness.main(), 1)
        azure.assert_not_called()


if __name__ == "__main__":
    unittest.main()
