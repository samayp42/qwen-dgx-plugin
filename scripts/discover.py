#!/usr/bin/env python3
"""Find a live OpenAI-compatible model endpoint without changing the host.

The discovery order is deliberately narrow:

1. An explicitly configured endpoint.
2. Explicit endpoint candidates.
3. Model-serving listeners reported by a configured SSH host.

Only GET /models is used. Port 8000 is reserved and is never probed.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from typing import Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import SplitResult, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


PROTECTED_PORT = 8000
MAX_RESPONSE_BYTES = 1024 * 1024
MODEL_PROCESS_RE = re.compile(
    r"(?:\bvllm\b|\bsglang\b|\bollama\b|\bllama(?:[-_. ]?server|[-_. ]?cpp)?\b|"
    r"\btext[-_ ]generation(?:[-_ ]inference)?\b|\btgi\b|\blmdeploy\b|"
    r"\btritonserver\b|\binference[-_ ]server\b|\bopenai[-_ ]compatible\b)",
    re.IGNORECASE,
)
PID_RE = re.compile(r"pid=(\d+)")
PROCESS_RE = re.compile(r"^\s*(\d+)\s+(\S+)(?:\s+(.*))?$")
PORT_FLAG_RE = re.compile(r"(?:^|\s)--port[= ](\d+)")


class DiscoveryError(RuntimeError):
    """A safe, user-actionable discovery failure."""


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, new_url):
        return None


_OPENER = build_opener(_NoRedirect)


def _timeout(name: str, default: float) -> float:
    """Read a bounded timeout so a bad environment value cannot hang discovery."""

    try:
        value = float(os.environ.get(name, default))
    except ValueError:
        value = default
    return min(max(value, 0.5), 10.0)


def _has_control_chars(value: str) -> bool:
    return any(ord(char) < 32 or ord(char) == 127 for char in value)


def _split_endpoint(endpoint: str) -> SplitResult:
    candidate = endpoint.strip()
    if not candidate or _has_control_chars(candidate):
        raise DiscoveryError("the configured endpoint is invalid")
    parts = urlsplit(candidate)
    if parts.scheme not in {"http", "https"} or not parts.netloc or parts.fragment:
        raise DiscoveryError("the configured endpoint must be an http or https URL")
    if parts.username or parts.password or parts.query:
        raise DiscoveryError("endpoint URLs must not contain credentials or query parameters")
    try:
        port = parts.port
    except ValueError as exc:
        raise DiscoveryError("the configured endpoint has an invalid port") from exc
    if port == PROTECTED_PORT:
        raise DiscoveryError("port 8000 is reserved and will not be probed")
    if not parts.hostname:
        raise DiscoveryError("the configured endpoint has no host")
    return parts


def normalize_endpoint(endpoint: str) -> str:
    """Return an OpenAI-compatible base URL without embedded credentials."""

    parts = _split_endpoint(endpoint)
    path = parts.path.rstrip("/")
    if path.endswith("/models"):
        path = path[: -len("/models")].rstrip("/")
    return urlunsplit((parts.scheme, parts.netloc, path, parts.query, ""))


def _models_url(endpoint: str) -> str:
    parts = _split_endpoint(endpoint)
    path = parts.path.rstrip("/")
    if not path.endswith("/models"):
        path = f"{path}/models" if path else "/models"
    return urlunsplit((parts.scheme, parts.netloc, path, parts.query, ""))


def model_ids(payload: bytes | str | dict) -> list[str]:
    """Extract safe model IDs from an OpenAI /models response."""

    data = payload if isinstance(payload, dict) else json.loads(payload)
    records = data.get("data") if isinstance(data, dict) else None
    if not isinstance(records, list):
        return []
    result: list[str] = []
    for record in records:
        model_id = record.get("id") if isinstance(record, dict) else None
        if not isinstance(model_id, str) or not model_id or _has_control_chars(model_id):
            continue
        if model_id not in result:
            result.append(model_id)
    return result


def probe_models(endpoint: str, timeout: float | None = None) -> list[str]:
    """GET /models once; never follow redirects or print response contents."""

    url = _models_url(normalize_endpoint(endpoint))
    headers = {"Accept": "application/json"}
    request = Request(url, headers=headers, method="GET")
    try:
        with _OPENER.open(request, timeout=timeout or _timeout("QWEN_DGX_PROBE_TIMEOUT", 4.0)) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except (HTTPError, OSError, TimeoutError, URLError, ValueError):
        return []
    if len(body) > MAX_RESPONSE_BYTES:
        return []
    try:
        return model_ids(body)
    except (TypeError, ValueError, json.JSONDecodeError):
        return []


def _parse_port(address: str) -> int | None:
    address = address.strip()
    if address.startswith("[") and "]" in address:
        _, _, port = address.rpartition("]:")
    else:
        _, separator, port = address.rpartition(":")
        if not separator:
            return None
    try:
        value = int(port)
    except ValueError:
        return None
    return value if 1 <= value <= 65535 else None


def _processes(ps_output: str) -> dict[int, str]:
    result: dict[int, str] = {}
    for line in ps_output.splitlines():
        match = PROCESS_RE.match(line)
        if match:
            pid, command, args = match.groups()
            result[int(pid)] = " ".join(part for part in (command, args or "") if part)
    return result


def is_model_serving_process(command: str) -> bool:
    return bool(MODEL_PROCESS_RE.search(command))


def listener_ports(listener_output: str) -> list[int]:
    """Parse ss/netstat output and retain only model-serving listeners."""

    ss_output, separator, ps_output = listener_output.partition("__QWEN_DGX_PS__")
    processes = _processes(ps_output if separator else "")
    declared_ports: set[int] = set()
    for command in processes.values():
        if is_model_serving_process(command):
            declared_ports.update(int(port) for port in PORT_FLAG_RE.findall(command))
    ports: set[int] = set()
    for line in ss_output.splitlines():
        if not line.strip() or not re.match(r"^\s*(?:LISTEN|tcp\s+\d|tcp6\s+\d)", line, re.IGNORECASE):
            continue
        fields = line.split()
        addresses = fields[3:5] if len(fields) >= 5 else fields
        port = next((_parse_port(address) for address in addresses), None)
        if not port or port == PROTECTED_PORT:
            continue
        pids = {int(pid) for pid in PID_RE.findall(line)}
        process_text = " ".join(processes.get(pid, "") for pid in pids)
        process_text = f"{process_text} {line}"
        if is_model_serving_process(process_text) or port in declared_ports:
            ports.add(port)
    return sorted(ports)


def _valid_ssh_host(host: str) -> str:
    host = host.strip()
    if not host or host.startswith("-") or _has_control_chars(host) or any(char.isspace() for char in host):
        raise DiscoveryError("QWEN_DGX_HOST must be a configured SSH host")
    return host


def _valid_ssh_identity(identity: str) -> str:
    candidate = os.path.expanduser(identity.strip())
    if (
        not candidate
        or _has_control_chars(candidate)
        or not os.path.isfile(candidate)
        or not os.access(candidate, os.R_OK)
    ):
        raise DiscoveryError("QWEN_DGX_SSH_IDENTITY must be a readable identity file")
    return candidate


def ssh_command_args(
    host: str,
    ssh_port: str | None = None,
    identity: str | None = None,
) -> list[str]:
    """Build the fixed, read-only SSH invocation used for host discovery."""

    host = _valid_ssh_host(host)
    args = ["ssh"]
    if identity is not None:
        args.extend(["-i", _valid_ssh_identity(identity), "-o", "IdentitiesOnly=yes"])
    args.extend(
        [
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=3",
            "-o",
            "ServerAliveInterval=2",
            "-o",
            "ServerAliveCountMax=1",
        ]
    )
    if ssh_port:
        if not ssh_port.isdigit() or not 1 <= int(ssh_port) <= 65535 or int(ssh_port) == PROTECTED_PORT:
            raise DiscoveryError("QWEN_DGX_SSH_PORT is invalid or reserved")
        args.extend(["-p", ssh_port])
    command = "ss -Hlnpt 2>/dev/null || netstat -lntp 2>/dev/null; printf '\\n__QWEN_DGX_PS__\\n'; ps -eo pid=,comm=,args= 2>/dev/null"
    args.extend([host, command])
    return args


def remote_listener_output(
    host: str,
    ssh_port: str | None = None,
    identity: str | None = None,
) -> str:
    """Read listener/process metadata from one configured host; never execute a shell string."""

    args = ssh_command_args(host, ssh_port, identity)
    try:
        result = subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
            timeout=_timeout("QWEN_DGX_SSH_TIMEOUT", 5.0),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DiscoveryError("could not read the configured DGX host") from exc
    if result.returncode != 0:
        raise DiscoveryError("could not read the configured DGX host")
    return result.stdout


def _host_for_url(ssh_host: str) -> str:
    host = ssh_host.rsplit("@", 1)[-1]
    if host.startswith("[") and host.endswith("]"):
        return host
    if ":" in host:
        return f"[{host}]"
    return host


def _candidate_endpoints(host: str, candidates: Iterable[str]) -> list[str]:
    result = [candidate.strip() for candidate in candidates if candidate.strip()]
    output = remote_listener_output(
        host,
        os.environ.get("QWEN_DGX_SSH_PORT") or None,
        os.environ.get("QWEN_DGX_SSH_IDENTITY") or None,
    )
    url_host = _host_for_url(host)
    result.extend(f"http://{url_host}:{port}/v1" for port in listener_ports(output))
    return result


def _configured_candidates() -> list[str]:
    value = os.environ.get("QWEN_DGX_ENDPOINT_CANDIDATES", "")
    if not value:
        value = os.environ.get("QWEN_DGX_CANDIDATES", "")
    return [candidate for candidate in re.split(r"[,\n]", value) if candidate.strip()]


def _model_id_override(value: str) -> str:
    value = value.strip()
    if value.startswith("dgx/"):
        value = value[len("dgx/") :]
    if not value or _has_control_chars(value):
        raise DiscoveryError("the configured model is invalid")
    return value


def discover() -> tuple[str, str]:
    endpoint_override = os.environ.get("QWEN_DGX_ENDPOINT", "").strip()
    model_override = os.environ.get("QWEN_DGX_MODEL", "").strip()
    host = os.environ.get("QWEN_DGX_HOST", "").strip()
    candidates = _configured_candidates()
    if not endpoint_override and not candidates and not host:
        raise DiscoveryError("set QWEN_DGX_ENDPOINT or QWEN_DGX_HOST for discovery")

    def select(candidates_to_probe: Iterable[str]) -> tuple[str, str] | None:
        seen: set[str] = set()
        protected = False
        for candidate in candidates_to_probe:
            try:
                endpoint = normalize_endpoint(candidate)
            except DiscoveryError as exc:
                if "port 8000" in str(exc):
                    protected = True
                if endpoint_override and candidate == endpoint_override:
                    raise
                continue
            if endpoint in seen:
                continue
            seen.add(endpoint)
            ids = probe_models(endpoint)
            if ids:
                if model_override:
                    requested = _model_id_override(model_override)
                    if requested not in ids:
                        continue
                    return endpoint, requested
                return endpoint, ids[0]
        if protected and endpoint_override:
            raise DiscoveryError("port 8000 is reserved and will not be probed")
        return None

    if endpoint_override:
        selected = select([endpoint_override])
        if not selected:
            raise DiscoveryError("the configured endpoint or model is unavailable")
        return selected
    selected = select(candidates)
    if selected:
        return selected
    if host:
        selected = select(_candidate_endpoints(host, []))
        if selected:
            return selected
    raise DiscoveryError("no reachable OpenAI-compatible model endpoint was found")


def main() -> int:
    try:
        endpoint, model_id = discover()
    except DiscoveryError as exc:
        print(f"qwen-dgx: {exc}", file=sys.stderr)
        return 3
    print(endpoint)
    print(model_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
