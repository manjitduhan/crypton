#!/usr/bin/env python3
"""Generate and install Crypton PKI material.

The JSON file is the declarative input. OpenSSL is used for all key and
certificate operations; this project only validates the configuration,
arranges the generated files, and installs a selected device bundle into a
swanctl directory.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

VALID_ALGORITHMS = {"rsa", "ecdsa", "ed25519", "ed448"}
VALID_DIGESTS = {
    "sha224", "sha256", "sha384", "sha512",
    "sha3_224", "sha3_256", "sha3_384", "sha3_512",
}
VALID_RSA_PADDING = {"pkcs1", "pss"}
VALID_USAGE = {"server_auth": "serverAuth", "client_auth": "clientAuth"}
# Keep standards-friendly curve names in JSON. OpenSSL uses the historical
# alias prime256v1 for the P-256/secp256r1 curve.
VALID_CURVES = {"secp256r1": 256, "secp384r1": 384, "secp521r1": 521}
OPENSSL_CURVES = {"secp256r1": "prime256v1", "secp384r1": "secp384r1", "secp521r1": "secp521r1"}


class ConfigError(Exception):
    """A user-correctable PKI configuration error."""


def fail(message: str) -> "NoReturn":
    raise ConfigError(message)


def mapping(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{path} must be a mapping")
    return value


def nonempty(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{path} must be a non-empty string")
    if "\n" in value or "\r" in value:
        fail(f"{path} must not contain a newline")
    return value


def safe_name(value: Any, path: str) -> str:
    value = nonempty(value, path)
    if not all(char.isalnum() or char in "._-" for char in value):
        fail(f"{path} may contain only letters, numbers, '.', '_' and '-'")
    return value


def positive_int(value: Any, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        fail(f"{path} must be a positive integer")
    return value


def subject(value: Any, path: str) -> dict[str, str]:
    data = mapping(value, path)
    required = {
        "common_name": "CN",
        "organization": "O",
        "country": "C",
        "state_or_province": "ST",
        "locality": "L",
    }
    result: dict[str, str] = {}
    for key, label in required.items():
        result[key] = nonempty(data.get(key), f"{path}.{key}")
        if any(char in result[key] for char in ",/\n\r"):
            fail(f"{path}.{key} must not contain ',', '/', or newlines")
    if "organizational_unit" in data:
        result["organizational_unit"] = nonempty(
            data["organizational_unit"], f"{path}.organizational_unit"
        )
    return result


def certificate(data: Any, path: str, *, ca: bool = False) -> dict[str, Any]:
    data = mapping(data, path)
    result: dict[str, Any] = {
        "validity_days": positive_int(data.get("validity_days"), f"{path}.validity_days"),
        "subject": subject(data.get("subject"), f"{path}.subject"),
    }
    signature = mapping(data.get("signature"), f"{path}.signature")
    digest = nonempty(signature.get("digest"), f"{path}.signature.digest")
    if digest not in VALID_DIGESTS:
        fail(f"{path}.signature.digest is not supported: {digest}")
    result["digest"] = digest
    if "rsa_padding" in signature:
        padding = nonempty(signature["rsa_padding"], f"{path}.signature.rsa_padding")
        if padding not in VALID_RSA_PADDING:
            fail(f"{path}.signature.rsa_padding is not supported: {padding}")
        result["rsa_padding"] = padding
    if ca:
        path_length = data.get("path_length", 0)
        if isinstance(path_length, bool) or not isinstance(path_length, int) or path_length < 0:
            fail(f"{path}.path_length must be a non-negative integer")
        result["path_length"] = path_length
    sans = data.get("sans", [])
    if not isinstance(sans, list) or any(not isinstance(item, str) or not item for item in sans):
        fail(f"{path}.sans must be a list of non-empty strings")
    result["sans"] = sans
    usage = data.get("usage", [])
    if not isinstance(usage, list) or any(item not in VALID_USAGE for item in usage):
        fail(f"{path}.usage must contain only server_auth and client_auth")
    result["usage"] = usage
    return result


def key(data: Any, path: str) -> dict[str, Any]:
    data = mapping(data, path)
    algorithm = nonempty(data.get("algorithm"), f"{path}.algorithm")
    if algorithm not in VALID_ALGORITHMS:
        fail(f"{path}.algorithm must be one of {sorted(VALID_ALGORITHMS)}")
    result: dict[str, Any] = {"algorithm": algorithm}
    if algorithm == "rsa":
        size = positive_int(data.get("size"), f"{path}.size")
        if size < 2048:
            fail(f"{path}.size must be at least 2048 for RSA")
        result["size"] = size
    elif algorithm == "ecdsa":
        curve = nonempty(data.get("curve"), f"{path}.curve")
        if curve not in VALID_CURVES:
            fail(f"{path}.curve must be one of {sorted(VALID_CURVES)}")
        result["curve"] = curve
    elif "size" in data or "curve" in data:
        fail(f"{path}.size/curve is not valid for {algorithm}")
    return result


def relative_output_path(value: Any, path: str) -> str:
    """Keep child outputs below their authority output directory."""
    value = nonempty(value, path)
    candidate = Path(value)
    if candidate.is_absolute() or ".." in candidate.parts:
        fail(f"{path} must be a relative path below the authority output_dir")
    return value


def load_config(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        fail(f"cannot read configuration {path}: {exc}")
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON in {path}: {exc}")
    root = mapping(raw, "document")
    if root.get("schema_version") != 1:
        fail("schema_version must be 1")
    pki = mapping(root.get("pki"), "pki")
    authorities = pki.get("authorities")
    if not isinstance(authorities, list) or not authorities:
        fail("pki.authorities must be a non-empty list")

    normalized: dict[str, Any] = {"authorities": []}
    names: set[str] = set()
    for index, raw_authority in enumerate(authorities):
        apath = f"pki.authorities[{index}]"
        authority = mapping(raw_authority, apath)
        name = safe_name(authority.get("name"), f"{apath}.name")
        if name in names:
            fail(f"duplicate authority name: {name}")
        names.add(name)
        output_dir = nonempty(authority.get("output_dir"), f"{apath}.output_dir")
        root_ca = mapping(authority.get("root_ca"), f"{apath}.root_ca")
        intermediate_cas = root_ca.get("intermediate_cas")
        if not isinstance(intermediate_cas, list) or not intermediate_cas:
            fail(f"{apath}.root_ca.intermediate_cas must be a non-empty list")
        normalized_authority: dict[str, Any] = {
            "name": name,
            "output_dir": output_dir,
            "root_ca": {
                "key": key(root_ca.get("key"), f"{apath}.root_ca.key"),
                "certificate": certificate(
                    root_ca.get("certificate"), f"{apath}.root_ca.certificate", ca=True
                ),
                "intermediate_cas": [],
            },
        }
        ica_names: set[str] = set()
        for ica_index, raw_ica in enumerate(intermediate_cas):
            ipath = f"{apath}.root_ca.intermediate_cas[{ica_index}]"
            ica = mapping(raw_ica, ipath)
            ica_name = safe_name(ica.get("name"), f"{ipath}.name")
            if ica_name in ica_names:
                fail(f"duplicate intermediate CA name in {name}: {ica_name}")
            ica_names.add(ica_name)
            devices = ica.get("devices", [])
            if not isinstance(devices, list):
                fail(f"{ipath}.devices must be a list")
            normalized_ica: dict[str, Any] = {
                "name": ica_name,
                "output_dir": relative_output_path(
                    ica.get("output_dir", f"intermediate-cas/{ica_name}"),
                    f"{ipath}.output_dir",
                ),
                "key": key(ica.get("key"), f"{ipath}.key"),
                "certificate": certificate(ica.get("certificate"), f"{ipath}.certificate", ca=True),
                "devices": [],
            }
            nonempty(normalized_ica["output_dir"], f"{ipath}.output_dir")
            device_names: set[str] = set()
            for device_index, raw_device in enumerate(devices):
                dpath = f"{ipath}.devices[{device_index}]"
                device = mapping(raw_device, dpath)
                device_name = safe_name(device.get("name"), f"{dpath}.name")
                if device_name in device_names:
                    fail(f"duplicate device name in {name}/{ica_name}: {device_name}")
                device_names.add(device_name)
                role = nonempty(device.get("role", "client"), f"{dpath}.role")
                if role not in {"server", "client"}:
                    fail(f"{dpath}.role must be server or client")
                normalized_ica["devices"].append({
                    "name": device_name,
                    "role": role,
                    "key": key(device.get("key"), f"{dpath}.key"),
                    "certificate": certificate(device.get("certificate"), f"{dpath}.certificate"),
                })
            normalized_authority["root_ca"]["intermediate_cas"].append(normalized_ica)
        normalized["authorities"].append(normalized_authority)
    return normalized


def openssl_subject(data: dict[str, str]) -> str:
    """Build an OpenSSL slash-form subject from the JSON subject fields."""
    parts = [f"/C={data['country']}", f"/ST={data['state_or_province']}", f"/L={data['locality']}", f"/O={data['organization']}"]
    if "organizational_unit" in data:
        parts.append(f"/OU={data['organizational_unit']}")
    parts.append(f"/CN={data['common_name']}")
    return "".join(parts)


def openssl_binary(workspace: Path) -> Path:
    """Find Crypton's OpenSSL first, with the system OpenSSL as a fallback."""
    configured = os.environ.get("CRYPTON_OPENSSL_BIN")
    candidates = []
    if configured:
        candidates.append(Path(configured))
    candidates.append(workspace / "output" / "openssl" / "bin" / "openssl")
    system = shutil.which("openssl")
    if system:
        candidates.append(Path(system))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    fail("OpenSSL is not available; run ./crypton build pki or install openssl")


