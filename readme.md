# Smart Search Service

A standalone FastAPI microservice that turns a free-text search query (a sentence
or phrase) into broad search **tokens** and explicit **required concepts** using
the GovAI LLM API. Tokens broaden lexical retrieval; required concepts preserve
clear conjunctions such as "cars and plants".

It is the "smart search box" companion to the **Embedding Service**: where the
Embedding Service converts text into a vector, this service converts a sentence
into the most relevant search terms.

## 1. How It Works

1. A search query (e.g. *"photos from the Dubai Metro opening ceremony"*) is sent
   to `POST /tokenize` as `{"text": "..."}`.
2. The service auto-detects the language (Arabic vs English) and builds a prompt
   that asks the LLM to extract the key nouns, entities, and concepts — correcting
   spelling, removing stop words, and standardizing the output language.
3. The LLM (`qwen3-235b-fp16` by default) returns a JSON object with the tokens.
4. The service robustly parses the JSON (handling markdown fences, partial JSON,
   etc.) and returns:

```json
{
  "text": "photos from the Dubai Metro opening ceremony",
   "tokens": ["Dubai Metro", "opening ceremony", "photos"],
   "required_concepts": [],
  "language": "English"
}
```

If the LLM fails to return usable JSON, the service falls back to a plain
whitespace split of the input text so search is never broken.

## 2. Why `qwen3-235b-fp16`?

Token extraction is a lightweight **text-generation / extraction** task that
requires reliable structured (JSON) output — not embeddings, vision, or audio.
From the available GovAI models, `qwen3-235b-fp16` is the best fit because it is
a large, capable instruction-following model that reliably produces structured
JSON, is fast enough in fp16, and is already proven in production for the
`tokenize` task in the Translator Rephraser service. Embedding models
(`qwen3-embedding-8b`), rerankers (`qwen3-reranker-8b`), vision/audio/OCR models,
and the very large MoE models (`qwen35-397b*`) are either the wrong type or
unnecessarily heavy for this task.

## 3. Endpoints

### `POST /tokenize`
Request body:
```json
{ "text": "any free-text search query" }
```
Response body:
```json
{ "text": "...", "tokens": ["...", "..."], "required_concepts": ["..."], "language": "English" }
```

### `GET /health`
```json
{ "status": "healthy", "model": "qwen3-235b-fp16" }
```

## 4. Setup and Installation

### 4.1 Online (development machine)

1. Navigate to this directory.
2. Create a virtual environment: `python -m venv venv`
3. Activate it: `venv\Scripts\activate`
4. Install dependencies: `pip install -r requirements.txt`
5. Create a `.env` file (copy from `.env.example`):
   ```
   GOVAI_API_URL=https://llmapi.govai.ae/chat/completions
   GOVAI_API_KEY=your-api-key-here
   GOVAI_MODEL=qwen3-235b-fp16
   ```
6. Run the service: `run.bat` (or `python app.py`). It runs on **port 5006**.

### 4.2 Offline (production server — no internet)

This service ships with a complete offline-install workflow using a local wheel
cache, so it can be deployed on a server with no internet access.

**Step A — Prepare the package bundle (on a machine WITH internet):**

1. Run `download_packages.bat`. This downloads every wheel (including transitive
   dependencies) into a `packages\` folder. It downloads wheels for the current
   platform AND explicitly for **Python 3.12** (both `win_amd64` and `win32`),
   so the compiled C-extension wheels (`charset_normalizer`, `pydantic_core`)
   will match the server's Python version.
2. Run `create_archive.bat`. This builds a timestamped zip file (e.g.
   `Smart_Search_Service_2026-09-29_14-30-00.zip`) in the parent directory,
   containing the whole service — `app.py`, all `.bat` files, `web.config`,
   `requirements.txt`, `.env.example`, `readme.md`, and the `packages\` wheel
   cache. It excludes `venv\`, `__pycache__\`, `.env`, and logs so the archive
   is clean and ready to deploy.

**Step B — Deploy to the offline server:**

1. Copy the zip archive to the server and extract it.
2. Run `install_packages.bat`. This:
   - Creates a fresh `venv\` virtual environment (`python -m venv venv`).
   - Activates it.
   - Installs all dependencies **offline** from `packages\`:
     `pip install --no-index --find-links packages -r requirements.txt`
3. Copy `.env.example` to `.env` and fill in your `GOVAI_API_URL`,
   `GOVAI_API_KEY`, and `GOVAI_MODEL`.
4. Run `run.bat` to start the service on port 5006.

> **Note:** The `packages\` cache includes wheels for Python 3.12 (both 64-bit
> and 32-bit Windows). If the server runs a different Python version, re-run
> `download_packages.bat` and update the `--python-version` flags to match.

### 4.3 Batch file reference

| File | Purpose |
|------|---------|
| `download_packages.bat` | **Online machine.** Downloads all wheels into `packages\` — for the current platform plus explicitly for Python 3.12 (`win_amd64` + `win32`). |
| `create_archive.bat` | **Online machine.** Builds a timestamped `.zip` of the whole service (including `packages\`) in the parent directory, ready to copy to the offline server. Excludes `venv\`, `__pycache__\`, `.env`, and logs. |
| `install_packages.bat` | **Offline server.** Creates a fresh venv + installs from `packages\` (no internet required). |
| `run.bat` | Starts the uvicorn server on port 5006 (uses venv if present). |


## 5. Integration (Backend — EDMS API)

This service is called by the EDMS API backend, exactly like the Embedding
Service. The frontend is unchanged.

In the EDMS API:

- `api_client.py` — `get_search_intent(text)` calls
  `{SMART_SEARCH_API_URL}/tokenize`.
- `database/documents.py` — `fetch_documents_from_oracle` uses tokens to broaden
   SQL `LIKE` candidates and requires every explicitly required concept to match
   indexed text. It independently embeds the original sentence and combines
   keyword/vector rankings with reciprocal-rank fusion.
  If the Smart Search Service is unavailable, it falls back to the raw
  `search_term` exactly as before.

Add to the EDMS API `.env`:
```
SMART_SEARCH_API_URL="http://localhost:5006/"
```

## 6. IIS Deployment

The included `web.config` uses the `httpPlatformHandler` to run uvicorn under
IIS, mirroring the Embedding Service configuration. Set the `GOVAI_*`
environment variables in the `<environmentVariables>` block (or via Azure app
settings).
