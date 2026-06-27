# Visual Schema-Driven Chunked Data Extractor

An interactive, visual schema editor and text-extraction application. This project pairs a web-based **Cappuccino (Objective-J)** desktop frontend with a **Mojolicious (Perl)** backend to extract structured, nested data from unstructured text using Large Language Models (LLMs) and automatically resolve terminology via dense retrieval.

---

## System Architecture

```
┌──────────────────────────────────────┐          ┌───────────────────────────┐
│         Objective-J Frontend         │          │    Mojolicious Backend    │
│  ┌────────────────────────────────┐  │  JSON    │  ┌─────────────────────┐  │
│  │ CPOutlineView (Visual Schema)  │  ├─────────►│  │ Chunking & Merging  │  │
│  └────────────────────────────────┘  │  Request │  └──────────┬──────────┘  │
│  ┌────────────────────────────────┐  │          │             ▼             │
│  │ CPTextView (Text Highlights)   │  │◄─────────┤  ┌─────────────────────┐  │
│  └────────────────────────────────┘  │  JSON    │  │ Schema Validation   │  │
│  ┌────────────────────────────────┐  │  Response│  │  & Self-Correction  │  │
│  │ CPTableView & CSV Export       │  │          │  └──────────┬──────────┘  │
│  └────────────────────────────────┘  │          │             ▼             │
└──────────────────────────────────────┘          │      Dense Retrieval      │
                                                  │    Vector Search Lookup   │
                                                  │             ▼             │
                                                  │       Target LLM API      │
                                                  └───────────────────────────┘
```
<img width="1079" height="783" alt="Bildschirmfoto 2026-06-27 um 11 27 06" src="https://github.com/user-attachments/assets/d18570b8-c591-4cd2-aae5-8d8b178e801f" />

---

## Features

*   **Graphical Schema Tree Editor**: Create, modify, and nest schema fields dynamically (supporting `string`, `number`, `array`, and `object` types).
*   **Dense-Retrieval Integration**: Seamlessly maps raw text extractions to canonical database entries. Extracted strings are resolved using semantic dense vector searches (`top_k=1`) against user-selected catalog systems to retrieve unified identifiers.
*   **Automatic Chunking & Merging**: Automatically splits long inputs to match context window limitations and merges the results into a single structured output.
*   **Source Text Highlighting**: Color-coded visualization mapping extracted fields back to their exact coordinates in the source text.
*   **Self-Correction Loop**: Validates JSON outputs against the user-defined schema and performs corrective retry prompts if type or structure mismatches occur.
*   **Data Export**: Instant tabular viewing and export of resolved paths and values as a CSV spreadsheet.

---

## Getting Started

### 1. Prerequisites

*   **Perl 5.20+**
*   An active LLM connection (OpenAI, local Ollama, or any OpenAI-compatible gateway)
*   An endpoint hosting embedding indices for semantic vector search (such as the Patchbay API gateway)

### 2. Setup

Clone the repository and install the Perl dependencies:

```bash
# Install Mojolicious and dependencies
cpanm Mojolicious::Lite Encode File::Spec
```

Set up your environment variables for your chosen LLM endpoint and dense-retrieval vector database:

```bash
export VLLM_API_KEY="your-api-key"
export VLLM_ENDPOINT="https://your-llm-gateway.example.com/v1/chat/completions"
export VLLM_MODEL="gpt-oss-120b"
export PATCHBAY_URL="http://10.210.21.201:3036"
```

Start the Mojolicious development server (defaults to port 3000):

```bash
morbo ./backend.pl  --listen "http://*:3000"
```

Open `http://localhost:3000/Frontend/index.html` in your web browser to run the application.

---

## Usage Workflow

1.  **Input Text**: Paste unstructured text into the left pane.
2.  **Configure Schema**: Define keys and structural hierarchy using the Schema Tree Editor on the right.
3.  **Enable Dense Retrieval**: Assign specific fields to lookup targets (vector collections) to resolve raw extracted text to standard, coded database equivalents.
4.  **Extract**: Click **Extract Structured Chunks**. The application chunks the text, runs extraction, validates consistency, queries the dense-retrieval API, and returns highlighted results.
5.  **Export**: Click **Export Results as CSV** to download a spreadsheet of the resolved extraction records.