def execute(command: list[str], output: Path, mode: int = 0o644) -> None:
    """Run OpenSSL and atomically move its output into place."""
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with temporary_path.open("wb") as stream:
            result = subprocess.run(command + ["-out", str(temporary_path)], stdout=stream, stderr=subprocess.PIPE, check=False)
        if result.returncode:
            error = result.stderr.decode(errors="replace").strip()
            fail(f"command failed ({' '.join(command)}): {error}")
        temporary_path.chmod(mode)
        temporary_path.replace(output)
    finally:
        temporary_path.unlink(missing_ok=True)


def generate_key(pki: Path, spec: dict[str, Any], output: Path) -> None:
    algorithm = "EC" if spec["algorithm"] == "ecdsa" else spec["algorithm"]
    command = [str(pki), "genpkey", "-algorithm", algorithm, "-outform", "PEM"]
    if spec["algorithm"] == "rsa":
        command += ["-pkeyopt", f"rsa_keygen_bits:{spec['size']}"]
    elif spec["algorithm"] == "ecdsa":
        command += ["-pkeyopt", f"ec_paramgen_curve:{OPENSSL_CURVES[spec['curve']]}"]
    execute(command, output, 0o600)


def public_key(pki: Path, private_key: Path, output: Path) -> None:
    execute([str(pki), "pkey", "-in", str(private_key), "-pubout", "-outform", "PEM"], output)


