# AI Orchestrator (LangGraph)

A modular FastAPI service that leverages LangGraph to orchestrate AI-driven workflows for WooCommerce and WordPress management. It executes commands via `kubectl exec` and provides real-time streaming of tool execution and reasoning to the dashboard.

## Core Architecture
- **LangGraph Orchestration**: Manages complex, multi-step tasks (e.g., marketing campaigns or bulk order processing) using a stateful graph.
- **Modular MCP Servers**:
  - `woocommerce_mcp_server.py`: Specialized tools for WooCommerce entities (Orders, Products, Customers).
  - `elementor_mcp_server.py`: Interfaces with Elementor for automated page layout and design edits.
  - `popup_mcp_server.py`: Handles creation and management of UI notifications and popups.
  - `urumi_suite_mcp_server.py`: General utility tools for the Urumi platform.
- **Unified Client**: A centralized `mcp_client.py` facilitates communication between the orchestrator and various MCP servers.

## Key Features
- **Natural Language Intent**: Translates user requests into precise WP-CLI and WC-CLI commands.
- **Multi-step Planning**: Automatically breaks down high-level requests into sequential, logical tool calls.
- **Clarification Loop**: Interactively asks for missing information (e.g., specific order IDs or email addresses) before proceeding.
- **Safe Execution Protocol**: Enforces a `list` -> `get` -> `modify` -> `verify` pattern for all destructive or state-changing operations.
- **Streaming NDJSON**: Provides real-time feedback to the UI, including "thoughts," tool execution logs, and final responses.

## Getting Started

### Prerequisites
- Python 3.11+
- Access to a Kubernetes cluster (e.g., k3d)
- Azure OpenAI or OpenAI API credentials configured

### Installation
```bash
cd ai-orchestrator
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### Configuration
1. Copy the example environment file:
   ```bash
   cp env-example.txt .env
   ```
2. Set your `AZURE_OPENAI_ENDPOINT` (ensuring it ends with `/openai/v1/`) and other required API keys.

### Running the Service
```bash
# Start the FastAPI server
uvicorn main:APP --host 0.0.0.0 --port 8000
```

## API Usage
Interact with the orchestrator via the `/chat` endpoint:
```bash
curl -X POST http://localhost:8000/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"Create a 20% discount coupon for Diwali"}'
```

## Security & Constraints
- **Safe Mode**: Toggle `SAFE_MODE=true` in `.env` for enhanced pre-flight validation.
- **Command Allowlist**: Elementor and WooCommerce actions are restricted via `elementor-allowlist.json` and tool-level permissions.
