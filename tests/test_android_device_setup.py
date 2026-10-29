#!/usr/bin/env python3
"""Fail-closed Android smoke runner tests; no real device is changed."""
from contextlib import redirect_stdout, redirect_stderr
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("rami_android_device", PROJECT / "scripts/test-android-device.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
CERT = "a" * 64
OTHER_CERT = "b" * 64
SERIAL = "PRIVATE-SERIAL-TEST"


class Harness:
    def __init__(self, folder):
        self.folder = Path(folder)
        self.apk = self.folder / "game.apk"
        self.report = self.folder / "report.json"
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"binary manifest fixture")
        self.sdk = self.folder / "sdk"
        for tool in ("aapt", "apksigner", "zipalign"):
            path = self.sdk / "build-tools/36.0.0" / tool
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        path = self.sdk / "platform-tools/adb"
        path.parent.mkdir(parents=True)
        path.touch()
        self.calls = []
        self.device_state = "device"
        self.api = "36"
        self.abis = "arm64-v8a,armeabi-v7a"
        self.installed = True
        self.installed_cert = CERT
        self.installed_code = 7
        self.installed_bytes = self.apk.read_bytes()
        self.emulator = False
        self.pid_calls = 0
        self.pid_after = "1234"
        self.log = "I/godot( 1234): Game ready"
        self.crash = ""
        self.install_failure = False

    def run(self, command, **kwargs):
        self.calls.append(command)
        name = Path(command[0]).name
        if name == "apksigner":
            cert = self.installed_cert if Path(command[-1]).name == "installed.apk" else CERT
            return "Verifies\nSigner #1 certificate SHA-256 digest: " + cert
        if name == "zipalign":
            return ""
        if name == "aapt":
            code = self.installed_code if Path(command[-1]).name == "installed.apk" else 7
            return (f"package: name='{runner.PACKAGE}' versionCode='{code}' versionName='0.6.0'\n"
                    "sdkVersion:'24'\nnative-code: 'arm64-v8a' 'armeabi-v7a'\n"
                    "launchable-activity: name='com.godot.game.GodotApp'\n")
        if name != "adb":
            raise AssertionError(command)
        if command[1:] == ["devices"]:
            return "List of devices attached\n" + (SERIAL + "\t" + self.device_state if self.device_state else "")
        assert command[1:3] == ["-s", SERIAL], command
        args = command[3:]
        if args[:2] == ["shell", "getprop"]:
            return {"ro.build.version.sdk": self.api, "ro.product.cpu.abilist": self.abis,
                    "ro.product.model": "Test Phone", "ro.build.version.release": "16",
                    "ro.kernel.qemu": "1" if self.emulator else "0"}[args[2]]
        if args[:3] == ["shell", "pm", "path"]:
            return "package:/data/app/test/base.apk" if self.installed else ""
        if args[0] == "pull":
            Path(args[2]).write_bytes(self.installed_bytes)
            return ""
        if args[:2] == ["install", "-r"]:
            if self.install_failure:
                raise runner.CheckError("Échec de adb: INSTALL_FAILED_UPDATE_INCOMPATIBLE")
            return "Success"
        if args[:3] == ["shell", "am", "start"]:
            return "Status: ok"
        if args[:2] == ["shell", "pidof"]:
            self.pid_calls += 1
            return "1234" if self.pid_calls == 1 else self.pid_after
        if args[0] == "logcat":
            return self.crash if "crash" in args else self.log
        raise AssertionError(command)

    def invoke(self, *extra):
        args = ["--apk", str(self.apk), "--sdk", str(self.sdk), "--report", str(self.report)] + list(extra)
        with patch.object(runner, "run", self.run), patch.object(runner.time, "sleep"), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = runner.main(args)
        return code, json.loads(self.report.read_text())

    def changing_calls(self):
        return [call for call in self.calls if any(part in ("install", "uninstall", "clear", "start") for part in call)]


class DeviceSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rami-device-test-")
        self.addCleanup(self.temp.cleanup)
        self.h = Harness(self.temp.name)

    def test_readonly_reports_phone_test_pending_even_when_device_is_available(self):
        code, report = self.h.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "host_checks_passed_device_pending")
        self.assertFalse(report["physical_device_tested"])
        self.assertEqual(report["connected_devices"], 1)
        self.assertFalse(self.h.changing_calls())
        self.assertEqual(self.h.report.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(SERIAL, self.h.report.read_text())

    def test_no_devices_is_not_a_claim_of_a_physical_pass(self):
        self.h.device_state = ""
        code, report = self.h.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(report["connected_devices"], 0)
        self.assertEqual(report["device_test"], "not_run")

    def test_explicit_serial_required_before_any_device_command(self):
        with self.assertRaises(SystemExit) as error:
            self.h.invoke("--install")
        self.assertEqual(error.exception.code, 2)
        self.assertFalse(self.h.calls)

    def test_unauthorized_device_is_not_touched(self):
        self.h.device_state = "unauthorized"
        code, report = self.h.invoke("--serial", SERIAL, "--install")
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "failed")
        self.assertFalse(self.h.changing_calls())
        self.assertFalse(any("shell" in call for call in self.h.calls))

    def test_unsupported_android_api_stops_before_install(self):
        self.h.api = "23"
        code, _ = self.h.invoke("--serial", SERIAL, "--install")
        self.assertEqual(code, 1)
        self.assertFalse(self.h.changing_calls())

    def test_unsupported_cpu_stops_before_install(self):
        self.h.abis = "x86_64,x86"
        code, _ = self.h.invoke("--serial", SERIAL, "--install")
        self.assertEqual(code, 1)
        self.assertFalse(self.h.changing_calls())

    def test_different_certificate_never_uninstalls_or_installs(self):
        self.h.installed_cert = OTHER_CERT
        code, report = self.h.invoke("--serial", SERIAL, "--install")
        self.assertEqual(code, 1)
        self.assertIn("Signature différente", report["error"])
        self.assertFalse(self.h.changing_calls())

    def test_version_downgrade_is_rejected(self):
        self.h.installed_code = 8
        code, _ = self.h.invoke("--serial", SERIAL, "--install")
        self.assertEqual(code, 1)
        self.assertFalse(self.h.changing_calls())

    def test_update_uses_only_data_preserving_r_and_does_not_launch_implicitly(self):
        code, report = self.h.invoke("--serial", SERIAL, "--install")
        self.assertEqual(code, 0)
        installs = [call for call in self.h.calls if "install" in call]
        self.assertEqual(installs, [[str(self.h.sdk / "platform-tools/adb"), "-s", SERIAL,
                                    "install", "-r", str(self.h.apk.resolve())]])
        self.assertEqual(report["installation"], "passed_preserving_data")
        self.assertEqual(report["device_test"], "install_only")
        self.assertFalse(report["physical_device_tested"])
        self.assertFalse(any("uninstall" in call or "clear" in call or "-d" in call for call in self.h.changing_calls()))

    def test_launch_only_refuses_different_apk_bytes_even_with_same_version_and_certificate(self):
        self.h.installed_bytes = b"other APK with identical public version"
        code, report = self.h.invoke("--serial", SERIAL, "--launch")
        self.assertEqual(code, 1)
        self.assertIn("exactement", report["error"])
        self.assertFalse(self.h.changing_calls())

    def test_launch_without_installed_application_does_not_install(self):
        self.h.installed = False
        code, _ = self.h.invoke("--serial", SERIAL, "--launch")
        self.assertEqual(code, 1)
        self.assertFalse(self.h.changing_calls())

    def test_device_smoke_report_has_explicit_limits_and_no_serial(self):
        code, report = self.h.invoke("--serial", SERIAL, "--launch", "--seconds", "1")
        self.assertEqual(code, 0)
        self.assertTrue(report["physical_device_tested"])
        self.assertEqual(report["status"], "device_smoke_passed_manual_checks_pending")
        self.assertIn("pending", report["manual_checks"])
        self.assertNotIn(SERIAL, self.h.report.read_text())
        log = self.h.report.with_suffix(".application.log")
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        self.assertEqual(log.read_text(), self.h.log)

    def test_emulator_is_not_recorded_as_a_physical_device(self):
        self.h.emulator = True
        code, report = self.h.invoke("--serial", SERIAL, "--launch", "--seconds", "1")
        self.assertEqual(code, 0)
        self.assertFalse(report["physical_device_tested"])

    def test_crash_or_process_restart_fails_smoke(self):
        for state in ("", "9876"):
            with self.subTest(state=state):
                self.h.calls.clear()
                self.h.pid_calls = 0
                self.h.pid_after = state
                code, report = self.h.invoke("--serial", SERIAL, "--launch", "--seconds", "1")
                self.assertEqual(code, 1)
                self.assertEqual(report["status"], "failed")
                self.assertFalse(report["physical_device_tested"])

    def test_fatal_script_error_fails_even_if_process_survives(self):
        self.h.log = "E/godot( 1234): SCRIPT ERROR: example"
        code, report = self.h.invoke("--serial", SERIAL, "--launch", "--seconds", "1")
        self.assertEqual(code, 1)
        self.assertFalse(report["physical_device_tested"])

    def test_godot_activity_alias_is_found_when_badging_omits_launcher(self):
        xml = '''    E: application (line=22)
      E: activity (line=37)
        A: android:name(0x01010003)="com.godot.game.GodotApp"
      E: activity-alias (line=48)
        A: android:name(0x01010003)="com.godot.game.GodotAppLauncher"
        E: intent-filter (line=52)
          E: action (line=53)
            A: android:name(0x01010003)="android.intent.action.MAIN"
          E: category (line=55)
            A: android:name(0x01010003)="android.intent.category.LAUNCHER"
      E: meta-data (line=58)
'''
        original = self.h.run
        def alias_manifest(command, **kwargs):
            output = original(command, **kwargs) if command[1:3] != ["dump", "xmltree"] else xml
            if Path(command[0]).name == "aapt" and command[1:3] == ["dump", "badging"]:
                output = "\n".join(line for line in output.splitlines() if not line.startswith("launchable-activity:"))
            return output
        self.h.run = alias_manifest
        code, report = self.h.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(report["apk"]["activity"], "com.godot.game.GodotAppLauncher")
        disabled = xml.replace('E: intent-filter (line=52)', 'A: android:enabled(0x0101000e)=(type 0x12)0x0\n        E: intent-filter (line=52)')
        self.assertEqual(runner.launcher_from_xmltree(disabled), "")

    def test_unsigned_or_invalid_apk_stops_before_adb(self):
        self.h.apk.write_bytes(b"not an APK")
        code, report = self.h.invoke("--serial", SERIAL, "--install")
        self.assertEqual(code, 1)
        self.assertIn("APK/ZIP", report["error"])
        self.assertFalse(self.h.calls)

    def test_apk_signature_failure_stops_before_adb(self):
        original = self.h.run
        def fail_signature(command, **kwargs):
            if Path(command[0]).name == "apksigner":
                self.h.calls.append(command)
                raise runner.CheckError("Échec de apksigner.")
            return original(command, **kwargs)
        self.h.run = fail_signature
        code, _ = self.h.invoke("--serial", SERIAL, "--install")
        self.assertEqual(code, 1)
        self.assertFalse(any(Path(call[0]).name == "adb" for call in self.h.calls))

    def test_command_timeout_does_not_leak_device_serial_into_report(self):
        original = self.h.run
        def timed_out(command, **kwargs):
            if "install" in command: raise subprocess.TimeoutExpired(command, 120)
            return original(command, **kwargs)
        self.h.run = timed_out
        code, report = self.h.invoke("--serial", SERIAL, "--install")
        self.assertEqual(code, 1)
        self.assertIn("Délai", report["error"])
        self.assertNotIn(SERIAL, self.h.report.read_text())

    def test_crash_buffer_filter_does_not_copy_other_application_records(self):
        output = ("E/AndroidRuntime( 1234): Process: fr.ramisalon.jeu, PID: 1234\n"
                  "E/AndroidRuntime( 1234): at rami.Example\n"
                  "E/OtherApp( 9999): unrelated message mentioning 1234\n")
        filtered = runner.package_crash_log(output)
        self.assertIn("at rami.Example", filtered)
        self.assertNotIn("OtherApp", filtered)


class SigningStatusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        signing_spec = importlib.util.spec_from_file_location("rami_signing_status", PROJECT / "scripts/setup-signing.py")
        cls.signing = importlib.util.module_from_spec(signing_spec)
        signing_spec.loader.exec_module(cls.signing)

    def invoke(self, entries, result_code=0):
        text = entries if isinstance(entries, str) else json.dumps(entries)
        with patch.object(self.signing.subprocess, "run", return_value=SimpleNamespace(returncode=result_code, stdout=text)) as command, \
                patch.object(self.signing.shutil, "which", return_value="/mock/gh"), \
                patch.object(self.signing.getpass, "getpass", side_effect=AssertionError("No password prompt allowed")), \
                redirect_stdout(io.StringIO()):
            code = self.signing.main(["--check-secrets", "--repository", "Romuel10/Rami-3D"])
        return code, command.call_args

    def test_complete_secret_names_are_only_presence_not_key_validation(self):
        code, call = self.invoke([{"name": name} for name in self.signing.SECRET_NAMES])
        self.assertEqual(code, 0)
        self.assertEqual(call.args[0], ["gh", "secret", "list", "--repo", "Romuel10/Rami-3D", "--json", "name"])
        self.assertNotIn("input", call.kwargs)

    def test_missing_names_report_incomplete_without_writes(self):
        code, call = self.invoke([{"name": self.signing.SECRET_NAMES[0]}])
        self.assertEqual(code, 1)
        self.assertNotIn("set", call.args[0])

    def test_invalid_metadata_and_auth_failure_fail_without_changes(self):
        for value, result in [("not JSON", 0), ({"name": "wrong shape"}, 0), ([], 1)]:
            with self.subTest(value=value, result=result), self.assertRaises(RuntimeError):
                self.invoke(value, result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