def signature_options(cert_spec: dict[str, Any], issuer_key_spec: dict[str, Any]) -> list[str]:
    """Translate the configured certificate signature into OpenSSL options."""
    command: list[str] = []
    if issuer_key_spec["algorithm"] not in {"ed25519", "ed448"}:
        command.append("-" + cert_spec["digest"].replace("_", "-"))
    if issuer_key_spec["algorithm"] == "rsa" and cert_spec.get("rsa_padding") == "pss":
        command += ["-sigopt", "rsa_padding_mode:pss", "-sigopt", "rsa_pss_saltlen:-1"]
    return command


def extension_file(spec: dict[str, Any], *, ca: bool, subject_key_spec: dict[str, Any]) -> Path:
    """Create a temporary OpenSSL extension file for one issued certificate."""
    temporary = tempfile.NamedTemporaryFile(mode="w", suffix=".cnf", delete=False, encoding="utf-8")
    path = Path(temporary.name)
    lines = ["[ certificate_extensions ]"]
    if ca:
        lines += [
            f"basicConstraints = critical, CA:TRUE, pathlen:{spec['path_length']}",
            "keyUsage = critical, keyCertSign, cRLSign",
        ]
    else:
        lines += [
            "basicConstraints = critical, CA:FALSE",
            "keyUsage = critical, digitalSignature" + (", keyEncipherment" if subject_key_spec["algorithm"] == "rsa" else ""),
        ]
        if spec["usage"]:
            lines.append("extendedKeyUsage = " + ", ".join(VALID_USAGE[item] for item in spec["usage"]))
    lines += ["subjectKeyIdentifier = hash", "authorityKeyIdentifier = keyid, issuer"]
    sans = spec["sans"]
    if sans:
        lines += ["subjectAltName = @alt_names", "", "[ alt_names ]"]
        dns_index = ip_index = email_index = 0
        import ipaddress
        for san in sans:
            try:
                ipaddress.ip_address(san)
            except ValueError:
                if "@" in san:
                    email_index += 1
                    lines.append(f"email.{email_index} = {san}")
                else:
                    dns_index += 1
                    lines.append(f"DNS.{dns_index} = {san}")
            else:
                ip_index += 1
                lines.append(f"IP.{ip_index} = {san}")
    temporary.write("\n".join(lines) + "\n")
    temporary.close()
    return path


