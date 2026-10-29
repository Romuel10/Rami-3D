#!/usr/bin/env python3
"""Check an APK, then optionally install/launch it on an explicitly selected device.

No device is changed unless --serial and --install/--launch are supplied.
Existing data is preserved: this tool never uninstalls or requests a downgrade.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import zipfile

PACKAGE = "fr.ramisalon.jeu"


class CheckError(RuntimeError):
    pass


def run(command: list[str], *, allow_failure: bool = False, timeout: int = 40) -> str:
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if result.returncode and not allow_failure:
        # Keep third-party logs out of the console; known install codes are safe.
        code = re.search(r"INSTALL_FAILED_[A-Z_]+", result.stdout + result.stderr)
        raise CheckError(f"Échec de {Path(command[0]).name}" + (": " + code[0] if code else "."))
    return result.stdout.strip()


def find_tools(sdk: Path | None) -> dict[str, str]:
    if sdk is None:
        configured = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
        sdk = Path(configured).expanduser() if configured else None
    if sdk is None or not sdk.is_dir():
        raise CheckError("Indiquez le SDK Android avec --sdk ou ANDROID_HOME.")
    folders = [p for p in (sdk / "build-tools").glob("*") if re.fullmatch(r"\d+(?:\.\d+)+", p.name)]
    folders.sort(key=lambda p: tuple(int(v) for v in p.name.split(".")), reverse=True)
    folder = next((p for p in folders if all((p / name).is_file() for name in ("aapt", "apksigner", "zipalign"))), None)
    adb = sdk / "platform-tools" / "adb"
    if folder is None or not adb.is_file():
        raise CheckError("Le SDK doit contenir platform-tools et build-tools (36 ou plus récent recommandé).")
    return {name: str(folder / name) for name in ("aapt", "apksigner", "zipalign")} | {"adb": str(adb)}


def launcher_from_xmltree(text: str) -> str:
    """aapt badging can omit Godot's launcher when it is an activity-alias."""
    lines = text.splitlines()
    for start, line in enumerate(lines):
        if not re.match(r"^\s*E: activity(?:-alias)? ", line): continue
        indent = len(line)-len(line.lstrip())
        end = start+1
        while end < len(lines):
            following = lines[end]
            if re.match(r"^\s*E: ", following) and len(following)-len(following.lstrip()) <= indent: break
            end += 1
        block = "\n".join(lines[start:end])
        if "android.intent.action.MAIN" not in block or "android.intent.category.LAUNCHER" not in block: continue
        if re.search(r"A: android:enabled[^\n]*\(type 0x12\)0x0(?:\s|$)", block): continue
        name = re.search(r'A: android:name[^\n]*?="([^"]+)"', block)
        if name: return name[1]
    return ""


def inspect_apk(apk: Path, tools: dict[str, str]) -> dict:
    if not apk.is_file():
        raise CheckError("Fichier APK introuvable.")
    try:
        with zipfile.ZipFile(apk) as archive:
            if "AndroidManifest.xml" not in archive.namelist() or archive.testzip() is not None:
                raise CheckError("APK incomplet ou corrompu.")
    except zipfile.BadZipFile as error:
        raise CheckError("Le fichier n’est pas un APK/ZIP valide ; décompressez d’abord l’artefact GitHub.") from error
    signature = run([tools["apksigner"], "verify", "--verbose", "--print-certs", str(apk)])
    certificates = re.findall(r"Signer #\d+ certificate SHA-256 digest:\s*([a-fA-F0-9]+)", signature)
    if not certificates:
        raise CheckError("Certificat public de l’APK introuvable.")
    run([tools["zipalign"], "-c", "-P", "16", "4", str(apk)])
    manifest = run([tools["aapt"], "dump", "badging", str(apk)])
    package = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", manifest)
    minimum = re.search(r"^sdkVersion:'(\d+)'", manifest, re.M)
    native = re.search(r"^native-code: (.+)$", manifest, re.M)
    activity = re.search(r"^launchable-activity: name='([^']+)'", manifest, re.M)
    activity_name = activity[1] if activity else launcher_from_xmltree(
        run([tools["aapt"], "dump", "xmltree", str(apk), "AndroidManifest.xml"]))
    if not package or package[1] != PACKAGE or not minimum or not activity_name:
        raise CheckError("Cet APK ne correspond pas à Rami Salon 3D ou son manifeste est incomplet.")
    return {"package": package[1], "version_code": int(package[2]), "version": package[3],
            "minimum_api": int(minimum[1]), "abis": re.findall(r"'([^']+)'", native[1]) if native else [],
            "activity": activity_name, "certificate_sha256": sorted(v.lower() for v in certificates),
            "sha256": hashlib.sha256(apk.read_bytes()).hexdigest(), "zip_integrity": "passed",
            "signature": "passed", "alignment_16kb": "passed"}


