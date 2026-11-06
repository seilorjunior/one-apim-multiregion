"""Offline compiled-ARM contracts for opt-in operational alerts; no Azure access."""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


class OperationalAlertTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        bicep = shutil.which("bicep")
        if not bicep:
            raise RuntimeError("Bicep CLI is required for offline alert contract tests.")
        result = subprocess.run(
            [bicep, "build", str(ROOT / "infra" / "main.bicep"), "--stdout"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        )
        cls.main = json.loads(result.stdout)
        cls.deployments = {
            resource["name"]: resource
            for resource in cls.main["resources"]
            if resource["type"] == "Microsoft.Resources/deployments"
        }
        cls.deployment = cls.deployments["operational-alerts"]
        cls.access = cls.deployments["certificate-alert-reader"]
        cls.template = cls.deployment["properties"]["template"]
        cls.resources = cls.template["resources"]
        cls.environment = json.loads(
            (ROOT / "infra" / "main.parameters.json").read_text()
        )["parameters"]

    def resource(self, suffix):
        found = [r for r in self.resources if suffix in r["name"]]
        self.assertEqual(len(found), 1, suffix)
        return found[0]

    def criterion(self, suffix):
        return self.resource(suffix)["properties"]["criteria"]["allOf"][0]

    def test_default_off_needs_no_email_certificate_or_vault(self):
        parameters = self.main["parameters"]
        self.assertIs(parameters["enableOperationalAlerts"]["defaultValue"], False)
        for name in ("alertNotificationEmail", "alertCertificateOrderResourceId"):
            self.assertEqual(parameters[name]["defaultValue"], "")
        self.assertEqual(
            self.deployment["condition"], "[parameters('enableOperationalAlerts')]"
        )
        self.assertEqual(
            self.access["condition"],
            "[and(parameters('enableOperationalAlerts'), "
            "not(empty(parameters('alertCertificateOrderResourceId'))))]",
        )
        self.assertEqual(
            self.environment["enableOperationalAlerts"]["value"],
            "${ENABLE_OPERATIONAL_ALERTS=false}",
        )
        self.assertEqual(
            self.environment["alertNotificationEmail"]["value"],
            "${ALERT_NOTIFICATION_EMAIL=}",
        )
        self.assertEqual(
            self.environment["alertCertificateOrderResourceId"]["value"],
            "${APP_GATEWAY_CERTIFICATE_ORDER_ID=}",
        )
        self.assertEqual(self.template["parameters"]["notificationEmail"]["minLength"], 3)
        scope_parts = self.main["variables"]["alertCertificateOrderParts"]
        self.assertIn("if(empty(parameters('alertCertificateOrderResourceId'))", scope_parts)
        self.assertIn("/certificateOrders/not-configured", scope_parts)

    def test_profile_arm_scope_not_frontdoor_guid(self):
        profile = self.deployment["properties"]["parameters"]["profileId"]["value"]
        self.assertIn("resourceId(", profile)
        self.assertIn("'Microsoft.Cdn/profiles'", profile)
        self.assertIn(".outputs.profileName.value", profile)
        self.assertNotIn(".outputs.frontDoorId", profile)
        for suffix in ("-unavailable", "-frontdoor-http5xx"):
            self.assertEqual(
                self.resource(suffix)["properties"]["scopes"], ["[parameters('profileId')]"]
            )

    def test_enabled_empty_email_fails_nested_parameter_constraint(self):
        minimum = self.template["parameters"]["notificationEmail"]["minLength"]
        self.assertLess(len(""), minimum)
        self.assertEqual(self.main["parameters"]["enableOperationalAlerts"]["type"], "bool")
        self.assertEqual(
            self.deployment["condition"], "[parameters('enableOperationalAlerts')]"
        )
        self.assertEqual(
            self.deployment["properties"]["parameters"]["notificationEmail"]["value"],
            "[parameters('alertNotificationEmail')]",
        )
        # ARM enforces this child-template constraint when enabled, not during Bicep build.
        self.assertEqual(minimum, 3)

    def test_existing_offline_topology_counts_are_unchanged(self):
        def flatten(template):
            for resource in template["resources"]:
                yield resource
                if resource["type"] == "Microsoft.Resources/deployments":
                    yield from flatten(resource["properties"]["template"])

        resources = list(flatten(self.main))
        for resource_type, expected in {
            "Microsoft.ApiManagement/service": 1,
            "Microsoft.ContainerService/managedClusters": 2,
            "Microsoft.Network/applicationGateways": 2,
            "Microsoft.OperationalInsights/workspaces": 1,
            "Microsoft.Cdn/profiles/originGroups/origins": 1,
        }.items():
            self.assertEqual(
                sum(r["type"] == resource_type for r in resources), expected, resource_type
            )
        self.assertEqual(sum(
            r["type"] == "Microsoft.Authorization/roleAssignments"
            and r["properties"]["principalType"] == "User"
            for r in resources
        ), 2)

    def test_each_origin_has_exact_host_port_and_group_dimensions(self):
        rule = self.resource("-unavailable")
        self.assertEqual(rule["copy"]["count"], "[length(parameters('originHosts'))]")
        criterion = self.criterion("-unavailable")
        self.assertEqual(criterion["metricNamespace"], "Microsoft.Cdn/profiles")
        self.assertEqual(criterion["metricName"], "OriginHealthPercentage")
        self.assertEqual(criterion["dimensions"], [
            {
                "name": "Origin", "operator": "Include",
                "values": ["[format('{0}:443', parameters('originHosts')[copyIndex()])]"],
            },
            {
                "name": "OriginGroup", "operator": "Include",
                "values": ["[parameters('originGroup')]"],
            },
        ])
        self.assertEqual(
            (criterion["timeAggregation"], criterion["operator"], criterion["threshold"]),
            ("Average", "LessThan", 1),
        )

    def test_public_private_origin_wiring_and_private_only_gateways(self):
        parameters = self.deployment["properties"]["parameters"]
        self.assertEqual(
            parameters["originGroup"],
            "[if(variables('privateIngress'), createObject('value', "
            "'regional-apis-private'), createObject('value', 'regional-apis'))]",
        )
        for index, region in enumerate(("primary", "secondary")):
            host = parameters["originHosts"]["value"][index]
            self.assertIn(f"if(variables('privateIngress'), parameters('gateway{region.title()}Host'),", host)
            self.assertIn(f".outputs.{region}Host.value", host)
        gateways = parameters["gatewayIds"]
        self.assertTrue(gateways.startswith("[if(variables('privateIngress'),"))
        for region in ("primary", "secondary"):
            self.assertIn(f"'{region}-application-gateway'", gateways)
        self.assertTrue(gateways.endswith("createObject('value', createArray()))]"))

    def test_http5xx_is_supported_percentage_not_invented_metric(self):
        criterion = self.criterion("-frontdoor-http5xx")
        self.assertEqual(criterion["metricNamespace"], "Microsoft.Cdn/profiles")
        self.assertEqual(criterion["metricName"], "Percentage5XX")
        self.assertEqual(
            (criterion["timeAggregation"], criterion["operator"], criterion["threshold"]),
            ("Average", "GreaterThan", 1),
        )
        self.assertNotIn("dimensions", criterion)

    def test_unhealthy_backend_exact_scopes_and_pool_split(self):
        rule = self.resource("-unhealthy-backend")
        self.assertEqual(rule["copy"]["count"], "[length(parameters('gatewayIds'))]")
        self.assertEqual(
            rule["properties"]["scopes"], ["[parameters('gatewayIds')[copyIndex()]]"]
        )
        criterion = self.criterion("-unhealthy-backend")
        self.assertEqual(criterion["metricNamespace"], "Microsoft.Network/applicationGateways")
        self.assertEqual(criterion["metricName"], "UnhealthyHostCount")
        self.assertEqual(
            (criterion["timeAggregation"], criterion["operator"], criterion["threshold"]),
            ("Average", "GreaterThan", 0),
        )
        self.assertEqual(criterion["dimensions"], [
            {"name": "BackendSettingsPool", "operator": "Include", "values": ["*"]}
        ])

    def test_metric_windows_severity_and_action_group(self):
        for resource in self.resources:
            if resource["type"] != "Microsoft.Insights/metricAlerts":
                continue
            properties = resource["properties"]
            self.assertEqual(properties["evaluationFrequency"], "PT1M")
            self.assertEqual(properties["windowSize"], "PT5M")
            self.assertTrue(properties["autoMitigate"])
            self.assertEqual(properties["severity"], 2 if "http5xx" in resource["name"] else 1)
            action = properties["actions"][0]["actionGroupId"]
            self.assertIn("resourceId('Microsoft.Insights/actionGroups'", action)

    def test_action_group_uses_configured_email_common_schema_and_tags(self):
        group = self.resource("-operations")
        self.assertEqual(group["location"], "global")
        self.assertEqual(group["properties"]["emailReceivers"], [{
            "name": "operations",
            "emailAddress": "[parameters('notificationEmail')]",
            "useCommonAlertSchema": True,
        }])
        self.assertEqual(
            self.deployment["properties"]["parameters"]["notificationEmail"]["value"],
            "[parameters('alertNotificationEmail')]",
        )
        for resource in self.resources:
            if resource["type"] != "Microsoft.Authorization/roleAssignments":
                self.assertEqual(resource["tags"], "[parameters('tags')]")

    def test_daily_cap_uses_documented_log_signal(self):
        rule = self.resource("-ingestion-daily-cap")
        properties = rule["properties"]
        self.assertEqual(properties["scopes"], ["[parameters('workspaceId')]"])
        self.assertEqual(properties["evaluationFrequency"], "PT5M")
        self.assertEqual(properties["windowSize"], "PT5M")
        self.assertEqual(properties["severity"], 2)
        criterion = properties["criteria"]["allOf"][0]
        query = " ".join(criterion["query"].split())
        self.assertEqual(
            query,
            '_LogOperation | where TimeGenerated >= ago(5m) '
            '| where Category =~ "Ingestion" | where Detail contains "OverQuota"',
        )
        self.assertEqual(
            (criterion["timeAggregation"], criterion["operator"], criterion["threshold"]),
            ("Count", "GreaterThan", 0),
        )

    def test_certificate_expiry_is_arg_management_metadata_including_missing_data(self):
        rule = self.resource("-certificate-order-expiry")
        self.assertEqual(
            rule["condition"],
            "[and(variables('createRules'), not(empty(parameters('certificateOrderResourceId'))))]",
        )
        properties = rule["properties"]
        self.assertEqual(properties["scopes"], ["[parameters('workspaceId')]"])
        self.assertEqual(properties["evaluationFrequency"], "PT1H")
        self.assertEqual(properties["windowSize"], "PT1H")
        self.assertTrue(properties["skipQueryValidation"])
        criterion = properties["criteria"]["allOf"][0]
        query = criterion["query"]
        self.assertTrue(query.startswith("[format("))
        self.assertIn('arg("").Resources', query)
        self.assertIn("microsoft.certificateregistration/certificateorders", query)
        self.assertIn("where id =~", query)
        self.assertIn("todatetime(properties.signedCertificate.notAfter)", query)
        self.assertIn("summarize Expiry = max(Expiry), Orders = count()", query)
        self.assertIn("Orders != 1 or isnull(Expiry) or Expiry <= now() + {1}d", query)
        self.assertIn("project TimeGenerated = now()", query)
        self.assertTrue(query.endswith(
            "parameters('certificateOrderResourceId'), parameters('certificateExpiryWarningDays'))]"
        ))
        self.assertNotIn("${", query)
        self.assertEqual(
            (criterion["timeAggregation"], criterion["operator"], criterion["threshold"]),
            ("Count", "GreaterThan", 0),
        )
        parameters = self.main["parameters"]["alertCertificateExpiryWarningDays"]
        self.assertEqual(
            (parameters["defaultValue"], parameters["minValue"], parameters["maxValue"]),
            (30, 1, 365),
        )
        status = self.main["outputs"]["CERTIFICATE_EXPIRY_MONITOR_STATUS"]["value"]
        self.assertIn("not-configured: certificate expiry is NOT monitored", status)
        self.assertIn("set APP_GATEWAY_CERTIFICATE_ORDER_ID", status)

    def test_query_identity_and_least_privilege_resource_scoped_rbac(self):
        identity = self.resource("-alert-query")
        self.assertEqual(identity["type"], "Microsoft.ManagedIdentity/userAssignedIdentities")
        for suffix in ("-ingestion-daily-cap", "-certificate-order-expiry"):
            resource = self.resource(suffix)
            self.assertEqual(resource["identity"]["type"], "UserAssigned")
            self.assertEqual(len(resource["identity"]["userAssignedIdentities"]), 1)
            self.assertIn("-alert-query", json.dumps(resource["identity"]))
        assignments = [
            r for r in self.resources
            if r["type"] == "Microsoft.Authorization/roleAssignments"
        ]
        self.assertEqual(len(assignments), 2)
        workspace, order = assignments
        self.assertIn("Microsoft.OperationalInsights/workspaces", workspace["scope"])
        self.assertEqual(workspace["condition"], "[variables('createRules')]")
        self.assertEqual(
            workspace["properties"]["roleDefinitionId"], "[variables('logReaderRoleId')]"
        )
        self.assertIn(
            "73c42c96-874c-492b-b04d-ab87d138a893",
            self.template["variables"]["logReaderRoleId"],
        )
        self.assertEqual(order["condition"], "[parameters('certificateAccessOnly')]")
        self.assertEqual(
            order["scope"],
            "[resourceId('Microsoft.CertificateRegistration/certificateOrders', "
            "variables('certificateOrderName'))]",
        )
        self.assertEqual(
            self.template["variables"]["certificateOrderName"],
            "[if(parameters('certificateAccessOnly'), "
            "last(split(parameters('certificateOrderResourceId'), '/')), 'not-configured')]",
        )
        self.assertEqual(order["properties"]["principalType"], "ServicePrincipal")
        self.assertEqual(
            order["properties"]["principalId"], "[parameters('certificateReaderPrincipalId')]"
        )
        self.assertIn(
            "acdd72a7-3385-48ef-bd42-f606fba81ae7",
            self.template["variables"]["readerRoleId"],
        )
        self.assertEqual(self.access["resourceGroup"], "[variables('alertCertificateOrderParts')[4]]")
        self.assertEqual(self.access["subscriptionId"], "[variables('alertCertificateOrderParts')[2]]")
        self.assertTrue(self.access["properties"]["parameters"]["certificateAccessOnly"]["value"])
        for resource in self.resources:
            if resource is not order and "certificate-order-expiry" not in resource["name"]:
                self.assertEqual(resource["condition"], "[variables('createRules')]")

    def test_certificate_query_zero_rows_and_missing_properties_truth_table(self):
        query = self.criterion("-certificate-order-expiry")["query"]
        normalized = query.replace("\\r\\n", "\n").replace("\r\n", "\n")
        self.assertIn(
            "| summarize Expiry = max(Expiry), Orders = count()\n"
            "            | where Orders != 1 or isnull(Expiry) or Expiry <= now() + {1}d",
            normalized,
        )
        now = datetime(2030, 1, 1, tzinfo=timezone.utc)
        deadline = now + timedelta(days=30)

        def result_rows(orders):
            # Offline oracle for Kusto's ungrouped summarize (even empty input yields
            # one row), nullable todatetime/max, and the exact predicate asserted above.
            expiries = []
            for order in orders:
                signed = order.get("properties", {}).get("signedCertificate") or {}
                raw = signed.get("notAfter")
                try:
                    expiry = datetime.fromisoformat(raw) if raw else None
                except ValueError:
                    expiry = None
                if expiry is not None:
                    expiries.append(expiry)
            expiry = max(expiries, default=None)
            return int(len(orders) != 1 or expiry is None or expiry <= deadline)

        def order(expiry):
            return {"properties": {"signedCertificate": {"notAfter": expiry}}}

        cases = {
            "zero_ARG_rows": ([], 1),
            "missing_properties": ([{}], 1),
            "missing_signed_certificate": ([{"properties": {}}], 1),
            "missing_not_after": ([{"properties": {"signedCertificate": {}}}], 1),
            "null_not_after": ([order(None)], 1),
            "invalid_not_after": ([order("invalid")], 1),
            "expired": ([order((now - timedelta(days=1)).isoformat())], 1),
            "exact_warning_boundary": ([order(deadline.isoformat())], 1),
            "healthy": ([order((deadline + timedelta(seconds=1)).isoformat())], 0),
        }
        for scenario, (orders, expected) in cases.items():
            with self.subTest(scenario=scenario):
                self.assertEqual(result_rows(orders), expected)

    def test_no_vault_data_plane_or_purchase_renewal_resources(self):
        serialized = json.dumps(self.resources)
        self.assertNotIn("Microsoft.KeyVault", serialized)
        self.assertNotIn("listSecrets", serialized)
        self.assertNotIn("listKeys", serialized)
        self.assertNotRegex(
            serialized,
            r'"type": "Microsoft\.(?:CertificateRegistration|DomainRegistration)/',
        )
        for filename in (Path("main.bicep"), Path("modules") / "alerts.bicep", Path("main.parameters.json")):
            source = (ROOT / "infra" / filename).read_text()
            self.assertNotRegex(source, r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}")


if __name__ == "__main__":
    unittest.main()
