import asyncio
import json
import os
import nest_asyncio
import traceback
from typing import List, Any, Dict, Type
from langchain_core.tools import StructuredTool
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from pydantic import create_model, BaseModel, Field
import functools

def _make_sync_wrapper(async_fn):
    """
    Return a synchronous wrapper around an async function that:
      - uses asyncio.run() if no loop is running
      - if a loop is running, uses nest_asyncio to allow run_until_complete
    """
    @functools.wraps(async_fn)
    def sync_fn(**kwargs):
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return asyncio.run(async_fn(**kwargs))
        else:
            try:
                import nest_asyncio
                nest_asyncio.apply(loop)
            except Exception:
                pass
            coro = async_fn(**kwargs)
            return loop.run_until_complete(coro)
    return sync_fn

def _json_schema_to_pydantic(name: str, schema: Dict[str, Any]) -> Type[BaseModel]:
    """Convert JSON schema to a Pydantic model for LangChain tool validation."""
    properties = schema.get("properties", {})
    required = schema.get("required", [])
    fields = {}
    
    for prop_name, prop_info in properties.items():
        field_type = Any
        type_str = prop_info.get("type")
        if type_str == "string": field_type = str
        elif type_str == "integer": field_type = int
        elif type_str == "boolean": field_type = bool
        elif type_str == "number": field_type = float
        elif type_str == "array": field_type = List[Any]
        elif type_str == "object": field_type = Dict[str, Any]
        
        description = prop_info.get("description", "")
        default = prop_info.get("default")
        
        if prop_name in required:
            fields[prop_name] = (field_type, Field(..., description=description))
        else:
            fields[prop_name] = (field_type, Field(default, description=description))
            
    return create_model(name, **fields)

nest_asyncio.apply()

class McpToolBridge:
    def __init__(self, name: str, command: str, url: str, ck: str, cs: str):
        self.name = name
        self.command = command
        self.url = url
        self.ck = ck
        self.cs = cs
        self.auth = f"{ck}:{cs}"

    async def _fetch_tools(self) -> List[StructuredTool]:
        cmd_parts = self.command.split()
        server_params = StdioServerParameters(
            command=cmd_parts[0],
            args=cmd_parts[1:],
            env={
                **os.environ,
                "WP_API_USERNAME": self.ck,
                "WP_API_PASSWORD": self.cs,
                "WORDPRESS_URL": self.url,
                "WP_API_URL": self.url
            }
        )
        
        lc_tools = []
        try:
            async with stdio_client(server_params) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    mcp_tools = await session.list_tools()
                    
                    for t in mcp_tools.tools:
                        # 1. Create the async tool execution function
                        def create_tool_fn(tool_name):
                            async def tool_fn(**kwargs):
                                cp = self.command.split()
                                sp = StdioServerParameters(
                                    command=cp[0], args=cp[1:],
                                    env={**os.environ, "WP_API_USERNAME": self.ck, "WP_API_PASSWORD": self.cs, "WORDPRESS_URL": self.url, "WP_API_URL": self.url}
                                )
                                async with stdio_client(sp) as (r, w):
                                    async with ClientSession(r, w) as sess:
                                        await sess.initialize()
                                        resp = await sess.call_tool(tool_name, kwargs)
                                        return resp.content
                            return tool_fn

                        # 2. Map the MCP schema to a Pydantic model so the LLM sees the arguments
                        schema_model = _json_schema_to_pydantic(f"{self.name}_{t.name}_schema", t.inputSchema)
                        
                        # 3. Wrap in sync caller for LangGraph
                        sync_tool_fn = _make_sync_wrapper(create_tool_fn(t.name))

                        lc_tools.append(StructuredTool.from_function(
                            func=sync_tool_fn,
                            name=f"{self.name}_{t.name.replace('-', '_')}",
                            description=t.description or f"MCP tool {t.name}",
                            args_schema=schema_model
                        ))
            return lc_tools
        except Exception as e:
            print(f"Error fetching tools from {self.name}: {e}")
            return []

    def get_tools(self) -> List[StructuredTool]:
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None

        if loop and loop.is_running():
            import nest_asyncio
            nest_asyncio.apply(loop)
            return loop.run_until_complete(self._fetch_tools())
        else:
            return asyncio.run(self._fetch_tools())
