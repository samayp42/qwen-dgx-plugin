#!/usr/bin/env python3
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
import discover  # noqa: E402


class DiscoveryTests(unittest.TestCase):
    def test_model_ids_and_listener_filter(self):
        self.assertEqual(
            discover.model_ids({"data": [{"id": "first"}, {"id": "first"}, {"id": "second"}]}),
            ["first", "second"],
        )
        listeners = """\
LISTEN 0 4096 0.0.0.0:12345 0.0.0.0:* users:((\"python\",pid=41,fd=3))
LISTEN 0 4096 0.0.0.0:9000 0.0.0.0:* users:((\"python\",pid=42,fd=3))
__QWEN_DGX_PS__
  41 python python -m sglang.launch_server
  42 python python -m uvicorn app:main
"""
        self.assertEqual(discover.listener_ports(listeners), [12345])

    def test_port_8000_is_never_accepted(self):
        with self.assertRaises(discover.DiscoveryError):
            discover.normalize_endpoint("http://dgx.example:8000/v1")

    def test_endpoint_credentials_and_queries_are_rejected(self):
        for endpoint in (
            "http://user:secret@dgx.example:8889/v1",
            "http://dgx.example:8889/v1?token=secret",
        ):
            with self.subTest(endpoint=endpoint), self.assertRaises(discover.DiscoveryError):
                discover.normalize_endpoint(endpoint)

    def test_explicit_endpoint_does_not_fall_back(self):
        with patch.dict(
            "os.environ",
            {
                "QWEN_DGX_ENDPOINT": "http://stale.example:8889/v1",
                "QWEN_DGX_HOST": "user@dgx.example",
            },
            clear=True,
        ), patch.object(discover, "probe_models", return_value=[]), patch.object(
            discover, "_candidate_endpoints"
        ) as host_probe:
            with self.assertRaises(discover.DiscoveryError):
                discover.discover()
            host_probe.assert_not_called()

    def test_model_override_must_be_served(self):
        with patch.dict(
            "os.environ",
            {
                "QWEN_DGX_ENDPOINT": "http://dgx.example:8889/v1",
                "QWEN_DGX_MODEL": "dgx/missing-model",
            },
            clear=True,
        ), patch.object(discover, "probe_models", return_value=["running-model"]):
            with self.assertRaises(discover.DiscoveryError):
                discover.discover()

    def test_ssh_identity_is_validated_and_passed(self):
        with tempfile.NamedTemporaryFile() as identity:
            args = discover.ssh_command_args("user@dgx.example", "2222", identity.name)
        self.assertEqual(args[:5], ["ssh", "-i", identity.name, "-o", "IdentitiesOnly=yes"])
        identity_position = args.index("-i")
        self.assertEqual(args[identity_position + 1], identity.name)
        self.assertEqual(args[identity_position + 2 : identity_position + 4], ["-o", "IdentitiesOnly=yes"])
        self.assertEqual(args[-2], "user@dgx.example")

        with self.assertRaises(discover.DiscoveryError):
            discover.ssh_command_args("user@dgx.example", identity="/does/not/exist")


if __name__ == "__main__":
    unittest.main()
