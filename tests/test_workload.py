"""Offline YAML contract checks; requires PyYAML only on the validation machine."""
import json
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class WorkloadTests(unittest.TestCase):
    def setUp(self):
        source = (ROOT / "src" / "lab-api" / "workload.yaml").read_text()
        self.documents = {
            item["kind"]: item for item in yaml.safe_load_all(source)
        }

    def test_internal_service(self):
        service = self.documents["Service"]
        annotations = service["metadata"]["annotations"]
        self.assertEqual(
            annotations["service.beta.kubernetes.io/azure-load-balancer-internal"],
            "true",
        )
        self.assertEqual(service["spec"]["ports"][0]["port"], 443)
        self.assertEqual(service["spec"]["ports"][0]["targetPort"], 8443)
        self.assertEqual(
            service["spec"]["loadBalancerSourceRanges"], ["__APIM_SUBNET__"]
        )

    def test_nginx_and_openapi_paths_match(self):
        config = self.documents["ConfigMap"]["data"]["default.conf"]
        spec = json.loads((ROOT / "src" / "lab-api" / "openapi.json").read_text())
        self.assertEqual(
            set(re.findall(r"location = (\S+) \{", config)),
            set(spec["paths"]),
        )
        self.assertIn("ssl_protocols TLSv1.2 TLSv1.3;", config)
        self.assertIn('add_header X-Lab-Backend-Region "__REGION__" always;', config)
        self.assertIn('"region":"__REGION__"', config)
        self.assertIn("head", spec["paths"]["/health/ready"])
        for operation in spec["paths"]["/health/ready"].values():
            self.assertIn("503", operation["responses"])

    def test_pod_security_and_secret_mount(self):
        pod = self.documents["Deployment"]["spec"]["template"]["spec"]
        self.assertEqual(
            self.documents["Deployment"]["spec"]["strategy"]["rollingUpdate"],
            {"maxUnavailable": 0, "maxSurge": 1},
        )
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertTrue(pod["securityContext"]["runAsNonRoot"])
        container = pod["containers"][0]
        self.assertEqual(
            self.documents["Deployment"]["spec"]["template"]["metadata"]["annotations"]["checksum/lab-workload"],
            "__WORKLOAD_HASH__",
        )
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(container["readinessProbe"]["httpGet"]["scheme"], "HTTPS")
        self.assertEqual(container["ports"][0]["containerPort"], 8443)
        self.assertEqual(self.documents["Secret"]["type"], "kubernetes.io/tls")
        tls = next(v for v in pod["volumes"] if v["name"] == "tls")
        self.assertEqual(tls["secret"]["defaultMode"], 0o440)

    def test_azd_hooks_reference_existing_scripts(self):
        config = yaml.safe_load((ROOT / "azure.yaml").read_text())
        self.assertEqual(config["infra"]["provider"], "bicep")
        for hook in ("preprovision", "postprovision"):
            for platform, shell in (("windows", "pwsh"), ("posix", "sh")):
                item = config["hooks"][hook][platform]
                self.assertEqual(item["shell"], shell)
                self.assertFalse(item["continueOnError"])
                self.assertTrue(item["interactive"])
                script = item["run"].removeprefix("bash ")
                self.assertTrue(ROOT.joinpath(script).is_file())

    def test_disruption_budget_and_soft_topology_spreading(self):
        budget = self.documents["PodDisruptionBudget"]
        self.assertEqual(budget["apiVersion"], "policy/v1")
        self.assertEqual(budget["spec"]["minAvailable"], 1)
        self.assertEqual(budget["spec"]["selector"]["matchLabels"], {"app": "lab-api"})
        pod = self.documents["Deployment"]["spec"]["template"]["spec"]
        constraints = pod["topologySpreadConstraints"]
        self.assertEqual({item["topologyKey"] for item in constraints},
                         {"kubernetes.io/hostname", "topology.kubernetes.io/zone"})
        for item in constraints:
            self.assertEqual(item["maxSkew"], 1)
            self.assertEqual(item["whenUnsatisfiable"], "ScheduleAnyway")
            self.assertEqual(item["labelSelector"]["matchLabels"], {"app": "lab-api"})
        self.assertNotIn("HorizontalPodAutoscaler", self.documents)


if __name__ == "__main__":
    unittest.main()
