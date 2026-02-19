import unittest
from unittest.mock import patch

from tool_registry import (
    urumi_create_banner,
    mailpoet_create_campaign,
)

class TestUrumiTools(unittest.TestCase):

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_banner(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        urumi_create_banner(
            store_name="nike",
            headline="Sale",
        )
        args = mock_run.call_args[0][2]
        self.assertIn("urumi", args)

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_mailpoet(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        mailpoet_create_campaign("nike", "Subject", "<p>Body</p>")
        args = mock_run.call_args[0][2]
        self.assertIn("eval", args)


if __name__ == "__main__":
    unittest.main()

