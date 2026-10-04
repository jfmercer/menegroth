"""Print the values the server checks expect, as shell-quoted KEY=value words.

The Verify workflow passes them to scripts/verify/server.sh, so the checks
read the same configuration Ansible applies (role defaults, overridden by
group_vars/all.yml) instead of repeating it.

usage: uv run python scripts/verify/expected.py
"""

import pathlib
import re
import shlex

import yaml

ANSIBLE = pathlib.Path(__file__).resolve().parents[2] / "ansible"


def ansible_vars() -> dict:
    merged: dict = {}
    for defaults in sorted(ANSIBLE.glob("roles/*/defaults/main.yml")):
        merged.update(yaml.safe_load(defaults.read_text()) or {})
    merged.update(yaml.safe_load((ANSIBLE / "group_vars/all.yml").read_text()) or {})
    return merged


def to_bytes(size: str) -> int:
    """systemd memory sizes: K/M/G/T are powers of 1024."""
    match = re.fullmatch(r"(\d+)([KMGT]?)", str(size).strip())
    if not match:
        raise ValueError(f"unsupported size {size!r}")
    exponent = " KMGT".index(match.group(2) or " ")
    return int(match.group(1)) * 1024**exponent


def main() -> None:
    v = ansible_vars()
    expected = {
        "ADMIN_USER": v["admin_user"],
        "ADMIN_SHELL": v["admin_shell"],
        "REBOOT_TIME": v["unattended_reboot_time"],
        "NEMOCLAW_TAG": v["nemoclaw_install_tag"],
        "NEMOCLAW_COMMIT": v["nemoclaw_install_commit"],
        "NEMOCLAW_USER": v["nemoclaw_user"],
        "NEMOCLAW_UID": v["nemoclaw_uid"],
        "NEMOCLAW_HOME": v["nemoclaw_home"],
        "NEMOCLAW_SANDBOX": v["nemoclaw_sandbox_name"],
        "NEMOCLAW_PROVIDER_KEY_SECRET": v.get("nemoclaw_provider_key_secret") or "",
        "NEMOCLAW_GATEWAY_PORT": v["nemoclaw_gateway_port"],
        "SWAP_FILE": v["nemoclaw_swap_file"],
        "SWAP_MB": v["nemoclaw_swap_size_mb"],
        "CONTAINERS_MEMORY_MAX": to_bytes(v["nemoclaw_containers_memory_max"]),
        "USER_MEMORY_MAX": to_bytes(v["nemoclaw_memory_max"]),
        "DATA_MOUNT": v["luks_volume_mount"],
        "DATA_MAPPER": v["luks_volume_mapper"],
        "DATA_DEVICE_GLOB": v["luks_volume_device_glob"],
        "RESTIC_ENABLED": str(bool(v.get("ops_restic_enabled"))).lower(),
    }
    print(" ".join(f"{key}={shlex.quote(str(value))}" for key, value in expected.items()))


if __name__ == "__main__":
    main()
