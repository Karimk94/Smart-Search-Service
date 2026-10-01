import os
import re
import json
import logging
import requests
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from dotenv import load_dotenv
import uvicorn

# Load environment variables from a .env file
load_dotenv()

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

app = FastAPI(title="Smart Search Service API")

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- GovAI LLM API Configuration ---
GOVAI_API_URL = os.getenv("GOVAI_API_URL")
GOVAI_API_KEY = os.getenv("GOVAI_API_KEY")
GOVAI_MODEL = os.getenv("GOVAI_MODEL", "qwen3-235b-fp16")

# Validate configuration
if not GOVAI_API_URL or not GOVAI_API_KEY:
    logging.critical("GOVAI_API_URL and GOVAI_API_KEY must be set in environment variables.")
    logging.critical("Please create a .env file with: GOVAI_API_URL, GOVAI_API_KEY")
else:
    logging.info(f"GovAI LLM API configured with model: {GOVAI_MODEL}")


# --- Request Model ---
class TokenizeRequest(BaseModel):
    text: str


# --- Response Models ---
class TokenizeResponse(BaseModel):
    text: str
    tokens: list
    required_concepts: list
    language: str


class HealthResponse(BaseModel):
    status: str
    model: str = None
    reason: str = None


def is_arabic(text: str) -> bool:
    """Detects if the text contains a significant number of Arabic characters."""
    if not text or not isinstance(text, str):
        return False
    return bool(re.search(r'[\u0600-\u06FF]', text))


def clean_token(token: str) -> str:
    """Removes Arabic diacritics (Tashkeel) and stray question marks from a token."""
    if not token:
        return token
    arabic_diacritics = re.compile(r'[\u064B-\u065F\u0670]')
    cleaned = re.sub(arabic_diacritics, '', token)
    cleaned = cleaned.replace('?', '')
    return cleaned.strip()


def build_tokenization_prompt(text: str, source_language: str) -> list:
    """
    Constructs the system and user messages that instruct the LLM to extract
    search-relevant tokens (key nouns, entities, concepts) from the input text.

    Returns a list of message dicts for the OpenAI-compatible chat API.
    """
    tag_lang = "Arabic" if source_language == "Arabic" else "English"
    json_key = "arabic_tags" if source_language == "Arabic" else "english_tags"

    system_msg = "You are a JSON output machine. Your only function is to output a specific JSON structure."
    user_msg = f"""Follow these steps exactly:

1.  Analyze this {source_language} text: "{text}"
2.  Extract the key nouns, entities, and concepts for broad search tags.
3.  Identify concepts the user explicitly requires to appear together. For example, "cars and plants" requires both concepts; "cars or plants" requires neither individually.
4.  **All tags MUST be in {tag_lang}.** Do not mix languages.
5.  **Correct any spelling errors and standardize abbreviations.**
6.  Remove stop words, non-essential words, and duplicate entries.
7.  If generating {tag_lang} tags, do NOT include any diacritics (Tashkeel / formations).
8.  Output **NOTHING** except for the completed JSON structure below. Do not use markdown.

COPY AND PASTE THIS TEMPLATE, THEN FILL IT IN:
{{"{json_key}": [], "required_concepts": []}}

Your entire response must be only the filled-out template."""

    return [
        {"role": "system", "content": system_msg},
        {"role": "user", "content": user_msg}
    ]


def parse_tokens_from_response(raw_text: str, source_language: str) -> list:
    """
    Robustly extracts the list of tokens from the LLM response.

    Tries (in order):
      1. Parse the raw text as JSON and read the known key.
      2. Strip markdown code fences then re-parse as JSON.
      3. Regex-extract the first JSON object from the text and parse it.
      4. Fall back to a whitespace split of the cleaned text (last resort).

    Returns a de-duplicated list of cleaned, non-empty tokens.
    """
    json_key = "arabic_tags" if source_language == "Arabic" else "english_tags"

    def _extract_from_obj(obj):
        if isinstance(obj, dict):
            # Accept either the language-specific key or a generic key.
            for key in (json_key, "tokens", "tags", "english_tags", "arabic_tags"):
                if key in obj and isinstance(obj[key], list):
                    return obj[key]
        elif isinstance(obj, list):
            return obj
        return []

    candidates = []

    # Attempt 1: direct JSON parse
    try:
        candidates.append(json.loads(raw_text))
    except (json.JSONDecodeError, TypeError):
        pass

    # Attempt 2: strip markdown fences (```json ... ``` or ``` ... ```)
    fenced = re.search(r'```(?:json)?\s*(.*?)```', raw_text, re.DOTALL | re.IGNORECASE)
    if fenced:
        try:
            candidates.append(json.loads(fenced.group(1).strip()))
        except (json.JSONDecodeError, TypeError):
            pass

    # Attempt 3: regex-extract the first {...} block
    brace_match = re.search(r'\{.*\}', raw_text, re.DOTALL)
    if brace_match:
        try:
            candidates.append(json.loads(brace_match.group(0)))
        except (json.JSONDecodeError, TypeError):
            pass

    for cand in candidates:
        tokens = _extract_from_obj(cand)
        if tokens:
            cleaned_tokens = []
            seen = set()
            for tok in tokens:
                tok_str = clean_token(str(tok))
                if tok_str and tok_str.lower() not in seen:
                    seen.add(tok_str.lower())
                    cleaned_tokens.append(tok_str)
            if cleaned_tokens:
                return cleaned_tokens

    # Attempt 4: last-resort whitespace split of the cleaned raw text
    fallback = []
    seen = set()
    for word in raw_text.split():
        cleaned_word = clean_token(word.strip('",[]{}:'))
        if cleaned_word and len(cleaned_word) > 1 and cleaned_word.lower() not in seen:
            seen.add(cleaned_word.lower())
            fallback.append(cleaned_word)
    return fallback