def issue_certificate(
    openssl: Path,
    cert_spec: dict[str, Any],
    subject_key_spec: dict[str, Any],
    key_path: Path,
    issuer_cert: Path | None,
    issuer_key: Path | None,
    issuer_key_spec: dict[str, Any],
    output: Path,
    *,
    ca: bool = False,
) -> None:
    subject_name = openssl_subject(cert_spec["subject"])
    if issuer_cert is None:
        command = [str(openssl), "req", "-new", "-x509", "-key", str(key_path)]
        command += ["-days", str(cert_spec["validity_days"]), "-subj", subject_name]
        command += signature_options(cert_spec, issuer_key_spec)
        command += ["-addext", "basicConstraints = critical, CA:TRUE"]
        command += ["-addext", "keyUsage = critical, keyCertSign, cRLSign"]
        command += ["-addext", "subjectKeyIdentifier = hash"]
        execute(command, output)
        return
    extension = extension_file(cert_spec, ca=ca, subject_key_spec=subject_key_spec)
    try:
        with tempfile.TemporaryDirectory(prefix="crypton-pki-") as temporary:
            request = Path(temporary) / "request.pem"
            execute(
                [str(openssl), "req", "-new", "-key", str(key_path), "-subj", subject_name]
                + signature_options(cert_spec, subject_key_spec),
                request,
                0o600,
            )
            command = [
                str(openssl), "x509", "-req", "-in", str(request),
                "-CA", str(issuer_cert), "-CAkey", str(issuer_key),
                "-set_serial", "0x" + secrets.token_hex(16),
                "-days", str(cert_spec["validity_days"]),
                "-extfile", str(extension), "-extensions", "certificate_extensions",
            ]
            command += signature_options(cert_spec, issuer_key_spec)
            execute(command, output)
    finally:
        extension.unlink(missing_ok=True)


def copy_file(source: Path, target: Path, mode: int = 0o644) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(mode)


