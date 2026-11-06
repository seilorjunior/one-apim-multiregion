"""Scoped lab readiness checks. Startup is opt-in; no purchases or link approvals."""
import argparse
import contextlib
import datetime as dt
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
AKS = "Microsoft.ContainerService/managedClusters"
GATEWAY = "Microsoft.Network/applicationGateways"
VERSIONS = {AKS: "2024-10-01", GATEWAY: "2024-05-01"}
RECOVERY = (
    "Run scripts/powershell/Test-Readiness.ps1 -StartResources "
    "(Bash: scripts/bash/Test-Readiness.sh --start-resources) to explicitly "
    "resume existing AKS/gateway charges, or inspect Azure operations before retrying."
)


class ReadinessError(RuntimeError):
    pass


class Report:
    def __init__(self, stage):
        self.started = time.monotonic()
        self.data = {
            "schemaVersion": 1, "stage": stage, "status": "running",
            "startedAtUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "checks": [], "error": None,
            "evidenceBoundary": "Prerequisites only; run Test-Lab and Test-Origins for runtime TLS/API and fresh metrics.",
        }

    @contextlib.contextmanager
    def check(self, name):
        started = time.monotonic()
        item = {"name": name, "status": "running", "durationSeconds": 0, "error": None}
        self.data["checks"].append(item)
        print(f"START: {name} (Azure queries may take several minutes).", flush=True)
        try:
            yield
        except (ReadinessError, OSError) as error:
            item.update(status="failed", error=str(error))
            raise
        else:
            item["status"] = "passed"
        finally:
            item["durationSeconds"] = round(time.monotonic() - started, 3)
            print(f"{item['status'].upper()}: {name} ({item['durationSeconds']:.1f}s).", flush=True)

    def finish(self, error=None):
        self.data.update(
            status="failed" if error else "passed", error=str(error) if error else None,
            durationSeconds=round(time.monotonic() - self.started, 3),
            completedAtUtc=dt.datetime.now(dt.timezone.utc).isoformat(),
        )
        return self.data


