# PatchPilot

Självhostad patchhantering för Ubuntu-servrar. Agenter på varje maskin rapporterar in status, tar emot kommandon och utför kontrollerade uppdateringar — allt styrbart från ett webbaserat kontrollcenter.

---

## Vad är PatchPilot?

PatchPilot består av två delar: en **server** (kontrollcentret) och en **agent** (körs på varje Ubuntu-maskin som ska hanteras). Agenten pratar med servern — inte tvärtom. Det innebär att inga portar behöver öppnas mot de hanterade maskinerna.

---

## Funktioner

### Agent — installeras på varje Ubuntu-server

**Enrollment (registrering)**
Agenten registrerar sig automatiskt mot servern vid första start. Den genererar ett unikt maskin-ID baserat på hostname + slumpmässigt suffix och lagrar det lokalt. Servern utfärdar ett signerat bearer-token som används vid all fortsatt kommunikation. Omregistrering hanteras automatiskt — om maskinen redan är registrerad avslutar agenten rent utan felkod.

**Check-in (incheckning)**
Agenten checkar in mot servern var femte minut och rapporterar:
- Hostname, OS-version, kernelversion, agentversion
- Antal tillgängliga uppdateringar (totalt respektive säkerhetsrelaterade)
- Om omstart krävs efter en tidigare uppdatering
- Lista med paket som har tillgängliga versioner, inklusive flagga för CVE-relaterade paket

**Jobbexekvering**
Servern kan köa kommandon som agenten plockar upp vid nästa incheckning. Agenten rapporterar status (startad → klar) och skickar tillbaka exit-kod och textoutput. Tillåtna kommandon är hårdkodade — agenten accepterar inte godtyckliga kommandon från servern.

Tillåtna jobb:
| Kommando | Vad det gör |
|---|---|
| `check_updates` | Kör `apt-get update` och räknar tillgängliga uppdateringar |
| `upgrade` | Fullständig `apt-get upgrade` |
| `security_upgrade` | Uppgraderar enbart CVE-märkta paket |
| `apt_clean` | Rensar APT-cache |
| `self_update` | Laddar ned ny agentversion från servern, verifierar SHA256-hash och ersätter sig själv atomiskt |
| `reboot` | Startar om maskinen |

**Självuppdatering**
Agenten kan uppdatera sig själv via servern. Den laddar ned den nya versionen, kontrollerar SHA256-checksumman mot serverns manifest, skriver den till en temporärfil *på samma filsystem* som den befintliga agentfilen och byter sedan ut den atomiskt med `rename()` — en halvskriven fil kan aldrig aktiveras.

**Persistens**
Agenten installeras som en `systemd`-tjänst och startas automatiskt vid omstart. Konfiguration (server-URL, token, maskin-ID) lagras i `/etc/patchpilot/agent.json`.

---

### Server — kontrollcentret

**Webbaserat kontrollcenter (Admin UI)**
Ett enterprise-orienterat mörkt gränssnitt med sticky sidebar, KPI-kort och realtidsfiltrering. Tillgängligt via webbläsaren. Kräver inte att man kan nå de hanterade maskinerna direkt.

Innehåller:
- **Fleet-vy** — alla registrerade agenter med status (online/stale/offline/disabled), patchexponering, CVE-räkning, grupper och senaste incheckning. Sökbar i realtid.
- **KPI-kort** — totalt antal agenter, antal med säkerhetsexponering, antal som kräver omstart, jobbkö-status
- **Jobbvy** — alla körda och pågående jobb med output, exit-koder och tidsstämplar
- **Grupper** — organisera maskiner i logiska grupper (t.ex. prod-servrar, staging)
- **Scheman** — automatiserade patchfönster kopplade till maskin eller grupp, med dag, klockslag och tidszon
- **Paketexponering** — alla rapporterade paket med tillgängliga uppgraderingar, CVE-flaggade markeras separat
- **Auditlogg** — loggning av administrativa händelser och agentaktivitet

**Agent-API**
REST-API som agenter kommunicerar med. Separerat från admin-gränssnittet via host-baserad routing — en publik hostname för agenter, en intern för admin. Agenter autentiseras med bearer-token per maskin.

Endpoints:
- `POST /api/v1/agent/enroll` — registrera ny maskin
- `POST /api/v1/agent/checkin` — rapportera status och hämta väntande jobb
- `POST /api/v1/agent/jobs/{id}/started` — markera jobb som startat
- `POST /api/v1/agent/jobs/{id}/result` — rapportera utfall
- `GET  /api/v1/agent/latest` — agentens senaste version och SHA256
- `GET  /agent/patchpilot-agent.py` — ladda ned agentfilen
- `GET  /install.sh` — generat installationsskript med inbyggd SHA256-verifiering