def connected_devices(adb: str) -> dict[str, str]:
    result = {}
    for line in run([adb, "devices"]).splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] != "List":
            result[fields[0]] = fields[1]
    return result


def ensure_update_compatible(apk: dict, installed: dict) -> None:
    if installed["certificate_sha256"] != apk["certificate_sha256"]:
        raise CheckError("Signature différente de l’application installée : mise à jour refusée, données conservées. Ne désinstallez pas pour contourner ce contrôle.")
    if installed["version_code"] > apk["version_code"]:
        raise CheckError("Une version plus récente est installée : aucun retour en arrière effectué.")


def inspect_installed(apk_path: Path, tools: dict[str, str]) -> dict:
    """Inspect public signing metadata without assuming split alignment."""
    signature = run([tools["apksigner"], "verify", "--print-certs", str(apk_path)])
    manifest = run([tools["aapt"], "dump", "badging", str(apk_path)])
    code = re.search(r"versionCode='(\d+)'", manifest)
    certs = re.findall(r"Signer #\d+ certificate SHA-256 digest:\s*([a-fA-F0-9]+)", signature)
    if not code or not certs:
        raise CheckError("La signature de l’application existante ne peut pas être vérifiée ; aucune modification.")
    return {"version_code": int(code[1]), "certificate_sha256": sorted(v.lower() for v in certs),
            "sha256": hashlib.sha256(apk_path.read_bytes()).hexdigest()}


def package_crash_log(text: str) -> str:
    # The crash buffer may contain other applications: retain only this package.
    pids = set(re.findall(r"Process: " + re.escape(PACKAGE) + r", PID: (\d+)", text))
    return "\n".join(line for line in text.splitlines() if any(re.match(r"^[A-Z]/[^\n]*\(\s*" + pid + r"\):", line) for pid in pids))


