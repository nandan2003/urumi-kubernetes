import unittest
import sys
import os
import json
import logging
import time
from unittest.mock import patch, MagicMock, ANY

# Setup paths
sys.path.append(os.path.join(os.getcwd(), "ai-orchestrator"))

# Set required environment variables for testing
os.environ["KUBECONFIG"] = "/tmp/test-kubeconfig"
os.environ["ORCH_API_BASE"] = "http://mock-api:8080"
os.environ["AZURE_OPENAI_ENDPOINT"] = "https://mock.openai.com"
os.environ["AZURE_OPENAI_API_KEY"] = "mock-key"
os.environ["AZURE_OPENAI_DEPLOYMENT"] = "mock-deployment"

# Import modules to test
# We import them *after* env vars are set to ensure they pick up defaults if needed
from graph import get_dynamic_tools
from tools import _POD_CACHE, get_store_pod_info
import tools  # To patch _kubectl directly
import urumi_suite_mcp_server
import popup_mcp_server
import elementor_mcp_server
import woocommerce_mcp_server

# Configure logging to suppress noise during tests
logging.basicConfig(level=logging.CRITICAL)

class TestAIOrchestrator(unittest.TestCase):
    # ... existing setUp ...

    # ... existing tests ...

    @patch("elementor_mcp_server._kubectl")
    def test_elementor_refactor(self, mock_kubectl):
        """Test the refactored Elementor server (BaseMcpServer usage)."""
        print("\n[Test] Elementor Server Refactor")
        
        tool_name = "flush_css"
        args = {"store_name": "nike"}
        
        # Mock get_store_info on the mcp instance
        # elementor_mcp_server.mcp is the BaseMcpServer instance
        with patch.object(elementor_mcp_server.mcp, "get_store_info", return_value=("store-nike", "pod-123")):
            import asyncio
            try:
                loop = asyncio.get_event_loop()
            except RuntimeError:
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                
            mock_kubectl.return_value = "CSS flushed"
            # Call the module-level handler
            loop.run_until_complete(elementor_mcp_server.call_tool(tool_name, args))
            
            if not mock_kubectl.called:
                self.fail("kubectl was not called!")
            
            call_args = mock_kubectl.call_args[0][0]
            self.assertIn("flush-css", call_args)
            self.assertIn("--user=admin", call_args)
            print("  -> Verified flush-css command with BaseMcpServer integration")
        # Clear caches before each test
        _POD_CACHE.clear()
        if hasattr(get_dynamic_tools, "_DYNAMIC_TOOLS_CACHE"):
             # It's a global in the module, need to access via module or just assume
             # But in my code I put it in graph.py global scope.
             # I'll access it via the module import if possible, or just mock the function
             pass
        
        # Reset the global cache in graph.py manually if accessible
        import graph
        graph._DYNAMIC_TOOLS_CACHE = {}

    @patch("requests.get")
    @patch("tools._kubectl")
    def test_dynamic_tool_discovery(self, mock_kubectl, mock_requests):
        """Test that get_dynamic_tools discovers tools and uses cache."""
        print("\n[Test] Dynamic Tool Discovery & Caching")
        
        # 1. Mock API Response
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = [{"name": "nike", "namespace": "store-nike", "id": "store-nike"}]
        mock_requests.return_value = mock_response

        # 2. Mock K8s Pod Lookup (Running)
        # First call: list pods -> returns json
        mock_kubectl.side_effect = [
            json.dumps({"items": [{"metadata": {"name": "wordpress-pod-123"}, "status": {"phase": "Running"}}]}), # _wait_for_wp_pod
            "http://nike.local", # get siteurl (if called, but internal tools skip this)
            "application-password" # create app password (skipped for internal tools)
        ]

        # 3. Execute Discovery (First Run)
        start = time.time()
        tools_list = get_dynamic_tools("nike")
        duration = time.time() - start
        
        self.assertTrue(len(tools_list) > 0, "No tools discovered")
        print(f"  -> Discovered {len(tools_list)} tools in {duration:.4f}s")
        
        # Verify internal tools exist
        tool_names = [t.name for t in tools_list]
        self.assertIn("woo_list_products", tool_names)
        self.assertIn("popup_create_popup", tool_names)
        self.assertIn("suite_mailpoet_create_campaign", tool_names)

        # 4. Verify Pod Cache
        self.assertIn("store-nike", _POD_CACHE)
        self.assertEqual(_POD_CACHE["store-nike"], "wordpress-pod-123")
        print("  -> Pod resolution cached successfully")

        # 5. Execute Discovery (Second Run - Cached)
        # Reset mocks to ensure they aren't called again
        mock_requests.reset_mock()
        mock_kubectl.reset_mock()
        
        start = time.time()
        tools_cached = get_dynamic_tools("nike")
        duration_cached = time.time() - start
        
        self.assertEqual(len(tools_cached), len(tools_list))
        self.assertLess(duration_cached, 0.1, "Cache should be near-instant")
        print(f"  -> Cached retrieval in {duration_cached:.4f}s")
        
        mock_requests.assert_not_called()
        mock_kubectl.assert_not_called()

    @patch("tools._kubectl")
    def test_mailpoet_command_generation(self, mock_kubectl):
        """Test the MailPoet tool generates the correct PHP code via wp eval."""
        print("\n[Test] MailPoet Fix Verification")
        
        # Setup call args
        tool_name = "mailpoet_create_campaign"
        args = {
            "store_name": "nike",
            "subject": "Test Campaign",
            "body": "<p>Hello</p>"
        }
        
        # Mock finding the store pod on the mcp instance
        with patch.object(urumi_suite_mcp_server.mcp, "get_store_info", return_value=("store-nike", "pod-123")):
            import asyncio
            try:
                loop = asyncio.get_event_loop()
            except RuntimeError:
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
            
            mock_kubectl.return_value = json.dumps({"ok": True, "id": 1})
            loop.run_until_complete(urumi_suite_mcp_server.call_tool(tool_name, args))
            
            # Verify the command
            if not mock_kubectl.called:
                self.fail("kubectl was not called!")
            call_args = mock_kubectl.call_args[0][0]
            # Must be an eval command
            self.assertIn("eval", call_args)
            self.assertIn("--user=admin", call_args)
            
            # Verify the PHP code contains saveNewsletter (the fix)
            php_code = None
            for arg in call_args:
                if "saveNewsletter" in arg:
                    php_code = arg
                    break
            
            self.assertIsNotNone(php_code, "PHP code did not contain 'saveNewsletter'")
            print("  -> Confirmed usage of 'saveNewsletter' in PHP eval")

    @patch("tools._kubectl")
    def test_popup_validation_fix(self, mock_kubectl):
        """Test Popup Maker tool logic and settings validation."""
        print("\n[Test] Popup Settings Validation")
        
        tool_name = "set_popup_settings"
        args = {
            "store_name": "nike",
            "popup_id": 100,
            "settings": {"triggers": []}
        }
        
        with patch.object(popup_mcp_server.mcp, "get_store_info", return_value=("store-nike", "pod-123")):
            import asyncio
            try:
                loop = asyncio.get_event_loop()
            except RuntimeError:
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                
            mock_kubectl.return_value = json.dumps({"ok": True})
            loop.run_until_complete(popup_mcp_server.call_tool(tool_name, args))
            
            # Verify command
            if not mock_kubectl.called:
                self.fail("kubectl was not called!")
            call_args = mock_kubectl.call_args[0][0]
            self.assertIn("_pum_popup_settings", call_args) # The corrected meta key
            self.assertIn("--user=admin", call_args)
            print("  -> Confirmed usage of '_pum_popup_settings' and admin user")

    @patch("elementor_mcp_server._kubectl")
    def test_elementor_refactor(self, mock_kubectl):
        """Test the refactored Elementor server (BaseMcpServer usage)."""
        print("\n[Test] Elementor Server Refactor")
        
        tool_name = "flush_css"
        args = {"store_name": "nike"}
        
        # Mock get_store_info on the mcp instance
        with patch.object(elementor_mcp_server.mcp, "get_store_info", return_value=("store-nike", "pod-123")):
            import asyncio
            try:
                loop = asyncio.get_event_loop()
            except RuntimeError:
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                
            mock_kubectl.return_value = "CSS flushed"
            # Call the module-level handler
            loop.run_until_complete(elementor_mcp_server.call_tool(tool_name, args))
            
            if not mock_kubectl.called:
                self.fail("kubectl was not called!")
            
            call_args = mock_kubectl.call_args[0][0]
            self.assertIn("flush-css", call_args)
            self.assertIn("--user=admin", call_args)
            print("  -> Verified flush-css command with BaseMcpServer integration")

    @patch("tools._kubectl")
    def test_woo_refactor(self, mock_kubectl):
        """Test the refactored WooCommerce server."""
        print("\n[Test] WooCommerce Server Refactor")
        
        tool_name = "list_products"
        args = {"store_name": "nike"}
        
        with patch.object(woocommerce_mcp_server.mcp, "get_store_info", return_value=("store-nike", "pod-123")):
            import asyncio
            try:
                loop = asyncio.get_event_loop()
            except RuntimeError:
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                
            mock_kubectl.return_value = "[]"
            loop.run_until_complete(woocommerce_mcp_server.call_tool(tool_name, args))
            
            if not mock_kubectl.called:
                self.fail("kubectl was not called!")
            
            call_args = mock_kubectl.call_args[0][0]
            self.assertIn("product", call_args)
            self.assertIn("list", call_args)
            self.assertIn("--user=admin", call_args)
            self.assertIn("--format=json", call_args)
            print("  -> Verified product list command")

    @patch("tools._kubectl")
    def test_urumi_banner(self, mock_kubectl):
        """Test the Urumi Banner tool (standard command generation)."""
        print("\n[Test] Urumi Banner Tool")
        
        tool_name = "urumi_create_banner"
        args = {
            "store_name": "nike",
            "headline": "Diwali Sale",
            "subheadline": "50% Off",
            "coupon": "DIWALI50"
        }
        
        with patch.object(urumi_suite_mcp_server.mcp, "get_store_info", return_value=("store-nike", "pod-123")):
            import asyncio
            try:
                loop = asyncio.get_event_loop()
            except RuntimeError:
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                
            mock_kubectl.return_value = "Banner created"
            loop.run_until_complete(urumi_suite_mcp_server.call_tool(tool_name, args))
            
            if not mock_kubectl.called:
                self.fail("kubectl was not called!")
            
            call_args = mock_kubectl.call_args[0][0]
            self.assertIn("urumi", call_args)
            self.assertIn("banner", call_args)
            self.assertIn("create", call_args)
            self.assertIn("--headline=Diwali Sale", call_args)
            self.assertIn("--user=admin", call_args)
            print("  -> Verified banner creation command")

if __name__ == "__main__":
    unittest.main()
