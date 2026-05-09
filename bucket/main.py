"""
Bucket — Dragline JS crawl and PDF extraction service
Exposes:
  POST /crawl   {"url": "..."}  → {"text", "title", "final_url", "word_count", "error"}
  POST /extract  multipart file  → {"text", "tables", "error"}
"""

import asyncio
import io
import logging
import re
from contextlib import asynccontextmanager

import pdfplumber
import uvicorn
from fastapi import FastAPI, File, UploadFile
from playwright.async_api import Browser, async_playwright
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("bucket")

# ── Browser lifecycle ──────────────────────────────────────────────────────────

_browser: Browser | None = None
_playwright_ctx = None
_semaphore: asyncio.Semaphore | None = None
MAX_CONCURRENT = 4


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _browser, _playwright_ctx, _semaphore
    log.info("Starting Playwright / Chromium…")
    _playwright_ctx = await async_playwright().start()
    _browser = await _playwright_ctx.chromium.launch(
        headless=True,
        args=[
            "--no-sandbox",
            "--disable-setuid-sandbox",
            "--disable-dev-shm-usage",
            "--disable-gpu",
            "--disable-extensions",
        ],
    )
    _semaphore = asyncio.Semaphore(MAX_CONCURRENT)
    log.info("Bucket ready.")
    yield
    log.info("Shutting down Playwright…")
    await _browser.close()
    await _playwright_ctx.stop()


app = FastAPI(title="Bucket", description="Dragline crawl and PDF extraction service", lifespan=lifespan)

# ── Models ─────────────────────────────────────────────────────────────────────

class CrawlRequest(BaseModel):
    url: str


# ── Helpers ────────────────────────────────────────────────────────────────────

def _clean(text: str) -> str:
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def _word_count(text: str) -> int:
    return len(text.split()) if text else 0


# ── Routes ─────────────────────────────────────────────────────────────────────

@app.post("/crawl")
async def crawl(req: CrawlRequest):
    async with _semaphore:
        context = None
        try:
            context = await _browser.new_context(
                user_agent="Mozilla/5.0 (compatible; Dragline/1.0; entity intelligence)",
                ignore_https_errors=True,
                java_script_enabled=True,
            )
            page = await context.new_page()

            # Block images, fonts, media to speed things up
            await page.route(
                "**/*",
                lambda route: route.abort()
                if route.request.resource_type in ("image", "media", "font")
                else route.continue_(),
            )

            response = await page.goto(req.url, wait_until="networkidle", timeout=30_000)
            final_url = page.url
            title = await page.title()

            text = await page.evaluate("""() => {
                document.querySelectorAll('script, style, noscript, iframe').forEach(el => el.remove());
                return document.body ? document.body.innerText : '';
            }""")

            text = _clean(text)

            log.info(f"Crawled {req.url} → {_word_count(text)} words")
            return {
                "text": text,
                "title": title,
                "final_url": final_url,
                "word_count": _word_count(text),
                "error": None,
            }

        except Exception as exc:
            log.warning(f"Crawl failed for {req.url}: {exc}")
            return {
                "text": None,
                "title": None,
                "final_url": req.url,
                "word_count": 0,
                "error": str(exc),
            }
        finally:
            if context:
                await context.close()


@app.post("/extract")
async def extract(file: UploadFile = File(...)):
    try:
        content = await file.read()
        text_parts = []
        tables = []

        with pdfplumber.open(io.BytesIO(content)) as pdf:
            for page in pdf.pages:
                page_text = page.extract_text()
                if page_text:
                    text_parts.append(page_text.strip())

                for table in page.extract_tables():
                    if table:
                        tables.append(table)

        text = "\n\n".join(text_parts)
        log.info(f"Extracted PDF '{file.filename}': {_word_count(text)} words, {len(tables)} tables")
        return {"text": text, "tables": tables, "error": None}

    except Exception as exc:
        log.warning(f"PDF extraction failed for '{file.filename}': {exc}")
        return {"text": None, "tables": [], "error": str(exc)}


@app.get("/health")
async def health():
    return {"status": "ok", "browser": _browser is not None and _browser.is_connected()}


if __name__ == "__main__":
    uvicorn.run("main:app", host="127.0.0.1", port=3002, workers=1)