**Schemaläggare**
En bakgrundsprocess kontrollerar varje minut om något schema ska aktiveras. Den skapar automatiskt jobb för rätt maskiner eller grupper baserat på dag, klockslag och tidszon. Stödjer godkännandekrav — jobbet köas men väntar på manuellt godkännande i UI:t innan det skickas till agenten.

**Godkännandeflöde för agenter**
Nya agenter kan kräva manuellt godkännande innan de får utföra jobb. Administratören godkänner eller avvisar i UI:t. Kan stängas av för att automatgodkänna alla nya agenter.

---

### Säkerhet

**Autentisering**
- Varje agent har ett unikt bearer-token (prefix `pp_agent_` + 32 slumpmässiga bytes, URL-safe base64). Tokenet lagras enbart som bcrypt-hash i databasen.
- Admin-gränssnittet skyddas med HTTP Basic Auth via miljövariabeln `ADMIN_PASSWORD`.

**CSRF-skydd**
Alla POST-formulär i admin-gränssnittet innehåller ett CSRF-token som valideras server-side. Tokenet är HMAC-SHA256 av en hemlig nyckel + aktuell timme, giltigt i upp till två timmar. Injiceras automatiskt i alla formulär via JavaScript — ingen manuell hantering krävs av formulären.

**XSS-skydd**
Jinja2 HTML-escapar alla templatevariabler automatiskt. Bekräftelsedialoger (t.ex. "Ta bort agent?") använder `data-confirm`-attribut med en generisk text — inte dynamiska strängar inlagda i JavaScript-kod, vilket hade öppnat för XSS.

**Host-baserad routing**
Agenternas publika endpoint och admin-gränssnittet exponeras på olika hostnames. Om en request till admin-hostnamet träffar agent-API:et, eller vice versa, returneras 404. Det innebär att admin-gränssnittet aldrig behöver vara publikt tillgängligt.

**Rate limiting**
Enrollment-endpointen tillåter max 10 registreringar per IP-adress per timme. Skyddar mot automatiserade försök att registrera stora mängder falska agenter.

**Säker självuppdatering**
Agenten verifierar SHA256-checksumman på nedladdad agentfil innan den ersätter sig själv. Tempfilen skrivs på samma filsystem som målfilen för att garantera atomisk namnändring — ingen risk för halvkorrupt agentfil vid strömavbrott.

**Paketvalidering**
Servern accepterar max 500 paket per incheckning. Jobb-actions valideras mot en hårdkodad vitlista — servern kan aldrig köa ett godtyckligt shell-kommando.

---

## Teknikstack

| Komponent | Teknologi |
|---|---|
| Server runtime | Python 3.11, FastAPI, Uvicorn |
| Databas | PostgreSQL (produktion), SQLite (tester) |
| ORM | SQLAlchemy 2.0 |
| Templates | Jinja2 |
| Schemaläggare | APScheduler |
| Autentisering | bcrypt via passlib, HMAC-SHA256 |
| Agent | Python 3 stdlib only (inga externa beroenden) |
| Reverse proxy | Caddy |
| Container | Docker + Docker Compose |
| Test | pytest, 64 tester (API, säkerhet, agentlogik) |

---

## Driftsättning

```bash
cp .env.example .env
# Fyll i .env med ADMIN_PASSWORD, APP_SECRET, PUBLIC_AGENT_URL
docker compose up -d --build
```

Admin-gränssnittet nås på `http://localhost:8080/admin`.

### Deploy

```bash
./deploy.sh
```

Pushar lokala commits, pullar på servern och bygger om containern.

### Agentinstallation på Ubuntu-maskin

```bash
curl -fsSL https://din-server/install.sh | sudo bash -s -- --server https://din-server
```

Installationsskriptet verifierar agentfilens SHA256-hash mot servern innan det aktiverar den.

---

## Säkerhetsarkitektur i korthet

```
Ubuntu-maskin                   Server (intern/Cloudflare Tunnel)
┌──────────────────┐            ┌──────────────────────────────────┐
│ patchpilot-agent │ ──HTTPS──► │ /api/v1/agent/*  (publik)        │
│ (systemd-tjänst) │ ◄──jobb─── │                                  │
└──────────────────┘            │ /admin           (intern only)    │
                                └──────────────────────────────────┘
```

Agenten initierar alltid kommunikationen. Inga inkommande anslutningar krävs till de hanterade maskinerna.
