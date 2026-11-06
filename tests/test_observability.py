"""Offline observability contracts; these do not claim live gateway/log ingestion validation."""
import json
import re
import shutil
import subprocess
import unittest
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class CorrelationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy = ET.parse(ROOT / "infra" / "policies" / "global.xml").getroot()
        documents = yaml.safe_load_all((ROOT / "src" / "lab-api" / "workload.yaml").read_text())
        cls.nginx = next(d for d in documents if d["kind"] == "ConfigMap")["data"]["default.conf"]
        expression = cls.policy.find("inbound/set-variable").attrib["value"]
        cls.expression = expression
        pattern = re.search(r'@"([^"]+)"', expression).group(1)
        cls.guid_pattern = re.compile(pattern.replace(r"\z", r"\Z"))

    def test_untrusted_ids_are_strict_guids_or_replaced(self):
        good = "A1234567-B123-C123-D123-E123456789AB"
        self.assertRegex(good, self.guid_pattern)
        for value in ("", "user@email.test", good + "\n", good + "\r\nInjected: value",
                      good + "," + good, " " + good, good + " ", "a" * 4096,
                      good.replace("-", ""), '";error_log /dev/stdout;#'):
            with self.subTest(value=value[:80]):
                self.assertIsNone(self.guid_pattern.fullmatch(value))
        self.assertIn("candidate.Length == 36", self.expression)
        self.assertIn("candidate.ToLowerInvariant()", self.expression)
        self.assertIn("Guid.NewGuid().ToString()", self.expression)
        self.assertRegex(str(uuid.uuid4()), self.guid_pattern)

    def test_global_policy_initializes_before_access_control_and_backend(self):
        inbound = self.policy.find("inbound")
        self.assertEqual(inbound[0].tag, "set-variable")
        self.assertEqual(inbound[1].tag, "set-header")
        self.assertEqual(inbound[1].attrib["name"], "X-Correlation-ID")
        self.assertIn('context.Variables["labCorrelationId"]', inbound[1].findtext("value"))
        self.assertEqual(self.policy.find("backend/forward-request").attrib["timeout"], "20")

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is required for the .NET regex-engine check")
    def test_dotnet_regex_engine_rejects_header_injection_and_duplicates(self):
        pattern = re.search(r'@"([^"]+)"', self.expression).group(1)
        command = f"""
$pattern = '{pattern}'
$valid = 'A1234567-B123-C123-D123-E123456789AB'
if (-not [regex]::IsMatch($valid, $pattern)) {{ throw 'valid GUID rejected' }}
if (-not [regex]::IsMatch([Guid]::NewGuid().ToString(), $pattern)) {{ throw 'generated GUID rejected' }}
foreach ($invalid in @('', ($valid + "`n"), ($valid + "`r`nInjected: value"), ($valid + ',' + $valid), 'unsafe')) {{
    if ([regex]::IsMatch($invalid, $pattern)) {{ throw 'untrusted header accepted' }}
}}
"""
        result = subprocess.run(
            [shutil.which("pwsh"), "-NoProfile", "-NonInteractive", "-Command", command],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_success_early_rejection_and_error_responses_include_correlation(self):
        for path in ("outbound", "on-error", "inbound/choose/when/return-response"):
            section = self.policy.find(path)
            header = section.find("set-header[@name='X-Correlation-ID']")
            self.assertIsNotNone(header, path)
            self.assertEqual(header.attrib["exists-action"], "override")
            self.assertIn("labCorrelationId", header.findtext("value"))
        self.assertIn("context.RequestId.ToString()", self.policy.findtext("on-error/set-header/value"))
        self.assertEqual(self.policy.find("inbound/choose/when/return-response/set-status").attrib["code"], "403")

    def test_regional_inheritance_and_readiness_guard_are_unchanged(self):
        regional = ET.parse(ROOT / "infra" / "policies" / "regional.xml").getroot()
        for section in ("inbound", "backend", "outbound", "on-error"):
            self.assertEqual(regional.find(section)[0].tag, "base")
        guard = regional.find("outbound/choose/when")
        self.assertIn("readiness-get", guard.attrib["condition"])
        self.assertIn("X-Lab-Backend-Region", guard.attrib["condition"])
        self.assertEqual(guard.find("set-status").attrib["code"], "503")

    def test_nginx_validates_ids_and_formats_generated_request_ids_as_guids(self):
        pattern = re.search(r'"(~\\A[^"]+)" \$http_x_correlation_id;', self.nginx).group(1)[1:]
        self.assertEqual(pattern.replace(r"\z", r"\Z"), self.guid_pattern.pattern)
        generated = re.search(r'"~(\^\([^\n]+?)" "([^"]+)";', self.nginx)
        self.assertIsNotNone(generated)
        raw = uuid.uuid4().hex
        match = re.fullmatch(generated.group(1), raw)
        result = generated.group(2)
        for index, value in enumerate(match.groups(), 1):
            result = result.replace(f"${index}", value)
        self.assertRegex(result, self.guid_pattern)
        self.assertIn("default $lab_generated_correlation_id;", self.nginx)
        self.assertIn("add_header X-Correlation-ID $lab_correlation_id always;", self.nginx)

    def test_nginx_structured_logs_have_no_sensitive_request_values(self):
        log_format = re.search(r"log_format lab_json escape=json\s+(.*?);", self.nginx, re.S).group(1)
        payload = "".join(re.findall(r"'([^']+)'", log_format))
        values = {
            "time_iso8601": "2026-11-05T00:00:00Z", "lab_correlation_id": str(uuid.uuid4()),
            "hostname": "pod-1", "request_method": "GET", "lab_route": "whoami",
            "status": "200", "request_time": "0.001", "body_bytes_sent": "123",
        }
        rendered = re.sub(r"\$(\w+)", lambda m: values[m[1]], payload)
        entry = json.loads(rendered)
        self.assertEqual(entry["status"], 200)
        self.assertEqual(entry["route"], "whoami")
        self.assertEqual(set(re.findall(r"\$(\w+)", payload)), set(values))
        for variable in ("$request_uri", "$args", "$request_body", "$http_authorization",
                         "$http_cookie", "$request", "$remote_addr", "$uri"):
            self.assertNotRegex(log_format, re.escape(variable) + r"\b")
        self.assertIn("access_log /dev/stdout lab_json;", self.nginx)
        self.assertIn("error_log /dev/null;", self.nginx)
        self.assertIn("default other;", self.nginx)


class OperationsWorkbookTests(unittest.TestCase):
    def test_front_door_filters_match_observed_provider_and_categories(self):
        query = (ROOT / "infra" / "queries" / "front-door.kql").read_text()
        provider = re.search(r'ResourceProvider =~ "([^"]+)"', query).group(1)
        categories = re.search(r"Category in \(([^)]+)\)", query).group(1)
        self.assertEqual(provider, "MICROSOFT.CDN")
        self.assertEqual(set(re.findall(r'"([^"]+)"', categories)), {
            "FrontDoorAccessLog", "FrontDoorHealthProbeLog", "FrontDoorWebApplicationFirewallLog",
        })
        self.assertIn("TimeGenerated > ago(1h)", query)
        self.assertNotIn("datatable", query)

    def test_queries_cover_distinct_tiers_without_universal_join(self):
        expected = {
            "front-door": ("MICROSOFT.CDN", "FrontDoorAccessLog"),
            "application-gateway": ("MICROSOFT.NETWORK", "ApplicationGatewayAccessLog"),
            "apim-correlation": ("MICROSOFT.APIMANAGEMENT", "GatewayLogs"),
            "aks-control-plane": ("MICROSOFT.CONTAINERSERVICE", "kube-apiserver"),
        }
        for name, filters in expected.items():
            query = (ROOT / "infra" / "queries" / f"{name}.kql").read_text()
            self.assertIn("TimeGenerated > ago(1h)", query)
            for value in filters:
                self.assertIn(value, query)
            self.assertNotRegex(query, r"(?im)^\s*\|\s*join\b")
            self.assertNotRegex(query, r"(?i)\b(requestUri|requestBody|authorization|cookie)\b")
        apim = (ROOT / "infra" / "queries" / "apim-correlation.kql").read_text()
        self.assertIn('["x-correlation-id"]', apim)
        self.assertIn("ApimRequestId=", apim)
        self.assertIn("ApimCorrelationId=", apim)

    def test_workbook_reuses_workspace_without_enabling_new_ingestion(self):
        source = (ROOT / "infra" / "modules" / "operations-workbook.bicep").read_text()
        self.assertIn("Microsoft.Insights/workbooks@2023-06-01", source)
        self.assertIn("sourceId: workspace.id", source)
        self.assertEqual(source.count("query: loadTextContent('../queries/"), 5)
        for phrase in ("not a universal distributed trace", "untrusted diagnostic label",
                       "NOT enabled here", "NOT healthy evidence", "strict metric"):
            self.assertIn(phrase, source)
        self.assertNotIn("Microsoft.Insights/components@", source)
        self.assertNotIn("Microsoft.Insights/dataCollectionRules@", source)
        region = (ROOT / "infra" / "modules" / "region.bicep").read_text()
        self.assertNotIn("omsagent", region)

    def test_optional_container_query_does_not_require_container_insights(self):
        source = (ROOT / "infra" / "queries" / "aks-correlation.kql").read_text()
        self.assertIn("union isfuzzy=true", source)
        self.assertIn("datatable(", source)
        self.assertIn("ContainerLogV2", source)
        self.assertIn('PodNamespace == "apim-lab"', source)
        self.assertIn('ContainerName == "api"', source)
        self.assertIn("CorrelationId=tostring(Entry.correlationId)", source)

    def test_apim_diagnostics_only_allow_safe_headers_and_no_bodies(self):
        source = (ROOT / "infra" / "modules" / "apim-observability.bicep").read_text()
        diagnostic = source.split("resource apiDiagnostics ", 1)[1].split("dependsOn:", 1)[0]
        self.assertIn("logClientIp: false", diagnostic)
        self.assertEqual(diagnostic.count("body: { bytes: 0 }"), 4)
        headers = re.findall(r"headers:\s*\[([^\]]*)\]", diagnostic)
        self.assertEqual(len(headers), 4)
        self.assertEqual(headers[0].strip(), "")
        allowlist = {"X-Correlation-ID", "X-Lab-Gateway-Region", "X-Lab-Backend-Region"}
        for block in headers:
            self.assertLessEqual(set(re.findall(r"'([^']+)'", block)), allowlist)
        self.assertIn("percentage: 100", diagnostic)
        self.assertIn("alwaysLog: 'allErrors'", diagnostic)


class ApimCorrelationQueryTests(unittest.TestCase):
    """Fixture contracts derived from query selectors, not a live Kusto-engine test."""

    @classmethod
    def setUpClass(cls):
        cls.query = (ROOT / "infra" / "queries" / "apim-correlation.kql").read_text()
        block = cls.query.split("| extend CorrelationId=coalesce(", 1)[1].split("| project", 1)[0]
        cls.selectors = re.findall(
            r'SafeCorrelation\(tostring\((column_ifexists\("[^"]+", ""\)|\w+\["[^"]+"\])\)\)',
            block,
        )
        cls.pattern = re.compile(re.search(r'matches regex @"([^"]+)"', cls.query).group(1))
        cls.packed = re.findall(
            r'(\w+)=parse_json\(tolower\(tostring\(column_ifexists\("([^"]+)"', cls.query,
        )
        cls.overflow_packed = re.findall(
            r'(\w+)=parse_json\(tolower\(coalesce\(tostring\(Overflow\["([^"]+)"\]\), tostring\(Overflow\["([^"]+)"\]\)\)\)\)',
            cls.query,
        )

    def select(self, row):
        overflow = row.get("AdditionalFields") or {}
        contexts = {"Overflow": overflow}

        def parse_headers(value):
            try:
                decoded = json.loads((value if isinstance(value, str) else json.dumps(value)).lower())
                return decoded if isinstance(decoded, dict) else {}
            except (ValueError, TypeError):
                return {}

        for alias, column in self.packed:
            contexts[alias] = parse_headers(row.get(column, "{}"))
        for alias, first, second in self.overflow_packed:
            contexts[alias] = parse_headers(overflow.get(first) or overflow.get(second) or "{}")
        for expression in self.selectors:
            column = re.fullmatch(r'column_ifexists\("([^"]+)", ""\)', expression)
            if column:
                value = row.get(column[1], "")
            else:
                indexed = re.fullmatch(r'(\w+)\["([^"]+)"\]', expression)
                self.assertIsNotNone(indexed, expression)
                value = contexts[indexed[1]].get(indexed[2], "")
            candidate = value.lower() if isinstance(value, str) else ""
            if len(candidate) == 36 and self.pattern.fullmatch(candidate):
                return candidate
        return ""

    def test_query_selector_precedence_is_response_then_request_then_backend_response(self):
        self.assertEqual(len(self.selectors), 15)
        self.assertEqual(len(self.packed), 3)
        self.assertEqual(len(self.overflow_packed), 3)
        self.assertEqual(self.selectors[::5], [
            'column_ifexists("responseHeaders_X_Correlation_ID_g", "")',
            'column_ifexists("backendRequestHeaders_X_Correlation_ID_g", "")',
            'column_ifexists("backendResponseHeaders_X_Correlation_ID_g", "")',
        ])
        response, request, backend = [str(uuid.uuid4()) for _ in range(3)]
        row = {
            "responseHeaders_X_Correlation_ID_g": response.upper(),
            "backendRequestHeaders_X_Correlation_ID_g": request,
            "backendResponseHeaders_X_Correlation_ID_g": backend,
            "responseHeaders_s": json.dumps({"X-Correlation-ID": backend}),
            "AdditionalFields": {"responseHeaders_X_Correlation_ID_g": request},
        }
        self.assertEqual(self.select(row), response)
        row["responseHeaders_X_Correlation_ID_g"] = "invalid"
        self.assertEqual(self.select(row), request)
        row.pop("AdditionalFields")
        self.assertEqual(self.select(row), backend)
        row.pop("responseHeaders_s")
        self.assertEqual(self.select(row), request)

    def test_flattened_and_overflow_and_legacy_packed_headers_are_supported(self):
        guid = str(uuid.uuid4())
        for prefix in ("responseHeaders", "backendRequestHeaders", "backendResponseHeaders"):
            fixtures = [
                {prefix + "_X_Correlation_ID_g": guid},
                {"AdditionalFields": {prefix + "_X_Correlation_ID_g": guid}},
                {"AdditionalFields": {prefix + "_X_Correlation_ID": guid}},
                {prefix + "_s": json.dumps({"X-Correlation-ID": guid})},
                {"AdditionalFields": {prefix + "_s": json.dumps({"X-Correlation-ID": guid})}},
                {"AdditionalFields": {prefix: {"X-Correlation-ID": guid}}},
            ]
            for row in fixtures:
                with self.subTest(prefix=prefix, row=row):
                    self.assertEqual(self.select(row), guid)

    def test_missing_invalid_or_native_provider_ids_never_fake_correlation(self):
        guid = str(uuid.uuid4())
        native_only = {"requestId_g": guid, "correlationId_g": guid,
                       "responseHeaders_X_Lab_Gateway_Region_s": guid}
        self.assertEqual(self.select(native_only), "")
        self.assertEqual(self.select({}), "")
        for invalid in (guid + "\n", " " + guid, guid + "," + guid, "not-a-guid",
                        "", None, 123, [guid], {"id": guid}):
            with self.subTest(invalid=invalid):
                row = dict(native_only, responseHeaders_X_Correlation_ID_g=invalid)
                self.assertEqual(self.select(row), "")
                row["backendRequestHeaders_X_Correlation_ID_g"] = guid
                self.assertEqual(self.select(row), guid)
        block = self.query.split("| extend CorrelationId=coalesce(", 1)[1].split("| project", 1)[0]
        self.assertNotIn("requestId_g", block)
        self.assertNotIn("correlationId_g", block)
        self.assertNotIn("new_guid", self.query)
        self.assertIn("strlen(candidate) == 36", self.query)

    def test_regions_support_live_flattened_columns_and_overflow(self):
        for column in ("responseHeaders_X_Lab_Gateway_Region_s",
                       "backendResponseHeaders_X_Lab_Backend_Region_s"):
            self.assertIn(f'column_ifexists("{column}", "")', self.query)
            self.assertIn(f'Overflow["{column}"]', self.query)
        self.assertIn("BackendRegion=coalesce(", self.query)


@unittest.skipUnless(shutil.which("bicep"), "Bicep CLI is required for deployment-scope contracts")
class ScopedDeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.templates = {}
        for name in ("main", "observability"):
            result = subprocess.run(
                [shutil.which("bicep"), "build", str(ROOT / "infra" / f"{name}.bicep"),
                 "--no-restore", "--stdout"],
                capture_output=True, text=True, timeout=60,
            )
            if result.returncode:
                raise AssertionError(result.stdout + result.stderr)
            cls.templates[name] = json.loads(result.stdout)

    @staticmethod
    def leaves(template):
        for resource in template["resources"]:
            if resource["type"] == "Microsoft.Resources/deployments":
                yield from ScopedDeploymentTests.leaves(resource["properties"]["template"])
            else:
                yield resource

    def test_scoped_template_can_only_put_policy_diagnostic_and_workbook(self):
        resources = list(self.leaves(self.templates["observability"]))
        self.assertEqual(len(resources), 3)
        self.assertEqual({r["type"] for r in resources}, {
            "Microsoft.ApiManagement/service/policies",
            "Microsoft.ApiManagement/service/apis/diagnostics",
            "Microsoft.Insights/workbooks",
        })

    def test_main_and_scoped_entrypoint_share_identical_resource_definitions(self):
        scoped = {r["type"]: r for r in self.leaves(self.templates["observability"])}
        main = {r["type"]: r for r in self.leaves(self.templates["main"]) if r["type"] in scoped}
        self.assertEqual(main, scoped)

    def test_entrypoint_requires_existing_front_door_boundary_and_stable_name(self):
        parameters = self.templates["observability"]["parameters"]
        self.assertNotIn("defaultValue", parameters["frontDoorId"])
        self.assertNotIn("defaultValue", parameters["name"])
        self.assertEqual(parameters["frontDoorId"]["minLength"], 36)
        self.assertEqual(parameters["frontDoorId"]["maxLength"], 36)
        source = (ROOT / "infra" / "modules" / "apim-observability.bicep").read_text()
        self.assertEqual(source.count(" existing = {"), 3)
        workbook = (ROOT / "infra" / "modules" / "operations-workbook.bicep").read_text()
        self.assertIn("existing = {", workbook)
        self.assertIn("guid(resourceGroup().id, name, 'regional-operations')", workbook)


if __name__ == "__main__":
    unittest.main()
