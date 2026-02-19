import asyncio
import sys
import logging
import json
import os
from typing import Callable, Awaitable, List

from mcp.server import Server, NotificationOptions
from mcp.server.models import InitializationOptions
from mcp.server.stdio import stdio_server
import mcp.types as types

# Import tools logic
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from tools import _fetch_stores, _match_store_record, _resolve_store_namespace, _wait_for_wp_pod

class BaseMcpServer:
    def __init__(self, server_name: str, version: str = "1.0.0"):
        self.name = server_name
        self.version = version
        
        # Configure logging
        logging.basicConfig(level=logging.INFO, stream=sys.stderr)
        self.logger = logging.getLogger(server_name)
        
        self.server = Server(server_name)
        
        # Register store resolution helper
        self.get_store_info = self._get_store_info_impl

    def _get_store_info_impl(self, store_name: str) -> tuple[str, str]:
        """Helper to get namespace and pod for a store."""
        try:
            stores = _fetch_stores()
            match = _match_store_record(store_name, stores or [])
            if not match:
                raise ValueError(f"Store {store_name} not found")
            ns = match.get("namespace") or _resolve_store_namespace(store_name, stores)
            pod = _wait_for_wp_pod(ns)
            return ns, pod
        except Exception as e:
            self.logger.error(f"Failed to resolve store {store_name}: {e}")
            raise

    def register_handlers(self, list_tools_fn: Callable[[], Awaitable[List[types.Tool]]], call_tool_fn: Callable[[str, dict], Awaitable[List[types.TextContent]]]):
        """Register the tool listing and execution handlers."""
        
        @self.server.list_tools()
        async def handle_list_tools() -> List[types.Tool]:
            return await list_tools_fn()

        @self.server.call_tool()
        async def handle_call_tool(name: str, arguments: dict | None) -> List[types.TextContent]:
            if not arguments:
                raise ValueError("Arguments required")
            try:
                return await call_tool_fn(name, arguments)
            except Exception as e:
                self.logger.exception(f"Error executing tool {name}")
                return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": str(e)}))]

    async def run(self):
        """Run the MCP server over stdio."""
        async with stdio_server() as (read, write):
            await self.server.run(
                read,
                write,
                InitializationOptions(
                    server_name=self.name,
                    server_version=self.version,
                    capabilities=self.server.get_capabilities(
                        notification_options=NotificationOptions(),
                        experimental_capabilities={},
                    ),
                ),
            )

    def serve(self):
        """Entry point to start the server."""
        try:
            asyncio.run(self.run())
        except KeyboardInterrupt:
            pass
        except Exception as e:
            self.logger.critical(f"Server crashed: {e}")
            sys.exit(1)