def command(program, arguments, timeout=300):
    executable = shutil.which(program)
    if not executable:
        raise ReadinessError(f"Required command not found: {program}.")
    try:
        result = subprocess.run(
            [executable, *arguments], capture_output=True, text=True,
            encoding="utf-8", cwd=ROOT, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise ReadinessError(
            f"{program} command timed out; inspect the scoped Azure operation before retrying."
        ) from None
    if result.returncode:
        # Neither azd environment values nor arbitrary provider responses belong in logs.
        raise ReadinessError(
            f"{program} {' '.join(arguments[:3])} failed (exit {result.returncode}). "
            "Check Azure login, scoped permissions and the resource activity log."
        )
    return result.stdout


def json_command(arguments, timeout=300):
    raw = command("az", [*arguments, "--output", "json", "--only-show-errors"], timeout)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        raise ReadinessError("Azure CLI did not return valid JSON readiness evidence.") from None


def environment():
    return dict(re.findall(
        r'^([A-Z][A-Z0-9_]*)="(.*)"\r?$',
        command("azd", ["env", "get-values"]), re.MULTILINE,
    ))


def require(values, *names):
    for name in names:
        if not values.get(name, "").strip():
            raise ReadinessError(f"Missing azd value {name}; provision the selected environment first.")


def location(value):
    return value.replace(" ", "").lower()


def same_id(left, right):
    return isinstance(left, str) and left.lower() == right.lower()


def succeeded(resource, label):
    state = resource.get("properties", {}).get("provisioningState")
    if state != "Succeeded":
        raise ReadinessError(f"{label} is not Succeeded (state={state!r}).")


class Readiness:
    def __init__(self, values):
        require(values, "AZURE_ENV_NAME", "AZURE_SUBSCRIPTION_ID")
        if not re.fullmatch(r"[a-z][a-z0-9-]{2,23}", values["AZURE_ENV_NAME"]):
            raise ReadinessError("Invalid selected azd environment name.")
        self.values = values
        self.subscription = values["AZURE_SUBSCRIPTION_ID"]
        self.mode = values.get("APP_INGRESS_MODE", "public")
        if self.mode not in ("public", "private"):
            raise ReadinessError("APP_INGRESS_MODE must be public or private.")

    def identifier(self, kind, name):
        require(self.values, "AZURE_RESOURCE_GROUP")
        if not re.fullmatch(r"[a-zA-Z0-9_.()-]+", name):
            raise ReadinessError("Invalid resource name in azd outputs.")
        return (
            f"/subscriptions/{self.subscription}/resourceGroups/"
            f"{self.values['AZURE_RESOURCE_GROUP']}/providers/{kind}/{name}"
        )

    def read(self, identifier, version, timeout=300):
        prefix = (
            f"/subscriptions/{self.subscription}/resourceGroups/"
            f"{self.values.get('AZURE_RESOURCE_GROUP', '')}/providers/"
        )
        if (not re.fullmatch(r"/subscriptions/[^/?#]+/resourceGroups/[^/?#]+/providers/[a-zA-Z0-9_./()-]+", identifier, re.IGNORECASE)
                or (self.values.get("AZURE_RESOURCE_GROUP") and not identifier.lower().startswith(prefix.lower()))
                or not identifier.lower().startswith(f"/subscriptions/{self.subscription}/resourcegroups/".lower())):
            raise ReadinessError("Refusing to read a resource outside the selected subscription/resource group.")
        resource = json_command([
            "rest", "--method", "get", "--url", f"{identifier}?api-version={version}",
        ], timeout=timeout)
        if not isinstance(resource, dict) or not same_id(resource.get("id"), identifier):
            raise ReadinessError("Azure resource response does not match the requested ID.")
        return resource

    def validate_target(self, target):
        kind = target["type"]
        identifier = target["id"]
        scope = re.fullmatch(
            r"/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/"
            + re.escape(kind) + r"/([a-zA-Z0-9_.()-]+)", identifier, re.IGNORECASE,
        )
        if (not scope or scope[1].lower() != self.subscription.lower()
                or scope[3].lower() != target["name"].lower()
                or target.get("tags", {}).get("azd-env-name") != self.values["AZURE_ENV_NAME"]):
            raise ReadinessError("Resource scope/tag does not match the selected environment.")
        group = self.values.get("AZURE_RESOURCE_GROUP")
        if group and scope[2].lower() != group.lower():
            raise ReadinessError("Resource group does not match the selected environment.")
        if target.get("resourceGroup", scope[2]).lower() != scope[2].lower():
            raise ReadinessError("Resource discovery group and ID disagree.")
        return scope[2]

    def targets(self, prepare):
        kinds = (AKS, GATEWAY) if self.mode == "private" else (AKS,)
        expected = {}
        if prepare:
            discovered = json_command([
                "resource", "list", "--subscription", self.subscription,
                "--tag", f"azd-env-name={self.values['AZURE_ENV_NAME']}",
            ])
            if not isinstance(discovered, list):
                raise ReadinessError("Resource discovery did not return a list.")
            targets = [item for item in discovered if item.get("type") in kinds]
        else:
            targets = []
            for key in ("PRIMARY", "SECONDARY"):
                require(self.values, f"AKS_{key}_NAME", f"AZURE_{key}_LOCATION")
                identifier = self.identifier(AKS, self.values[f"AKS_{key}_NAME"])
                expected[identifier.lower()] = location(self.values[f"AZURE_{key}_LOCATION"])
                targets.append({"id": identifier, "type": AKS})
                if self.mode == "private":
                    require(self.values, f"APP_GATEWAY_{key}_ID")
                    identifier = self.values[f"APP_GATEWAY_{key}_ID"]
                    expected[identifier.lower()] = location(self.values[f"AZURE_{key}_LOCATION"])
                    targets.append({"id": identifier, "type": GATEWAY})
            targets = [dict(self.read(item["id"], VERSIONS[item["type"]]), type=item["type"])
                       for item in targets]
        ids = [item["id"].lower() for item in targets]
        if len(set(ids)) != len(ids):
            raise ReadinessError("Duplicate AKS/gateway resource IDs; refusing ambiguous scope.")
        groups = {self.validate_target(item).lower() for item in targets}
        if len(groups) > 1:
            raise ReadinessError("Environment AKS/gateways span multiple resource groups.")
        regions = {
            location(self.values.get("AZURE_PRIMARY_LOCATION") or self.values.get("AZURE_LOCATION", "")),
            location(self.values.get("AZURE_SECONDARY_LOCATION", "")),
        }
        if len(regions) != 2 or "" in regions:
            raise ReadinessError("Two distinct configured Azure regions are required.")
        for kind in kinds:
            members = [item for item in targets if item["type"] == kind]
            member_regions = [location(item.get("location", "")) for item in members]
            if (len(members) > 2 or len(set(member_regions)) != len(member_regions)
                    or any(region not in regions for region in member_regions)):
                raise ReadinessError("Ambiguous resource count/region; refusing readiness or startup.")
        for item in targets:
            if not prepare and location(item.get("location", "")) != expected[item["id"].lower()]:
                raise ReadinessError("Regional resource outputs are swapped or stale.")
        if prepare and not targets:
            print("No existing environment AKS/gateways; Bicep can create them.", flush=True)
        return targets

    @staticmethod
    def pools(cluster, allow_pending=False):
        pools = cluster["properties"].get("agentPoolProfiles") or []
        if not pools or not any(p.get("mode") == "System" and p.get("count", 0) > 0 for p in pools):
            raise ReadinessError(f"AKS {cluster['name']} has no configured System nodes.")
        pending = False
        for pool in pools:
            state = pool.get("provisioningState")
            power = (pool.get("powerState") or {}).get("code")
            if (allow_pending and state in ("Starting", "Stopping", "Updating", "Creating", "Scaling")
                    and power in ("Running", "Stopped")):
                pending = True
                continue
            if (pool.get("provisioningState") != "Succeeded"
                    or (pool.get("powerState") or {}).get("code") != "Running"
                    or pool.get("count", 0) < 1):
                raise ReadinessError(
                    f"AKS {cluster['name']} node pool {pool.get('name')} is not Running/Succeeded "
                    "with positive capacity. Inspect the node-pool operation."
                )
        return not pending

    def compute(self, prepare=False, start=False, wait_seconds=1800):
        targets = self.targets(prepare)
        deadline = time.monotonic() + wait_seconds
        requested = set()
        while targets:
            pending = []
            ready = []
            for target in targets:
                if time.monotonic() >= deadline:
                    raise ReadinessError(f"Compute readiness timed out after {wait_seconds}s. {RECOVERY}")
                kind = target["type"]
                resource = self.read(target["id"], VERSIONS[kind],
                                     timeout=max(1, min(300, deadline - time.monotonic())))
                self.validate_target(dict(resource, type=kind))
                properties = resource["properties"]
                state = properties.get("provisioningState")
                power = ((properties.get("powerState") or {}).get("code") if kind == AKS
                         else properties.get("operationalState"))
                valid_power = ("Running", "Stopped") if kind == AKS else ("Running", "Stopped", "Starting", "Stopping")
                if state not in ("Succeeded", "Starting", "Stopping", "Updating", "Creating") or power not in valid_power:
                    raise ReadinessError(
                        f"{target['name']} has failed/unsupported state {power!r}/{state!r}; "
                        "inspect Azure operations, do not restart blindly."
                    )
                print(f"{target['name']}: {power}/{state}.", flush=True)
                if power == "Running" and state == "Succeeded":
                    if kind == AKS and not self.pools(resource, allow_pending=start):
                        pending.append((target, power, state))
                        continue
                    ready.append(dict(resource, type=kind))
                else:
                    pending.append((target, power, state))
            if time.monotonic() >= deadline:
                raise ReadinessError(f"Compute readiness timed out after {wait_seconds}s. {RECOVERY}")
            if not pending:
                return ready
            if not start:
                names = ", ".join(item[0]["name"] for item in pending)
                raise ReadinessError(f"Not Running/Succeeded: {names}. {RECOVERY}")
            for target, power, state in pending:
                if time.monotonic() >= deadline:
                    raise ReadinessError(f"Compute readiness timed out after {wait_seconds}s. {RECOVERY}")
                identifier = target["id"]
                if power == "Stopped" and state == "Succeeded" and identifier not in requested:
                    print(f"WARNING: Starting {target['name']}; running charges resume.", flush=True)
                    group = self.validate_target(target)
                    if target["type"] == AKS:
                        command("az", [
                            "aks", "start", "--subscription", self.subscription,
                            "--resource-group", group, "--name", target["name"],
                            "--no-wait", "--output", "none", "--only-show-errors",
                        ], timeout=max(1, min(300, deadline - time.monotonic())))
                    else:
                        command("az", [
                            "network", "application-gateway", "start", "--subscription", self.subscription,
                            "--resource-group", group, "--name", target["name"],
                            "--no-wait", "--output", "none", "--only-show-errors",
                        ], timeout=max(1, min(300, deadline - time.monotonic())))
                    requested.add(identifier)
            time.sleep(min(15, max(0, deadline - time.monotonic())))
        return []

    def routing(self):
        require(self.values, "APIM_NAME", "AZURE_FRONT_DOOR_PROFILE", "AZURE_FRONT_DOOR_ENDPOINT")
        apim = self.read(self.identifier("Microsoft.ApiManagement/service", self.values["APIM_NAME"]), "2024-05-01")
        succeeded(apim, "APIM")
        properties = apim["properties"]
        if properties.get("virtualNetworkType") != ("Internal" if self.mode == "private" else "External"):
            raise ReadinessError("APIM network mode does not match the selected ingress topology.")
        expected = [location(self.values[f"AZURE_{key}_LOCATION"]) for key in ("PRIMARY", "SECONDARY")]
        additional = properties.get("additionalLocations") or []
        if (location(apim.get("location", "")) != expected[0] or len(additional) != 1
                or location(additional[0].get("location", "")) != expected[1]):
            raise ReadinessError("APIM primary/additional regions do not match environment outputs.")
        if self.mode == "private":
            vips = [properties.get("privateIPAddresses") or [], additional[0].get("privateIPAddresses") or []]
            if any(len(addresses) != 1 for addresses in vips):
                raise ReadinessError("Both Internal APIM regional private VIPs must be available.")
        else:
            vips = [[], []]
        profile_id = self.identifier("Microsoft.Cdn/profiles", self.values["AZURE_FRONT_DOOR_PROFILE"])
        profile = self.read(profile_id, "2024-09-01")
        succeeded(profile, "Front Door profile")
        endpoint_id = f"{profile_id}/afdEndpoints/{self.values['AZURE_FRONT_DOOR_ENDPOINT']}"
        endpoint = self.read(endpoint_id, "2024-09-01")
        succeeded(endpoint, "Front Door endpoint")
        if endpoint["properties"].get("enabledState") != "Enabled":
            raise ReadinessError("Front Door endpoint is disabled.")
        group_name = "regional-apis-private" if self.mode == "private" else "regional-apis"
        if self.values.get("FRONT_DOOR_ORIGIN_GROUP", group_name) != group_name:
            raise ReadinessError("Front Door origin-group outputs are stale.")
        group_id = f"{profile_id}/originGroups/{group_name}"
        group = self.read(group_id, "2024-09-01")
        succeeded(group, "Front Door origin group")
        probe = group["properties"].get("healthProbeSettings") or {}
        if (probe.get("probePath") != "/lab/health/ready" or probe.get("probeProtocol") != "Https"
                or probe.get("probeRequestType") != "HEAD"):
            raise ReadinessError("Front Door regional readiness probe configuration has drifted.")
        route = self.read(f"{endpoint_id}/routes/lab-api", "2024-09-01")
        succeeded(route, "Front Door route")
        config = route["properties"]
        if (config.get("enabledState") != "Enabled" or config.get("forwardingProtocol") != "HttpsOnly"
                or config.get("httpsRedirect") != "Enabled" or config.get("linkToDefaultDomain") != "Enabled"
                or "/*" not in config.get("patternsToMatch", [])
                or not same_id((config.get("originGroup") or {}).get("id"), group_id)):
            raise ReadinessError("Front Door HTTPS route is disabled or points at stale origins.")
        for key, name, addresses in zip(("PRIMARY", "SECONDARY"), ("br", "us"), vips):
            host_key = f"APP_GATEWAY_{key}_HOST" if self.mode == "private" else f"APIM_{key}_HOST"
            require(self.values, host_key)
            origin = self.read(f"{group_id}/origins/{name}", "2024-09-01")
            succeeded(origin, f"Front Door origin {name}")
            config = origin["properties"]
            if (config.get("enabledState") != "Enabled" or config.get("httpsPort") != 443
                    or config.get("enforceCertificateNameCheck") is not True
                    or config.get("hostName") != self.values[host_key]
                    or config.get("originHostHeader") != self.values[host_key]):
                raise ReadinessError(f"Front Door origin {name} has disabled/stale Host/TLS configuration.")
            if self.mode == "private":
                self.backend_health(key, addresses[0])
        print("PASS: APIM regions and enabled Front Door HTTPS routing/probes verified.", flush=True)

    def backend_health(self, key, vip):
        identifier = self.values[f"APP_GATEWAY_{key}_ID"]
        gateway = self.read(identifier, VERSIONS[GATEWAY])
        pools = gateway["properties"].get("backendAddressPools") or []
        configured = [pool for pool in pools if pool.get("name") == "regional-apim"]
        if (len(configured) != 1
                or configured[0].get("properties", {}).get("backendAddresses") != [{"ipAddress": vip}]):
            raise ReadinessError(f"Gateway {key} backend does not match its regional APIM private VIP.")
        health = json_command([
            "network", "application-gateway", "show-backend-health",
            "--subscription", self.subscription, "--resource-group", self.values["AZURE_RESOURCE_GROUP"],
            "--name", gateway["name"],
        ], timeout=300)
        if not isinstance(health, dict):
            raise ReadinessError(f"Gateway {key} returned invalid backend-health JSON.")
        pools = [pool for pool in health.get("backendAddressPools", [])
                 if same_id((pool.get("backendAddressPool") or {}).get("id"), configured[0]["id"])]
        if len(pools) != 1:
            raise ReadinessError(f"Gateway {key} returned no unique regional APIM backend-health evidence.")
        settings = pools[0].get("backendHttpSettingsCollection") or []
        servers = [server for setting in settings for server in setting.get("servers", [])]
        if (not settings or any(not setting.get("servers") for setting in settings)
                or not servers or any(server.get("address") != vip or server.get("health") != "Healthy"
                                      for server in servers)):
            states = [server.get("health") for server in servers]
            raise ReadinessError(
                f"Gateway {key} APIM backend is not Healthy (states={states}). "
                "Inspect show-backend-health probe details, APIM, DNS and TLS; this is not propagation proof."
            )
        print(f"PASS: Gateway {key} regional APIM backend {vip} is Healthy.", flush=True)

    def aks_query(self, name, query):
        scope = [
            "--subscription", self.subscription,
            "--resource-group", self.values["AZURE_RESOURCE_GROUP"], "--name", name,
        ]
        deadline = time.monotonic() + 600
        raw = command("az", [
            "aks", "command", "invoke", *scope, "--command", query,
            "--output", "json", "--only-show-errors",
        ], timeout=600)
        try:
            result = json.loads(raw)
        except json.JSONDecodeError:
            pending = re.search(r"(?m)^command id: ([0-9a-fA-F]{32}), started at:", raw)
            if not pending:
                raise ReadinessError(f"AKS {name} returned an unexpected Run Command response.") from None
            while time.monotonic() < deadline:
                result = json_command([
                    "aks", "command", "result", *scope, "--command-id", pending[1],
                ], timeout=max(1, min(300, deadline - time.monotonic())))
                if not isinstance(result, dict):
                    raise ReadinessError(f"AKS {name} returned invalid Run Command result JSON.")
                if result.get("exitCode") is not None:
                    break
                if result.get("provisioningState") not in ("Accepted", "Creating", "Running", "Updating"):
                    raise ReadinessError(f"AKS {name} Run Command result has no completed exit code.")
                time.sleep(min(5, max(0, deadline - time.monotonic())))
            else:
                raise ReadinessError(f"AKS {name} Run Command readiness timed out after 600s.")
        if time.monotonic() >= deadline:
            raise ReadinessError(f"AKS {name} Run Command readiness timed out after 600s.")
        if (not isinstance(result, dict) or type(result.get("exitCode")) is not int
                or result["exitCode"] != 0
                or result.get("provisioningState") not in (None, "Succeeded")):
            raise ReadinessError(
                f"AKS Run Command failed in {name}; check Run Command/Kubernetes RBAC and namespace resources."
            )
        return result

    def kubernetes(self, cluster, workloads):
        marker = "LAB_WORKLOADS_JSON"
        query = "kubectl get nodes -o json"
        if workloads:
            query += (
                f" && printf '\\n{marker}\\n' && "
                "kubectl get deployments,services,endpointslices -n apim-lab -o json"
            )
        result = self.aks_query(cluster["name"], query)
        if not isinstance(result.get("logs"), str):
            raise ReadinessError(f"AKS {cluster['name']} Run Command returned no readiness logs.")
        try:
            parts = result["logs"].replace("\r\n", "\n").split(f"\n{marker}\n")
            nodes = json.loads(parts[0])["items"]
            workload_data = json.loads(parts[1])["items"] if workloads and len(parts) == 2 else None
        except (KeyError, TypeError, json.JSONDecodeError):
            raise ReadinessError(f"AKS {cluster['name']} returned invalid Kubernetes readiness JSON.") from None
        capacity = sum(pool["count"] for pool in cluster["properties"]["agentPoolProfiles"])
        if (not nodes or len(nodes) < capacity or any(
                node.get("spec", {}).get("unschedulable") is True
                or not any(condition.get("type") == "Ready" and condition.get("status") == "True"
                           for condition in node.get("status", {}).get("conditions", []))
                for node in nodes)):
            raise ReadinessError(f"AKS {cluster['name']} does not have all expected nodes Ready and schedulable.")
        if workloads:
            if workload_data is None:
                raise ReadinessError("AKS workload readiness evidence is missing.")
            key = "PRIMARY" if cluster["name"] == self.values["AKS_PRIMARY_NAME"] else "SECONDARY"
            require(self.values, f"BACKEND_{key}_IP")
            self.workload(workload_data, self.values[f"BACKEND_{key}_IP"], cluster["name"])
        print(f"PASS: {cluster['name']} nodes" + (" and lab-api workloads" if workloads else "") + " ready.", flush=True)

    @staticmethod
    def workload(items, ip, name):
        def one(kind):
            matches = [item for item in items if item.get("kind") == kind
                       and item.get("metadata", {}).get("name") == "lab-api"]
            if len(matches) != 1:
                raise ReadinessError(f"{name}: expected exactly one lab-api {kind}; run Deploy-LabApi.")
            return matches[0]
        deployment = one("Deployment")
        replicas = deployment.get("spec", {}).get("replicas", 0)
        status = deployment.get("status", {})
        if (type(replicas) is not int or replicas < 1
                or status.get("observedGeneration", -1) < deployment["metadata"].get("generation", 0)
                or any(status.get(field, 0) != replicas for field in
                       ("replicas", "updatedReplicas", "readyReplicas", "availableReplicas"))):
            raise ReadinessError(f"{name}: lab-api rollout/replicas are not fully ready; inspect pods/events.")
        service = one("Service")
        ingress = service.get("status", {}).get("loadBalancer", {}).get("ingress") or []
        if (service.get("spec", {}).get("type") != "LoadBalancer"
                or len(ingress) != 1 or ingress[0].get("ip") != ip
                or not any(port.get("port") == 443 for port in service.get("spec", {}).get("ports", []))):
            raise ReadinessError(f"{name}: lab-api HTTPS Internal Load Balancer does not have expected IP {ip}.")
        slices = [item for item in items if item.get("kind") == "EndpointSlice"
                  and item.get("metadata", {}).get("labels", {}).get("kubernetes.io/service-name") == "lab-api"]
        endpoints = [endpoint for item in slices for endpoint in item.get("endpoints", [])]
        ready_pods = {
            endpoint.get("targetRef", {}).get("uid") for endpoint in endpoints
            if endpoint.get("conditions", {}).get("ready") is True
            and endpoint.get("conditions", {}).get("terminating") is not True
            and endpoint.get("addresses")
        }
        ready_pods.discard(None)
        if len(ready_pods) < replicas:
            raise ReadinessError(f"{name}: lab-api does not have a ready service endpoint for every replica.")

    def run(self, stage, start, wait_seconds, report=None):
        report = report or Report(stage)
        with report.check("Subscription and authentication"):
            account = json_command(["account", "show", "--subscription", self.subscription])
            if account.get("state") != "Enabled" or not same_id(account.get("id"), self.subscription):
                raise ReadinessError("Azure subscription login is disabled or mismatched.")
        with report.check("AKS, node pools and Application Gateway runtime"):
            targets = self.compute(stage == "Prepare", start, wait_seconds)
        if stage != "Prepare":
            with report.check("APIM, Front Door routing and regional gateway backend health"):
                self.routing()
            if stage == "Workloads":
                for target in targets:
                    if target["type"] == AKS:
                        with report.check(f"Kubernetes nodes and lab-api: {target['name']}"):
                            self.kubernetes(target, True)
        print(
            f"PASS: {stage} readiness checks. This is not fresh Front Door metric or end-to-end TLS evidence.",
            flush=True,
        )


def private_access(shell):
    if shell == "powershell":
        args = [
            "-NoProfile", "-NonInteractive", "-Command",
            "& { param($Common) . $Common; $values = Get-LabEnvironment; Invoke-LabPrivateReadiness $values }",
            str(ROOT / "scripts" / "powershell" / "Lab.Common.ps1"),
        ]
        program = "pwsh"
    else:
        args = [
            "-c", 'source "$1"; lab_load_environment; lab_private_readiness',
            "--", (ROOT / "scripts" / "bash" / "Lab.Common.sh").as_posix(),
        ]
        program = "bash"
    executable = shutil.which(program)
    if not executable:
        raise ReadinessError(f"Required private-access validation tool not found: {program}.")
    try:
        result = subprocess.run(
            [executable, *args], stdout=sys.stderr, stderr=sys.stderr, cwd=ROOT, timeout=900,
        )
    except subprocess.TimeoutExpired:
        raise ReadinessError("Certificate/vault/Private Link validation timed out after 900s.") from None
    if result.returncode:
        raise ReadinessError(
            "Certificate/vault/Private Link validation failed. Inspect stderr diagnostics; "
            "no runtime health or approval is assumed."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=("Prepare", "Infrastructure", "Workloads"), default="Workloads")
    parser.add_argument("--start-resources", action="store_true")
    parser.add_argument("--environment-name")
    parser.add_argument("--wait-seconds", type=int, default=1800)
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--private-check-shell", choices=("powershell", "bash"))
    args = parser.parse_args()
    if not 30 <= args.wait_seconds <= 7200:
        parser.error("--wait-seconds must be in 30..7200.")
    report = Report(args.stage)
    failure = None
    output = contextlib.redirect_stdout(sys.stderr) if args.format == "json" else contextlib.nullcontext()
    with output:
        try:
            with report.check("Selected azd environment"):
                values = environment()
                if args.environment_name and values.get("AZURE_ENV_NAME") != args.environment_name:
                    raise ReadinessError("Selected azd environment changed during the operation; reload before retrying.")
                checker = Readiness(values)
            checker.run(args.stage, args.start_resources, args.wait_seconds, report)
            if args.stage != "Prepare" and checker.mode == "private":
                if args.private_check_shell:
                    with report.check("Certificate, private vault topology and scoped Private Link approval"):
                        private_access(args.private_check_shell)
                elif args.format == "json":
                    raise ReadinessError("Private JSON reports require --private-check-shell to include all access gates.")
        except (ReadinessError, OSError) as error:
            failure = error
            print(f"ERROR: {error}", file=sys.stderr)
    result = report.finish(failure)
    if args.format == "json":
        print(json.dumps(result, ensure_ascii=True))
    else:
        print(f"CORE SUMMARY: {result['status'].upper()} {args.stage} ({result['durationSeconds']:.1f}s).")
    return 1 if failure else 0


if __name__ == "__main__":
    sys.exit(main())
