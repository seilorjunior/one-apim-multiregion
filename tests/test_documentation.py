"""Offline local-link, architecture SVG and CI safety contracts."""
from pathlib import Path
import json
import re
import unittest
import xml.etree.ElementTree as ET

import yaml


ROOT = Path(__file__).resolve().parents[1]


class DocumentationTests(unittest.TestCase):
    def test_public_repository_guidance_and_example_hosts(self):
        for name in ("LICENSE", "CONTRIBUTING.md", "SECURITY.md"):
            self.assertTrue((ROOT / name).is_file(), name)
        self.assertIn("MIT License", (ROOT / "LICENSE").read_text())
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        for link in ("LICENSE", "CONTRIBUTING.md", "SECURITY.md"):
            self.assertIn(f"]({link})", readme)
        diagram = (ROOT / "diagrams" / "private-ingress.svg").read_text(encoding="utf-8")
        hosts = re.findall(r"gw-(?:westus3|centralus)\.[a-z0-9.-]+", diagram)
        self.assertEqual(set(hosts), {"gw-westus3.example.com", "gw-centralus.example.com"})
        security = (ROOT / "SECURITY.md").read_text()
        self.assertIn("security/advisories/new", security)

    def test_all_runbook_file_links_exist(self):
        documents = [ROOT / name for name in (
            "README.md", "diagrams/README.md", "CONTRIBUTING.md", "SECURITY.md")]
        documents.extend((ROOT / "docs").glob("*.md"))
        for doc in documents:
            for link in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)', doc.read_text(encoding="utf-8")):
                if "://" in link or link.startswith("#"):
                    continue
                path = link.split("#", 1)[0].strip("<>")
                if path:
                    self.assertTrue((doc.parent / path).is_file(), f"{doc.name}: missing {path}")

    def test_svg_sources_have_accessible_titles_descriptions_and_png_exports(self):
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        for source in (ROOT / "diagrams").glob("*.svg"):
            svg = ET.parse(source).getroot()
            self.assertTrue(svg.find("svg:title", namespace).text)
            self.assertTrue(svg.find("svg:desc", namespace).text)
            image = source.with_suffix(".png")
            self.assertTrue(image.is_file(), image.name)
            self.assertTrue(image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))

    def test_offline_ci_has_readonly_permissions_and_no_azure_login(self):
        source = (ROOT / ".github" / "workflows" / "validate.yml").read_text()
        workflow = yaml.safe_load(source)
        triggers = workflow.get("on", workflow.get(True))
        self.assertEqual(set(triggers), {"push", "pull_request", "workflow_dispatch"})
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertEqual(workflow["jobs"]["validate"]["strategy"]["matrix"]["os"],
                         ["ubuntu-24.04", "windows-2022"])
        self.assertIn("Test-Local.ps1", source)
        self.assertIn("xmlrunner discover", source)
        self.assertIn("if: always()", source)
        self.assertIn("retention-days: 14", source)
        self.assertIn("npm ci --no-audit --no-fund", source)
        self.assertIn("npm run diagrams:check", source)
        self.assertIn("npm run test:diagrams", source)
        for step in workflow["jobs"]["validate"]["steps"]:
            if "uses" in step:
                self.assertRegex(step["uses"], r"@[a-f0-9]{40}$")
        for prohibited in ("secrets.", "id-token:", "azure/login", "azd up", "azd provision", "terraform apply"):
            self.assertNotIn(prohibited, source)

    def test_secret_scanning_covers_full_history_without_privileged_credentials(self):
        source = (ROOT / ".github" / "workflows" / "secret-scan.yml").read_text()
        workflow = yaml.safe_load(source)
        triggers = workflow.get("on", workflow.get(True))
        self.assertEqual(set(triggers), {"push", "pull_request", "workflow_dispatch"})
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        steps = workflow["jobs"]["gitleaks"]["steps"]
        checkout = steps[0]
        self.assertRegex(checkout["uses"], r"^actions/checkout@[a-f0-9]{40}$")
        self.assertEqual(checkout["with"]["fetch-depth"], 0)
        self.assertIs(checkout["with"]["persist-credentials"], False)
        self.assertRegex(steps[1]["env"]["GITLEAKS_SHA256"], r"^[a-f0-9]{64}$")
        self.assertIn("sha256sum --check", steps[1]["run"])
        self.assertIn("set -euo pipefail", steps[1]["run"])
        self.assertIn('--log-opts="--all"', steps[2]["run"])
        self.assertIn("--redact", steps[2]["run"])
        for prohibited in ("secrets.", "id-token:", "pull_request_target", "GITLEAKS_LICENSE"):
            self.assertNotIn(prohibited, source)

    def test_diagram_tooling_pins_renderer_and_bundles_licensed_fonts(self):
        package = json.loads((ROOT / "package.json").read_text())
        self.assertTrue(package["private"])
        self.assertRegex(package["devDependencies"]["@resvg/resvg-js"], r"^\d+\.\d+\.\d+$")
        lock = json.loads((ROOT / "package-lock.json").read_text())
        self.assertEqual(lock["packages"]["node_modules/@resvg/resvg-js"]["version"],
                         package["devDependencies"]["@resvg/resvg-js"])
        for dependency in lock["packages"].values():
            if "resolved" in dependency:
                self.assertTrue(dependency["resolved"].startswith("https://registry.npmjs.org/"))
        renderer = (ROOT / "scripts" / "render-diagrams.mjs").read_text()
        self.assertIn("loadSystemFonts: false", renderer)
        self.assertIn("fontFiles: fonts", renderer)
        for name in ("NotoSans-Regular.ttf", "NotoSans-Bold.ttf"):
            self.assertTrue((ROOT / "diagrams" / "fonts" / name).is_file())
        self.assertIn("SIL OPEN FONT LICENSE", (ROOT / "diagrams" / "fonts" / "OFL.txt").read_text())
        for source in (ROOT / "diagrams").glob("*.svg"):
            self.assertIn("Noto Sans", source.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
