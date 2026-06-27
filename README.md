# Visual Schema-Driven Chunked Data Extractor

An interactive, visual schema editor and text-extraction application. This project combines a **Cappuccino (Objective-J)** web-based desktop application frontend with a **Mojolicious (Perl)** backend to extract structured, nested data from unstructured text using Large Language Models (LLMs) with automated self-correction.

---

## 🏗️ System Architecture

This application utilizes a decoupled client-server architecture:

```
┌──────────────────────────────────────┐          ┌───────────────────────────┐
│         Objective-J Frontend         │          │    Mojolicious Backend    │
│  ┌────────────────────────────────┐  │  JSON    │  ┌─────────────────────┐  │
│  │ CPOutlineView (Visual Schema)   │  ├─────────►│  │ Chunking & Merging  │  │
│  └────────────────────────────────┘  │  Request │  └──────────┬──────────┘  │
│  ┌────────────────────────────────┐  │          │             ▼             │
│  │ CPTextView (Text Highlights)   │  │◄─────────┤  ┌─────────────────────┐  │
│  └────────────────────────────────┘  │  JSON    │  │ Schema Validation   │  │
│  ┌────────────────────────────────┐  │  Response│  │  & Self-Correction  │  │
│  │ CPTableView & CSV Export       │  │          │  └──────────┬──────────┘  │
│  └────────────────────────────────┘  │          │             ▼             │
└──────────────────────────────────────┘          │       Target LLM API      │
                                                  │ (vLLM, Ollama, OpenAI)    │
                                                  └───────────────────────────┘
```

*   **Frontend (Objective-J / Cappuccino)**: Provides a desktop-class GUI in the browser. It features a recursive tree controller linked to a hierarchical schema editor, text highlighting based on character offset indices, dynamic JSON schema import/export, and tabular data visualization with instant CSV downloads.
*   **Backend (Perl / Mojolicious::Lite)**: Manages sliding character-bounded document chunking to fit context windows, constructs strict metadata-wrapped schemas, queries OpenAI-compatible endpoints or local Ollama instances, validates extraction structures dynamically, and performs corrective prompt retries on validation mismatches.

---

## ✨ Features

*   **Graphical Schema Tree Editor**: Create, modify, nest, and delete fields dynamically using a visual outline view (`string`, `number`, `array`, `object`).
*   **Dynamic Document Chunking**: Automatically processes long inputs by separating text into character-bounded blocks to respect LLM token limits.
*   **Source Text Highlights**: Visual color bands map the extracted fields directly to the precise verbatim offset matches inside the document editor.
*   **Auto-Correction Validation Loop**: The backend analyzes extraction structures against your visual tree schema and triggers correction feedback runs if structural or type validation mismatches are detected.
*   **JSON Import/Export**: Directly view, copy, or paste your layout via the Schema JSON panel to share schema configurations easily.
*   **Tabular CSV Export**: Export all resolved paths, extracted values, and source text coordinates as a structured CSV spreadsheet directly from the client.

---

## 🚀 Getting Started

### 1. Prerequisites

*   **Perl 5.20+** with cpanminus (or similar package manager).
*   An active LLM connection (e.g., an OpenAI-compatible API gateway or a local **Ollama** server running `gemma4:e4b-mlx` or equivalent).

### 2. Backend Installation & Run

Clone the repository and install the Perl dependencies:

```bash
# Clone the repository
git clone https://github.com/your-username/your-repo-name.git
cd your-repo-name

# Install Mojolicious and dependencies
cpanm Mojolicious::Lite Mojo::UserAgent Encode File::Spec Mojo::JSON
```

Set up your environment variables to point to your LLM provider. For example, to use a standard vLLM or OpenAI-compatible endpoint:

```bash
export VLLM_API_KEY="your-api-key-here"
export VLLM_ENDPOINT="https://your-llm-gateway.example.com/v1/chat/completions"
export VLLM_MODEL="gpt-oss-120b"
```

Start the Mojolicious development backend server:

```bash
perl app.pl daemon -l http://localhost:3000
```

*Note: If you choose the "ollama" option in the UI, the backend will automatically redirect requests to your local instance at `http://localhost:11434/v1/chat/completions` using the default model `gemma4:e4b-mlx` unless configured otherwise.*

### 3. Frontend Installation

To run the Objective-J frontend application, make sure your web server can serve the project's root folder where the main entry file resides.

For a fast development environment, you can run a simple HTTP server in the root of the project directory where `index.html` and the Objective-J app configuration are stored:

```bash
# Using Python's built-in HTTP server:
python3 -m http.server 8080
```

Open `http://localhost:8080` in your web browser to access the graphical editor interface.

---

## 🛠️ Usage Workflow

1.  **Paste Document Text**: Paste your target document (unstructured clinical reports, contracts, notes, etc.) into the left-hand text editor pane.
2.  **Define Schema**: Use the **Graphical Schema Tree Editor** on the right to build out your desired JSON structure, specifying field keys, value types, and nested parameters.
3.  **Refine Master Prompt**: Update the instruction prompt box to direct the extraction process focused on your schema criteria.
4.  **Extract Chunks**: Select the target model from the dropdown list and click **Extract Structured Chunks**. The application will communicate with the backend to chunk, extract, validate, and highlight text ranges.
5.  **Review & Export**: Use the interactive extraction results grid to click and verify highlighted source text, modify rows if necessary, and click **Export Results as CSV** to download a spreadsheet. Or open the **Schema JSON** panel to copy your schema layout configuration for future use.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.