"""Debug-webapp: facturen uit Ridder iQ bekijken en de pdf downloaden.

Alleen voor lokaal gebruik (luistert op 127.0.0.1) en alleen-lezen: er
wordt niets naar Ridder geschreven.

Starten:  ./run.sh   en dan http://127.0.0.1:8000
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Dict, Optional

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Query
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel

from ridder import RidderClient, RidderConfig, RidderError, available_environments

load_dotenv(Path(__file__).parent / ".env")

app = FastAPI(title="Ridder factuur-debug")
STATIC = Path(__file__).parent / "static"


# Actieve omgeving en clients leven alleen in dit proces (debug-app, één
# gebruiker). De app start op test, tenzij RIDDER_ENV=live in .env staat.
_state: Dict[str, str] = {}
_clients: Dict[str, RidderClient] = {}


def current_environment() -> str:
    return _state.get("environment") or os.environ.get("RIDDER_ENV", "test").strip().lower()


def get_client() -> RidderClient:
    environment = current_environment()
    if environment not in _clients:
        _clients[environment] = RidderClient(RidderConfig.from_env(os.environ, environment=environment))
    return _clients[environment]


class EnvironmentBody(BaseModel):
    environment: str


@app.exception_handler(RidderError)
def ridder_error_handler(_request, exc: RidderError) -> JSONResponse:
    return JSONResponse(
        status_code=502,
        content={"error": str(exc), "ridderStatus": exc.status, "body": exc.body, "url": exc.url},
    )


@app.exception_handler(ValueError)
def config_error_handler(_request, exc: ValueError) -> JSONResponse:
    return JSONResponse(status_code=500, content={"error": f"Configuratie: {exc}"})


@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC / "index.html")


def _config_payload() -> dict:
    cfg = RidderConfig.from_env(os.environ, environment=current_environment())
    return {
        "environment": cfg.environment,
        "tenant": cfg.tenant,
        "administration": cfg.administration,
        "available": available_environments(os.environ),
    }


@app.get("/api/config")
def config() -> dict:
    return _config_payload()


@app.post("/api/environment")
def switch_environment(body: EnvironmentBody) -> JSONResponse:
    environment = body.environment.strip().lower()
    if environment not in ("test", "live"):
        return JSONResponse(status_code=400, content={"error": "Kies 'test' of 'live'."})
    if environment not in available_environments(os.environ):
        return JSONResponse(
            status_code=400,
            content={"error": f"{environment} is niet ingesteld: vul RIDDER_{environment.upper()}_ADMINISTRATION en _API_KEY in .env in en herstart."},
        )
    _state["environment"] = environment
    return JSONResponse(content=_config_payload())


@app.get("/api/invoices")
def invoices(
    page: int = Query(1, ge=1),
    size: int = Query(25, ge=1, le=200),
    sort: str = "id.desc",
    filter: Optional[str] = None,
    client: RidderClient = Depends(get_client),
) -> dict:
    items = client.list_sales_invoices(page=page, size=size, sort=sort, filter=filter)
    return {"page": page, "size": size, "count": len(items), "items": items}


@app.get("/api/invoices/{invoice_id}/documents")
def invoice_documents(invoice_id: int, client: RidderClient = Depends(get_client)) -> dict:
    return {"items": client.invoice_documents(invoice_id)}


@app.get("/api/documents/{document_id}/pdf")
def document_pdf(document_id: int, client: RidderClient = Depends(get_client)) -> Response:
    doc = client.download_document(document_id)
    return Response(
        content=doc.content,
        media_type=doc.content_type,
        headers={"Content-Disposition": f'attachment; filename="{doc.filename}"'},
    )
