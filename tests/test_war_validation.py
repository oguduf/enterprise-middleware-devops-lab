import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "validate-war.py"


class WarValidationTests(unittest.TestCase):
    def run_validator(self, path):
        return subprocess.run([sys.executable, str(SCRIPT), str(path)], text=True, capture_output=True, check=False)

    def test_valid_war_archive_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            war = Path(directory) / "app.war"
            with zipfile.ZipFile(war, "w") as archive:
                archive.writestr("WEB-INF/web.xml", "<web-app/>")
                archive.writestr("index.html", "ok")
            result = self.run_validator(war)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_zip_war_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            war = Path(directory) / "bad.war"
            war.write_text("not a zip archive", encoding="utf-8")
            result = self.run_validator(war)
            self.assertEqual(result.returncode, 1)
            self.assertIn("not a readable ZIP/WAR archive", result.stderr)

    def test_zip_without_web_inf_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            war = Path(directory) / "not-really-a-war.war"
            with zipfile.ZipFile(war, "w") as archive:
                archive.writestr("readme.txt", "not a web archive")
            result = self.run_validator(war)
            self.assertEqual(result.returncode, 1)
            self.assertIn("no WEB-INF content", result.stderr)

    def test_wrong_extension_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "app.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("WEB-INF/web.xml", "<web-app/>")
            result = self.run_validator(archive_path)
            self.assertEqual(result.returncode, 1)
            self.assertIn("must end in .war", result.stderr)


if __name__ == "__main__":
    unittest.main()
