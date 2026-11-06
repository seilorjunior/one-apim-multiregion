"""Exercise k6 logic with local stubs; never contact the configured target."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
NODE = shutil.which("node")
K6 = shutil.which("k6")
SCRIPT = ROOT / "tests" / "load" / "lab.js"


@unittest.skipUnless(NODE, "Node is required for offline k6 module tests")
class LoadTests(unittest.TestCase):
    def run_module(self, changes=None, response=None):
        env = {"API_URL": "https://example.invalid/lab", "PRIMARY_REGION": "westus3",
               "SECONDARY_REGION": "centralus", "CONFIRM_LOAD": "yes"}
        env.update(changes or {})
        response = response or {
            "status": 200, "headers": {"X-Lab-Gateway-Region": "westus3"},
            "body": {"region": "westus3", "cluster": "aks-primary", "pod": "api-1"},
        }
        harness = r"""
import fs from 'node:fs';
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
globalThis.__ENV = input.env;
const metrics = {};
let requests = 0;
const http = { get(url, options) {
    requests++;
    if (!url.endsWith('/lab/whoami') || options.timeout !== '10s') throw Error('bad request');
    return {...input.response, json() {
        if (input.response.invalidJson) throw Error('malformed JSON');
        return input.response.body;
    }};
}};
const check = (response, checks) => Object.values(checks).every(fn => fn(response));
const sleep = () => {};
class Rate { constructor(name) {this.name = name;} add(value) {metrics[this.name] = value;} }
globalThis.stubs = {http, check, sleep, Rate};
const source = fs.readFileSync(input.path, 'utf8').replace(/^import .*;\r?$/gm, '');
const module = await import('data:text/javascript;base64,' + Buffer.from(
    'const {http, check, sleep, Rate} = globalThis.stubs;\n' + source).toString('base64'));
module.setup();
module.default();
process.stdout.write(JSON.stringify({options: module.options, metrics, requests}));
"""
        return subprocess.run([NODE, "--input-type=module", "-e", harness],
                              input=json.dumps({"path": str(SCRIPT), "env": env, "response": response}),
                              capture_output=True, text=True, timeout=20)

    def test_bounded_defaults_and_response_locality(self):
        result = self.run_module()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        scenario = output["options"]["scenarios"]["bounded"]
        self.assertEqual(scenario, {"executor": "constant-vus", "vus": 2,
                                   "duration": "60s", "gracefulStop": "15s"})
        self.assertEqual(output["requests"], 1)
        self.assertFalse(output["metrics"]["lab_invalid_response"])
        self.assertEqual(output["options"]["thresholds"]["http_req_duration"],
                         ["p(95)<1500", "p(99)<3000"])
        self.assertEqual(output["options"]["maxRedirects"], 0)
        self.assertFalse(output["options"]["insecureSkipTLSVerify"])
        self.assertIn("p(99)", output["options"]["summaryTrendStats"])

    def test_display_name_headers_match_azure_region_identifiers(self):
        for header, region in (("West US 3", "westus3"), ("Central US", "centralus")):
            with self.subTest(header=header):
                result = self.run_module(response={
                    "status": 200, "headers": {"X-Lab-Gateway-Region": header},
                    "body": {"region": region, "cluster": "aks", "pod": "api"},
                })
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(json.loads(result.stdout)["metrics"]["lab_invalid_response"])

    def test_invalid_configuration_or_missing_consent_cannot_send_requests(self):
        for key, value in (("API_URL", "http://example.invalid/lab"),
                           ("API_URL", "https://user:password@example.invalid/lab"),
                           ("API_URL", "https://example.invalid/lab?secret=1"),
                           ("LOAD_VUS", "51"), ("LOAD_SECONDS", "601"),
                           ("LOAD_VUS", "0"), ("LOAD_P99_MS", "100"),
                           ("PRIMARY_REGION", "centralus"), ("CONFIRM_LOAD", "")):
            with self.subTest(key=key, value=value):
                result = self.run_module({key: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_invalid_json_and_locality_fail_response_metric(self):
        for response in (
                {"status": 200, "headers": {}, "invalidJson": True},
                {"status": 200, "headers": {"X-Lab-Gateway-Region": "centralus"},
                 "body": {"region": "westus3", "cluster": "aks", "pod": "api"}},
                {"status": 504, "headers": {}}):
            with self.subTest(response=response):
                result = self.run_module(response=response)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(json.loads(result.stdout)["metrics"]["lab_invalid_response"])

    @unittest.skipUnless(K6, "Optional local k6 configuration validation")
    def test_k6_inspects_real_module_without_traffic(self):
        env = dict(os.environ, K6_NO_USAGE_REPORT="true")
        result = subprocess.run([K6, "inspect", "--env", "API_URL=https://example.invalid/lab",
                                 "--env", "PRIMARY_REGION=westus3", "--env", "SECONDARY_REGION=centralus",
                                 str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("unknown field", result.stderr)
        self.assertEqual(json.loads(result.stdout)["scenarios"]["bounded"]["vus"], 2)


if __name__ == "__main__":
    unittest.main()
