# factuur_sync

Eerste opzet voor de koppeling "factuur-pdf van Ridder iQ naar Exact Online".
Nu: een lokale debug-webapp om de Ridder-kant te testen. Later: een script
op een server dat dezelfde `ridder.py` gebruikt.

## Starten (Mac)

```
cd tools/factuur_sync
cp .env.example .env     # en vul de testadministratie en API-key in
./run.sh                 # daarna http://127.0.0.1:8000
```

De webapp is alleen-lezen en draait op 127.0.0.1. Standaard staat hij op de
**testadministratie**; de kleur van het label (groen TEST, rood LIVE) laat zien
waar je op werkt. Live gebruik je alleen door in `.env` `RIDDER_ENV=live` te
zetten.

Tests (geen netwerk nodig): `.venv/bin/pip install pytest && .venv/bin/pytest`

## Opbouw

| Bestand | Taak |
|---|---|
| `ridder.py` | Ridder v2-client: facturen, documenten bij een factuur, pdf downloaden |
| `app.py` | Dunne FastAPI-laag voor de debugpagina |
| `static/index.html` | Lijst met facturen, per factuur de documenten en een download-knop |

## Ridder-aanroepen (uit het takenoverzicht)

1. `GET /sales/salesinvoices` met `page`, `size`, `sort`, `filter`
2. `GET /sales/salesinvoices/{id}/documents` geeft het document-id
3. `GET /iqsystem/documents/{id}/document` geeft de pdf

## Nog niet bevestigd tegen de echte API

- De exacte veldnamen van een factuur (de tabel toont automatisch de eerste
  zes eenvoudige velden; met de knop JSON zie je alles).
- Of het downloaden (aanroep 3) de pdf direct teruggeeft of als base64 in json. `ridder.py` kan
  beide aan.
- Welke filter Ridder voor "gejournaliseerd" aanbiedt; probeer het in het
  filterveld en kijk in de JSON welk veld de journaalstatus bevat.

## Volgende stappen

- `exact.py`: het uploaden naar Exact Online als bijlage.
- Het script dat gejournaliseerde facturen vindt en bijhoudt welke al zijn
  doorgestuurd (een kleine lijst of sqlite, zodat niets dubbel gaat).
