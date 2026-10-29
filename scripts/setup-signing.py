#!/usr/bin/env python3
"""Create or reuse an Android signing key and send it to GitHub Actions securely.

Passwords are requested with getpass or read from explicitly named environment
variables. They are never placed in shell arguments, source files, or logs.
"""
from __future__ import annotations

import argparse
import base64
import getpass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SECRET_NAMES = (
    "ANDROID_KEYSTORE_BASE64",
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
)


def run_private(command: list[str], *, command_env: dict[str, str] | None = None,
                private_input: str | None = None, failure: str) -> None:
    result = subprocess.run(command, input=private_input, text=True,
                            env=command_env, capture_output=True)
    if result.returncode:
        # Third-party output might include configuration details; retain none.
        raise RuntimeError(failure)


def is_inside(path: Path, directory: Path) -> bool:
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def check_secret_names(repository: str) -> int:
    """Read names only; the GitHub API never returns secret values."""
    result = subprocess.run(["gh", "secret", "list", "--repo", repository, "--json", "name"],
                            capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("La liste des secrets GitHub est inaccessible. Vérifiez le compte gh et les droits du dépôt.")
    try:
        entries = json.loads(result.stdout)
    except (ValueError, TypeError) as error:
        raise RuntimeError("Réponse GitHub invalide ; aucun secret n’a été modifié.") from error
    if not isinstance(entries, list) or not all(isinstance(entry, dict) and isinstance(entry.get("name"), str) for entry in entries):
        raise RuntimeError("Réponse GitHub invalide ; aucun secret n’a été modifié.")
    names = {entry["name"] for entry in entries}
    missing = [name for name in SECRET_NAMES if name not in names]
    if missing:
        print("Signature durable incomplète. Secrets manquants : " + ", ".join(missing))
        print("Aucune clé ni aucun secret n’a été créé ou modifié.")
        return 1
    print("Les quatre noms de secrets de signature sont présents dans le dépôt.")
    print("Les valeurs restent privées et ne sont pas vérifiées ici. Le workflow doit valider la clé avant publication.")
    return 0


def main(argv: list[str] | None = None) -> int:
    default_data = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="Romuel10/Rami-3D", metavar="OWNER/REPO")
    parser.add_argument("--keystore", type=Path, default=default_data / "rami-signing/rami-salon.jks")
    parser.add_argument("--alias", default="ramisalon")
    parser.add_argument("--check-secrets", action="store_true", help="Read only the expected GitHub secret names; no password or key needed.")
    parser.add_argument("--create", action="store_true", help="Create a new key; refuses to replace an existing file.")
    parser.add_argument("--prepare-only", action="store_true", help="Create/validate locally without changing GitHub secrets.")
    parser.add_argument("--password-env", metavar="VARIABLE", help="Read the password from this variable instead of prompting.")
    arguments = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", arguments.repository):
        parser.error("Expected a repository in OWNER/REPO form.")
    if arguments.check_secrets:
        if arguments.create or arguments.prepare_only or arguments.password_env:
            parser.error("--check-secrets ne peut pas créer, valider ou envoyer une clé.")
        if not shutil.which("gh"):
            parser.error("GitHub CLI (gh) est nécessaire pour lire les noms des secrets.")
        return check_secret_names(arguments.repository)
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", arguments.alias):
        parser.error("Use a simple Android key alias (letters, numbers, dots, hyphens or underscores).")
    project = Path(__file__).resolve().parents[1]
    keystore = arguments.keystore.expanduser().resolve()
    if is_inside(keystore, project):
        parser.error("Store the private keystore outside the project directory.")
    if not shutil.which("keytool"):
        parser.error("Java keytool is required. Install a JDK first.")
    if not arguments.prepare_only:
        if not shutil.which("gh"):
            parser.error("GitHub CLI (gh) is required to configure the repository secrets.")
        run_private(["gh", "api", f"repos/{arguments.repository}"],
                    failure="GitHub repository access failed. Authenticate gh with the intended account, then retry.")
    if arguments.create and keystore.exists():
        parser.error("This keystore already exists and was preserved. Remove --create to reuse it.")
    if not arguments.create and not keystore.is_file():
        parser.error("Keystore not found. Use --create once, or specify the existing signing key with --keystore.")
    if arguments.password_env:
        password = os.environ.get(arguments.password_env, "")
        if not password:
            parser.error("The named password environment variable is empty or unavailable.")
    else:
        password = getpass.getpass("Mot de passe de la clé Android : ")
        if arguments.create and password != getpass.getpass("Confirmer le mot de passe : "):
            parser.error("Passwords do not match; no key was created.")
    if len(password) < 8 or "\n" in password or "\r" in password:
        parser.error("Choose a password of at least eight characters without newlines.")
    command_env = os.environ.copy()
    command_env["RAMI_SETUP_STORE_PASSWORD"] = password
    command_env["RAMI_SETUP_KEY_PASSWORD"] = password
    if arguments.create:
        keystore.parent.mkdir(parents=True, exist_ok=True)
        # Reserve the path exclusively. keytool writes a separate temporary file,
        # so a failure never overwrites a pre-existing private key.
        marker = keystore.open("xb")
        marker.close()
        keystore.chmod(0o600)
        with tempfile.TemporaryDirectory(prefix="rami-signing-", dir=str(keystore.parent)) as temporary:
            generated = Path(temporary) / "new.jks"
            try:
                run_private(["keytool", "-genkeypair", "-noprompt", "-storetype", "PKCS12",
                             "-keystore", str(generated), "-alias", arguments.alias,
                             "-storepass:env", "RAMI_SETUP_STORE_PASSWORD",
                             "-keypass:env", "RAMI_SETUP_KEY_PASSWORD", "-keyalg", "RSA",
                             "-keysize", "3072", "-validity", "10000", "-dname",
                             "CN=Rami Salon Android, O=Rami Salon, C=MG"], command_env=command_env,
                            failure="Android key generation failed; no existing key was replaced.")
                generated.chmod(0o600)
                os.replace(generated, keystore)
            except BaseException:
                if keystore.exists() and keystore.stat().st_size == 0:
                    keystore.unlink()
                raise
    if keystore.stat().st_size > 32768:
        parser.error("The keystore is too large for one GitHub Actions secret.")
    with tempfile.TemporaryDirectory(prefix="rami-signing-check-") as temporary:
        run_private(["keytool", "-certreq", "-keystore", str(keystore), "-alias", arguments.alias,
                     "-storepass:env", "RAMI_SETUP_STORE_PASSWORD", "-keypass:env",
                     "RAMI_SETUP_KEY_PASSWORD", "-file", str(Path(temporary) / "check.csr")],
                    command_env=command_env,
                    failure="The keystore, alias or password did not validate. GitHub secrets were not changed.")
    keystore.chmod(0o600)
    if arguments.prepare_only:
        print("Clé Android prête et vérifiée localement. Aucun secret GitHub modifié.")
        print(f"Sauvegardez ce fichier privé : {keystore}")
        return 0
    values = (base64.b64encode(keystore.read_bytes()).decode("ascii"), password, arguments.alias, password)
    # Upload the key last: an interrupted first setup remains incomplete, and the
    # workflow rejects partial configuration instead of publishing a wrong APK.
    for index in (1, 2, 3, 0):
        run_private(["gh", "secret", "set", SECRET_NAMES[index], "--repo", arguments.repository],
                    private_input=values[index],
                    failure="GitHub could not save every signing secret. Retry with this same keystore; it was preserved locally.")
    print(f"Les quatre secrets de signature sont configurés pour {arguments.repository}.")
    print(f"Conservez une copie privée de la clé et de son mot de passe : {keystore}")
    print("Relancez ensuite le workflow Android APK sur la branche main.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, KeyboardInterrupt) as error:
        if isinstance(error, KeyboardInterrupt):
            print("Configuration interrompue ; la clé locale existante est conservée.", file=sys.stderr)
        else:
            print(str(error), file=sys.stderr)
        raise SystemExit(1)
