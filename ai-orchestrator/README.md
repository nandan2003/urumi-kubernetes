# AI Orchestrator (LangGraph)

A high-performance FastAPI service that leverages LangGraph to orchestrate AI-driven workflows for WooCommerce and WordPress management. It provides a deterministic, stateful agent capable of planning complex tasks, executing WP-CLI commands via `kubectl exec`, and tracking progress in real-time.

## Core Architecture

- **LangGraph State Machine**: Uses a cyclic graph (`graph.py`) to manage agent state, tool execution loops, and message history.
- **In-Process Tool Registry**: Tools are defined centrally in `tool_registry.py` as strongly-typed Pydantic models. This replaces the legacy separate MCP server processes with a faster, direct execution model.
- **Direct Kubernetes Integration**: The tooling layer (`tools.py`) executes commands directly inside target WordPress pods using `kubectl exec`, ensuring context-aware operations (Namespace detection, Pod readiness checks).
- **Task Tracking System**: The main application (`main.py`) parses natural language plans (e.g., "Step 1...", "Todo:") from the AI's response and broadcasts structured `task_plan` and `task_progress` events to the UI.

## Key Features

- **Natural Language Intent**: Translates user requests (e.g., "Run a Diwali sale") into precise WP-CLI and WC-CLI commands.
- **Task Planning & Tracking**: Automatically detects multi-step plans in the agent's reasoning and reports progress (pending, in_progress, completed) for each step.
- **Safe Execution Protocol**: The system prompt enforces a "Read-Inspect-Mutate" pattern. Tools are strongly typed to prevent hallucinated arguments.
- **Streaming NDJSON**: Provides a rich real-time stream of events:
  - `tool_call`: The agent is invoking a specific action.
  - `tool_result`: Output from the WP-CLI command.
  - `task_plan`: A detected list of steps the agent intends to follow.
  - `task_progress`: Status updates on specific steps.
  - `final`: The final natural language response.

## Supported Capabilities

The orchestrator includes a comprehensive suite of tools (`tool_registry.py`) covering:

- **WooCommerce**:
  - **Products**: List, Get, Create, Update, Delete.
  - **Orders**: List, Get, Update status/notes.
  - **Coupons**: Create, List, Delete.
  - **Customers**: List, Get details.
- **Popup Maker**: Create, Update, Delete, List, and configure settings (triggers/cookies).
- **Elementor**: Flush CSS, Replace URLs, Sync Library, System Info.
- **Urumi Suite**: Create store-wide banners (`urumi_create_banner`).
- **MailPoet**: List subscribers, Create campaigns.
- **Mail Catcher**: Debugging tool to list captured outgoing emails.

## Getting Started

### Prerequisites
- Python 3.11+
- Access to a Kubernetes cluster (k3d or remote)
- Azure OpenAI credentials

### Installation

```bash
cd ai-orchestrator
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### Configuration

Create a `.env` file with the following:

```env
AZURE_OPENAI_ENDPOINT=https://<resource>.openai.azure.com/openai/v1/
AZURE_OPENAI_API_KEY=<your-key>
AZURE_OPENAI_DEPLOYMENT=<deployment-name>
ORCH_API_BASE=http://localhost:8080
```

### Running the Service

```bash
uvicorn main:APP --host 0.0.0.0 --port 8000
```

## API Usage

**Endpoint:** `POST /chat`

```bash
curl -X POST http://localhost:8000/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"Create a 20% discount coupon for Diwali and announce it with a banner"}'
```

The response is a stream of Newline Delimited JSON (NDJSON).

## Development & Testing

The project includes a comprehensive test suite in `test_suite.py` and `tests/`.

```bash
# Run the full test suite
python3 test_suite.py

# Run specific module tests
python3 -m unittest tests/test_tool_binding.py
```