def parse_required_concepts_from_response(raw_text: str) -> list:
    """Extracts explicit must-match concepts from the structured LLM response."""
    candidates = []
    try:
        candidates.append(json.loads(raw_text))
    except (json.JSONDecodeError, TypeError):
        pass

    fenced = re.search(r'```(?:json)?\s*(.*?)```', raw_text, re.DOTALL | re.IGNORECASE)
    if fenced:
        try:
            candidates.append(json.loads(fenced.group(1).strip()))
        except (json.JSONDecodeError, TypeError):
            pass

    brace_match = re.search(r'\{.*\}', raw_text, re.DOTALL)
    if brace_match:
        try:
            candidates.append(json.loads(brace_match.group(0)))
        except (json.JSONDecodeError, TypeError):
            pass

    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        concepts = candidate.get("required_concepts")
        if not isinstance(concepts, list):
            continue
        cleaned = []
        seen = set()
        for concept in concepts:
            value = clean_token(str(concept))
            if value and value.casefold() not in seen:
                seen.add(value.casefold())
                cleaned.append(value)
        if cleaned:
            return cleaned[:6]
    return []


def get_search_intent_from_govai(text: str, source_language: str) -> tuple[list, list]:
    """
    Calls the GovAI chat/completions endpoint to extract search tokens from text.
    Returns broad tokens and explicit must-match concepts, or raises on failure.
    """
    messages = build_tokenization_prompt(text, source_language)

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {GOVAI_API_KEY}",
    }

    payload = {
        "model": GOVAI_MODEL,
        "messages": messages,
        "stream": False,
        "max_tokens": 1024,
        "temperature": 0.2,
    }

    response = requests.post(
        GOVAI_API_URL,
        headers=headers,
        json=payload,
        timeout=60
    )
    response.raise_for_status()

    result = response.json()

    # Extract content from OpenAI-compatible (non-streaming) response format
    choices = result.get("choices", [])
    if not choices:
        raise ValueError("No choices returned from API")

    content = choices[0].get("message", {}).get("content", "")
    if not content:
        raise ValueError("Empty content returned from API")

    return (
        parse_tokens_from_response(content, source_language),
        parse_required_concepts_from_response(content),
    )


@app.post("/tokenize", response_model=TokenizeResponse)
async def tokenize(req: TokenizeRequest):
    """
    Receives a free-text search query (sentence or phrase) and returns a list of
    logical search tokens (key nouns, entities, concepts) extracted by the LLM.
    These tokens can be used to enrich the downstream embedding + SQL search.
    """
    if not req.text or not req.text.strip():
        raise HTTPException(status_code=400, detail="No 'text' field provided or text is empty.")

    if not GOVAI_API_URL or not GOVAI_API_KEY:
        raise HTTPException(
            status_code=503,
            detail="Smart Search service is not configured. Missing API credentials."
        )

    try:
        source_language = "Arabic" if is_arabic(req.text) else "English"
        tokens, required_concepts = get_search_intent_from_govai(req.text, source_language)

        # If the LLM returns nothing usable, fall back to whitespace split of the input
        if not tokens:
            tokens = [w.strip() for w in req.text.split() if w.strip()]

        return TokenizeResponse(
            text=req.text,
            tokens=tokens,
            required_concepts=required_concepts,
            language=source_language,
        )

    except requests.exceptions.RequestException as e:
        logging.error(f"API request error for text: {req.text[:50]}... Error: {e}", exc_info=True)
        raise HTTPException(
            status_code=502,
            detail="Failed to connect to LLM API."
        )

    except (KeyError, IndexError, ValueError) as e:
        logging.error(f"API response parsing error for text: {req.text[:50]}... Error: {e}", exc_info=True)
        raise HTTPException(
            status_code=500,
            detail="Failed to parse LLM API response."
        )

    except Exception as e:
        logging.error(f"Error generating tokens for text: {req.text[:50]}... Error: {e}", exc_info=True)
        raise HTTPException(
            status_code=500,
            detail="Failed to generate search tokens."
        )


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint to verify service status."""
    if not GOVAI_API_URL or not GOVAI_API_KEY:
        return HealthResponse(status="unhealthy", reason="Missing API configuration")

    return HealthResponse(status="healthy", model=GOVAI_MODEL)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5006))
    logging.info(f"Starting Smart Search Service on port {port}...")
    uvicorn.run(app, host="0.0.0.0", port=port)