def write_chain(paths: list[Path], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as stream:
        for path in paths:
            data = path.read_bytes()
            stream.write(data)
            if not data.endswith(b"\n"):
                stream.write(b"\n")
    output.chmod(0o644)


def authority_path(workspace: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else workspace / path


def generate(workspace: Path, config: dict[str, Any], force: bool) -> None:
    openssl = openssl_binary(workspace)
    for authority in config["authorities"]:
        root = authority_path(workspace, authority["output_dir"]).resolve()
        if root in {Path("/"), workspace.resolve()}:
            fail(f"refusing unsafe authority output path: {root}")
        if root.exists():
            if not force:
                fail(f"authority output already exists: {root}; use --force to regenerate it")
            shutil.rmtree(root)
        root.mkdir(parents=True, mode=0o700)

        root_key = root / "root-ca" / "private" / "root-ca.key.pem"
        root_pub = root / "root-ca" / "public" / "root-ca.public.pem"
        root_cert = root / "root-ca" / "certificate" / "root-ca.cert.pem"
        generate_key(openssl, authority["root_ca"]["key"], root_key)
        public_key(openssl, root_key, root_pub)
        issue_certificate(
            openssl,
            authority["root_ca"]["certificate"],
            authority["root_ca"]["key"],
            root_key,
            None,
            None,
            authority["root_ca"]["key"],
            root_cert,
        )

        manifest: dict[str, Any] = {"authority": authority["name"], "devices": []}
        for ica in authority["root_ca"]["intermediate_cas"]:
            ica_root = root / ica["output_dir"]
            ica_key = ica_root / "private" / "intermediate-ca.key.pem"
            ica_pub = ica_root / "public" / "intermediate-ca.public.pem"
            ica_cert = ica_root / "certificate" / "intermediate-ca.cert.pem"
            generate_key(openssl, ica["key"], ica_key)
            public_key(openssl, ica_key, ica_pub)
            issue_certificate(
                openssl,
                ica["certificate"],
                ica["key"],
                ica_key,
                root_cert,
                root_key,
                authority["root_ca"]["key"],
                ica_cert,
                ca=True,
            )

            for device in ica["devices"]:
                device_root = root / "devices" / device["name"]
                device_key = device_root / "private" / "device.key.pem"
                device_pub = device_root / "public" / "device.public.pem"
                device_cert = device_root / "certificate" / "device.cert.pem"
                chain = device_root / "certificate" / "chain.pem"
                generate_key(openssl, device["key"], device_key)
                public_key(openssl, device_key, device_pub)
                issue_certificate(
                    openssl,
                    device["certificate"],
                    device["key"],
                    device_key,
                    ica_cert,
                    ica_key,
                    ica["key"],
                    device_cert,
                )
                write_chain([device_cert, ica_cert, root_cert], chain)

                bundle = root / "bundles" / device["name"]
                copy_file(device_key, bundle / "private-key.pem", 0o600)
                copy_file(device_pub, bundle / "public-key.pem")
                copy_file(device_cert, bundle / "device-certificate.pem")
                copy_file(ica_cert, bundle / "intermediate-ca.pem")
                copy_file(root_cert, bundle / "root-ca.pem")
                copy_file(chain, bundle / "chain.pem")
                # The directory is convenient inside the workspace; the tar
                # archive is the portable bundle used for device transfer.
                bundle.chmod(0o700)
                archive = root / "bundles" / f"{device['name']}.tar.gz"
                with tempfile.NamedTemporaryFile(dir=archive.parent, delete=False) as temporary:
                    archive_temporary = Path(temporary.name)
                try:
                    import tarfile
                    with tarfile.open(archive_temporary, "w:gz") as tar:
                        tar.add(bundle, arcname=device["name"], recursive=True)
                    archive_temporary.chmod(0o600)
                    archive_temporary.replace(archive)
                finally:
                    archive_temporary.unlink(missing_ok=True)
                manifest["devices"].append({
                    "name": device["name"],
                    "role": device["role"],
                    "intermediate_ca": ica["name"],
                    "bundle": str(bundle.relative_to(root)),
                    "archive": str(archive.relative_to(root)),
                })
        manifest_path = root / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        manifest_path.chmod(0o644)
        print(f"pki: generated authority {authority['name']} in {root}")


def find_device(config: dict[str, Any], name: str, authority_name: str) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    for authority in config["authorities"]:
        if authority["name"] != authority_name:
            continue
        for ica in authority["root_ca"]["intermediate_cas"]:
            for device in ica["devices"]:
                if device["name"] == name:
                    return authority, ica, device
    fail(f"device '{name}' was not found in authority '{authority_name}'")


def install(workspace: Path, config: dict[str, Any], authority_name: str, device_name: str, target: Path) -> None:
    authority, ica, device = find_device(config, device_name, authority_name)
    root = authority_path(workspace, authority["output_dir"]).resolve()
    source = root / "devices" / device["name"]
    ica_cert = root / ica["output_dir"] / "certificate" / "intermediate-ca.cert.pem"
    root_cert = root / "root-ca" / "certificate" / "root-ca.cert.pem"
    device_key = source / "private" / "device.key.pem"
    device_cert = source / "certificate" / "device.cert.pem"
    for required in (device_key, device_cert, ica_cert, root_cert):
        if not required.is_file():
            fail(f"generated PKI file is missing: {required}; run ./crypton run pki generate")

    (target / "private").mkdir(parents=True, exist_ok=True)
    (target / "x509").mkdir(parents=True, exist_ok=True)
    (target / "x509ca").mkdir(parents=True, exist_ok=True)
    copy_file(device_key, target / "private" / f"{device_name}.key.pem", 0o600)
    copy_file(device_cert, target / "x509" / f"{device_name}.cert.pem")
    copy_file(ica_cert, target / "x509ca" / f"{ica['name']}-ca.cert.pem")
    copy_file(root_cert, target / "x509ca" / f"{authority_name}-root-ca.cert.pem")
    print(f"pki: installed {authority_name}/{device_name} into {target}")


def list_devices(config: dict[str, Any]) -> None:
    for authority in config["authorities"]:
        for ica in authority["root_ca"]["intermediate_cas"]:
            for device in ica["devices"]:
                print(f"{authority['name']}\t{ica['name']}\t{device['name']}\t{device['role']}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate and install Crypton PKI material")
    parser.add_argument("--config", type=Path, required=True, help="path to pki.json")
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate", help="generate authorities and device bundles")
    generate_parser.add_argument("--force", action="store_true", help="replace existing authority output")
    subparsers.add_parser("validate", help="validate pki.json without generating files")
    subparsers.add_parser("list", help="list configured devices")
    install_parser = subparsers.add_parser("install", help="install one device into a swanctl directory")
    install_parser.add_argument("--authority", required=True)
    install_parser.add_argument("--device", required=True)
    install_parser.add_argument("--swanctl-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        config = load_config(args.config.resolve())
        workspace = Path(os.environ.get("CRYPTON_ROOT", Path.cwd())).resolve()
        if args.command == "validate":
            print(f"pki: valid configuration ({len(config['authorities'])} authorities)")
        elif args.command == "list":
            list_devices(config)
        elif args.command == "generate":
            generate(workspace, config, args.force)
        elif args.command == "install":
            install(workspace, config, args.authority, args.device, args.swanctl_dir)
        return 0
    except ConfigError as exc:
        print(f"pki: error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
