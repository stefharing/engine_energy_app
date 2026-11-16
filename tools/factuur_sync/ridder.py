"""Kleine, alleen-lezen client voor de Ridder iQ v2 REST API.

Bewust los van de webapp: het latere server-/cronscript importeert dit
module en gebruikt dezelfde drie aanroepen:

    1. list_sales_invoices()   GET /sales/salesinvoices
    2. invoice_documents(id)   GET /sales/salesinvoices/{id}/documents
    3. download_document(id)   GET /iqsystem/documents/{id}/document

Het uploaden naar Exact Online (de laatste stap in het takenoverzicht) hoort
in een eigen module (exact.py), zodat deze client niets van Exact weet.
"""

from __future__ import annotations

import base64
import json
import os
import re
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional
from urllib.parse import quote

import httpx

BASE_HOST = "https://api.eciridderiq.com"


class RidderError(Exception):
    """Ridder gaf een foutstatus (of geen bruikbaar antwoord) terug."""

    def __init__(self, status: int, body: str, url: str = ""):
        super().__init__(f"Ridder antwoordde {status} op {url}: {body[:300]}")
        self.status = status
        self.body = body
        self.url = url


@dataclass(frozen=True)
class RidderConfig:
    tenant: str
    administration: str
    api_key: str
    environment: str  # "test" of "live"

    @property
    def base_url(self) -> str:
        return f"{BASE_HOST}/{quote(self.tenant)}/{self.administration}/v2"

    @classmethod
    def from_env(
        cls, env: Optional[Mapping[str, str]] = None, environment: Optional[str] = None
    ) -> "RidderConfig":
        """Leest de instellingen uit omgevingsvariabelen (zie .env.example).

        Standaard wordt de TESTadministratie gebruikt; voor live moet
        RIDDER_ENV=live uitdrukkelijk gezet worden (of [environment] mee
        gegeven worden, zoals de schakelaar in de webapp doet).
        """
        env = os.environ if env is None else env
        environment = (environment or env.get("RIDDER_ENV", "test")).strip().lower()
        if environment not in ("test", "live"):
            raise ValueError("RIDDER_ENV moet 'test' of 'live' zijn.")
        prefix = f"RIDDER_{environment.upper()}"
        administration = env.get(f"{prefix}_ADMINISTRATION", "").strip()
        api_key = env.get(f"{prefix}_API_KEY", "").strip()
        missing = [
            name
            for name, value in (
                (f"{prefix}_ADMINISTRATION", administration),
                (f"{prefix}_API_KEY", api_key),
            )
            if not value
        ]
        if missing:
            raise ValueError("Ontbrekend in .env: " + ", ".join(missing))
        return cls(
            tenant=env.get("RIDDER_TENANT", "Engine Energy B.V.").strip(),
            administration=administration,
            api_key=api_key,
            environment=environment,
        )


def available_environments(env: Optional[Mapping[str, str]] = None) -> List[str]:
    """De omgevingen waarvoor administratie en API-key zijn ingevuld."""
    env = os.environ if env is None else env
    return [
        name
        for name in ("test", "live")
        if env.get(f"RIDDER_{name.upper()}_ADMINISTRATION", "").strip()
        and env.get(f"RIDDER_{name.upper()}_API_KEY", "").strip()
    ]


@dataclass(frozen=True)
class DownloadedDocument:
    content: bytes
    content_type: str
    filename: str


def _items(body: Any) -> List[Dict[str, Any]]:
    """Lijsten komen als {'data': [...]} (soms {'items': [...]}) of kaal."""
    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        for key in ("data", "items"):
            if isinstance(body.get(key), list):
                return body[key]
    return []


def _unwrap_pdf(content: bytes) -> bytes:
    """Geeft de pdf-bytes. Ridder levert het bestand mogelijk als base64 in
    JSON; dat is nog niet tegen de echte API bevestigd, dus beide kunnen."""
    if content.startswith(b"%PDF"):
        return content
    try:
        data = json.loads(content)
    except ValueError:
        return content
    candidates: List[str] = []
    if isinstance(data, str):
        candidates.append(data)
    elif isinstance(data, dict):
        candidates.extend(v for v in data.values() if isinstance(v, str) and len(v) > 100)
    for text in candidates:
        try:
            decoded = base64.b64decode(text)
        except ValueError:
            continue
        if decoded.startswith(b"%PDF"):
            return decoded
    return content


def _filename(headers: Mapping[str, str], fallback: str) -> str:
    match = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)"?', headers.get("content-disposition", ""))
    return match.group(1) if match else fallback


class RidderClient:
    def __init__(
        self,
        config: RidderConfig,
        transport: Optional[httpx.BaseTransport] = None,
        timeout: float = 30.0,
    ):
        self.config = config
        self._http = httpx.Client(
            base_url=config.base_url,
            headers={"X-API-KEY": config.api_key},
            timeout=timeout,
            transport=transport,
        )

    def close(self) -> None:
        self._http.close()

    def _get(self, path: str, params: Optional[Dict[str, Any]] = None, accept: str = "application/json") -> httpx.Response:
        params = {k: v for k, v in (params or {}).items() if v not in (None, "")}
        try:
            response = self._http.get(path, params=params, headers={"Accept": accept})
        except httpx.HTTPError as exc:
            raise RidderError(0, f"Geen verbinding met Ridder: {exc}", path) from exc
        if response.status_code >= 400:
            raise RidderError(response.status_code, response.text, str(response.url))
        return response

    def list_sales_invoices(
        self,
        page: int = 1,
        size: int = 25,
        sort: str = "id.desc",
        filter: Optional[str] = None,
    ) -> List[Dict[str, Any]]:
        body = self._get(
            "/sales/salesinvoices",
            {"page": page, "size": size, "sort": sort, "filter": filter},
        ).json()
        return _items(body)

    def invoice_documents(self, invoice_id: int, page: int = 1, size: int = 200) -> List[Dict[str, Any]]:
        # Ook dit endpoint is gepagineerd: zonder page geeft Ridder een 400.
        return _items(
            self._get(
                f"/sales/salesinvoices/{invoice_id}/documents",
                {"page": page, "size": size},
            ).json()
        )

    def download_document(self, document_id: int) -> DownloadedDocument:
        response = self._get(f"/iqsystem/documents/{document_id}/document", accept="*/*")
        content = _unwrap_pdf(response.content)
        is_pdf = content.startswith(b"%PDF")
        return DownloadedDocument(
            content=content,
            content_type="application/pdf"
            if is_pdf
            else response.headers.get("content-type", "application/octet-stream"),
            filename=_filename(response.headers, f"document-{document_id}.pdf"),
        )