def check_device(arguments, tools: dict[str, str], apk: dict, report: dict) -> None:
    devices = connected_devices(tools["adb"])
    report["connected_devices"] = len([state for state in devices.values() if state == "device"])
    if not arguments.install and not arguments.launch:
        report["device_test"] = "not_run"
        report["status"] = "host_checks_passed_device_pending"
        return
    if not arguments.serial:
        raise CheckError("--serial est obligatoire pour installer ou lancer sur un appareil précis.")
    if devices.get(arguments.serial) != "device":
        raise CheckError("L’appareil choisi est absent, hors ligne ou non autorisé. Déverrouillez-le et autorisez le débogage USB.")
    command = [tools["adb"], "-s", arguments.serial]
    def adb(*parts: str, **kwargs) -> str:
        return run(command + list(parts), **kwargs)
    api = adb("shell", "getprop", "ro.build.version.sdk")
    abis = adb("shell", "getprop", "ro.product.cpu.abilist").split(",")
    report["device"] = {"model": adb("shell", "getprop", "ro.product.model"),
                        "android": adb("shell", "getprop", "ro.build.version.release"),
                        "api": int(api) if api.isdigit() else 0, "abis": abis}
    if report["device"]["api"] < apk["minimum_api"]:
        raise CheckError("La version Android est inférieure au minimum de cet APK.")
    if apk["abis"] and not set(apk["abis"]) & set(abis):
        raise CheckError("L’architecture du téléphone n’est pas incluse dans cet APK.")
    installed_path = adb("shell", "pm", "path", PACKAGE, allow_failure=True)
    installed_files = [line.removeprefix("package:") for line in installed_path.splitlines() if line.startswith("package:")]
    if installed_path and not installed_files:
        raise CheckError("Impossible de vérifier l’application installée ; aucune installation effectuée.")
    installed = None
    if installed_files:
        with tempfile.TemporaryDirectory(prefix="rami-installed-check-") as folder:
            previous = Path(folder) / "installed.apk"
            adb("pull", installed_files[0], str(previous))
            installed = inspect_installed(previous, tools)
        if arguments.install:
            ensure_update_compatible(apk, installed)
        elif (installed["certificate_sha256"] != apk["certificate_sha256"]
              or installed["version_code"] != apk["version_code"] or installed["sha256"] != apk["sha256"]):
            raise CheckError("L’APK fourni ne correspond pas exactement au jeu installé. Utilisez --install pour tester cet APK sans confondre les versions.")
    if arguments.install:
        adb("install", "-r", str(arguments.apk.resolve()), timeout=120)
        report["installation"] = "passed_preserving_data"
    elif not installed_files:
        raise CheckError("L’application n’est pas installée. Utilisez --install pour l’installer explicitement.")
    if not arguments.launch:
        report["device_test"] = "install_only"
        report["status"] = "device_install_passed_launch_pending"
        return
    launched = adb("shell", "am", "start", "-W", "-n", PACKAGE + "/" + apk["activity"])
    if "Error:" in launched or "Exception" in launched:
        raise CheckError("Android n’a pas pu ouvrir l’activité du jeu.")
    pid = adb("shell", "pidof", PACKAGE, allow_failure=True).split()
    time.sleep(arguments.seconds)
    alive = adb("shell", "pidof", PACKAGE, allow_failure=True).split()
    log = adb("logcat", "-d", "-v", "brief", "--pid=" + pid[0], "-t", "500") if pid else ""
    if not alive:
        log += "\n" + package_crash_log(adb("logcat", "-d", "-b", "crash", "-v", "brief", "-t", "200"))
    log_path = arguments.report.with_suffix(".application.log")
    log_path.write_text(log, encoding="utf-8")
    log_path.chmod(0o600)
    report["application_log"] = log_path.name
    if not pid or not set(pid) & set(alive) or re.search(r"FATAL EXCEPTION|Fatal signal|SCRIPT ERROR:|Parse Error:", log):
        raise CheckError("Le jeu s’est arrêté ou a signalé une erreur pendant l’essai ; consulter le journal de l’application.")
    report["device_test"] = "launch_smoke_passed"
    report["observation_seconds"] = arguments.seconds
    report["status"] = "device_smoke_passed_manual_checks_pending"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--serial", help="Exact adb serial; never written to the report.")
    parser.add_argument("--install", action="store_true", help="Install/update with -r only, after certificate checks.")
    parser.add_argument("--launch", action="store_true", help="Open the game and observe its process/log for a short smoke test.")
    parser.add_argument("--seconds", type=int, default=10)
    parser.add_argument("--report", type=Path, default=Path("builds/android-device-report.json"))
    arguments = parser.parse_args(argv)
    if not 1 <= arguments.seconds <= 60:
        parser.error("--seconds doit être compris entre 1 et 60.")
    if (arguments.install or arguments.launch) and not arguments.serial:
        parser.error("--serial est obligatoire avec --install ou --launch.")
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"format": 1, "physical_device_tested": False, "status": "not_run",
              "manual_checks": "pending: gameplay, frame rate, heat, audio, backgrounding, touchscreen"}
    code = 0
    try:
        tools = find_tools(arguments.sdk)
        report["apk"] = inspect_apk(arguments.apk, tools)
        check_device(arguments, tools, report["apk"], report)
        if report.get("device_test") == "launch_smoke_passed":
            # ADB may target an emulator; record that distinction explicitly.
            emulator = run([tools["adb"], "-s", arguments.serial, "shell", "getprop", "ro.kernel.qemu"])
            report["physical_device_tested"] = emulator != "1"
        print("Vérification terminée : " + report["status"])
        if report["device_test"] == "not_run":
            print("Aucun essai Android exécuté. Choisir un appareil avec --serial puis --install --launch.")
    except (CheckError, OSError, subprocess.TimeoutExpired, ValueError) as error:
        report["status"] = "failed"
        message = "Délai de commande dépassé ; essai arrêté sans désinstallation." if isinstance(error, subprocess.TimeoutExpired) else str(error)
        if arguments.serial: message = message.replace(arguments.serial, "[appareil choisi]")
        report["error"] = message
        print(message, file=sys.stderr)
        code = 1
    arguments.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    arguments.report.chmod(0o600)
    print("Rapport : " + str(arguments.report))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
