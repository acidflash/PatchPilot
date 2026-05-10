# PatchPilot — Teknisk internaldokumentation

Detaljerad genomgång av hur varje funktion fungerar och vad som används under ytan.

---

## Innehåll

1. [Systemarkitektur](#systemarkitektur)
2. [Datamodell](#datamodell)
3. [Agentfunktioner](#agentfunktioner)
4. [Server — autentisering och säkerhet](#server--autentisering-och-säkerhet)
5. [Server — agent-API](#server--agent-api)
6. [Server — admin-API](#server--admin-api)
7. [Schemaläggaren](#schemaläggaren)
8. [Notifieringar](#notifieringar)
9. [Installationsskript](#installationsskript)
10. [Testsvit](#testsvit)

---

## Systemarkitektur

```
┌─────────────────────────────────────────────────────────────────┐
│  Ubuntu-maskin                                                  │
│  /usr/local/bin/patchpilot-agent   (Python 3, inga deps)       │
│  systemd-timer → var 5:e minut                                  │
└────────────────────┬────────────────────────────────────────────┘
                     │ HTTPS  (bearer-token)
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Server  (Docker)                                               │
│  ┌──────────────┐   ┌────────────────────┐   ┌───────────────┐ │
│  │   Caddy      │   │  FastAPI / Uvicorn  │   │  PostgreSQL   │ │
│  │  (reverse    │──►│  Python 3.11        │──►│  SQLAlchemy   │ │
│  │   proxy)     │   │  port 8000          │   │  ORM          │ │
│  └──────────────┘   └────────────────────┘   └───────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

Caddy lyssnar på port 80/443 och vidarebefordrar till FastAPI på port 8000. FastAPI hanterar både agentens REST-API och admin-webbgränssnittet i samma process. Databasen nås uteslutande via SQLAlchemy ORM — inga råa SQL-strängar används i applikationskoden.

---

## Datamodell

Sex tabeller, definierade i `backend/app/models.py` med SQLAlchemy 2.0:s `Mapped`-syntax (typad ORM):

### `machines`
En rad per registrerad agent. Lagrar identitet (`machine_id`, `hostname`), autentisering (`token_hash`), systeminfo (`os_version`, `kernel_version`, `agent_version`), patchstatus (`updates_available`, `security_updates_available`, `reboot_required`), beteendeflags (`auto_patch`, `auto_reboot`), livscykelstatus (`active`, `approved`, `approval_status`) och tidsstämplar (`first_seen`, `last_seen`, `last_job_at`, `last_success_at`).

**Viktigt**: `token_hash` innehåller aldrig klartext-tokenet — bara en bcrypt-hash. Klartext-tokenet existerar enbart i svaret från enrollment-anropet och i agentens konfigurationsfil.

### `jobs`
En rad per jobb. Kopplas till en maskin via `machine_id` (foreign key). Innehåller `action` (t.ex. `upgrade`), `status` (`pending` → `running` → `success`/`failed`), `allow_reboot`-flag, `output` (max 30 000 tecken), `exit_code` och tre tidsstämplar (`created_at`, `started_at`, `finished_at`).

### `groups`
Namngivna grupper med `name` (unik) och `description`. Kopplas till maskiner via `machine_groups`.

### `machine_groups`
Bryggtabell (`machine_id`, `group_id`) med unik-constraint på kombinationen — en maskin kan vara med i samma grupp bara en gång.

### `package_updates`
En rad per paket-per-maskin. Uppdateras helt vid varje incheckning — alla gamla rader för maskinen raderas och de nya skrivs in (`UPSERT`-beteende via delete+insert). Unik-constraint på `(machine_id, package)`. Lagrar `current_version`, `candidate_version` och `security`-flag.

### `audit_logs`
Oföränderlig logg. En rad per administrativ händelse. Innehåller `actor` (t.ex. `admin` eller `agent`), `action` (t.ex. `job_created`, `machine_approved`), `target_type`/`target_id`, `ip_address` och fritext `details`.

### `schedules`
Konfiguration för återkommande jobb. Innehåller målspecifikation (`target_type`: `machine` eller `group`, `target_id`), timing (`day_of_week`, `time_of_day`, `timezone`), `action`, samt flags (`allow_reboot`, `require_approval`, `enabled`). `last_run_key` är en dedupliceringsträng på formatet `schedule_id:YYYY-MM-DD` som förhindrar att samma schema körs mer än en gång per dag.

---

## Agentfunktioner

Agenten (`agent/patchpilot-agent.py`) är ett enda Python-skript utan externa beroenden — enbart standardbiblioteket. Det gör det möjligt att köra det på Ubuntu utan `pip install`.

### `get_machine_id()`

```
/etc/patchpilot/machine-id
```

Läser filen om den finns. Annars genereras ett ID på formatet `hostname-xxxxxxxxxxxx` där sufixet är 12 hex-tecken från `uuid.uuid4()`. ID:t skrivs till filen med `chmod 600`. Filen är persistent — ID:t ändras inte om agenten ominstalleras, så länge filen finns kvar.

### `run(cmd)`

Kör ett shell-kommando via `subprocess.run(..., shell=True)`. Sätter `DEBIAN_FRONTEND=noninteractive` och `NEEDRESTART_MODE=a` i miljön så att APT aldrig frågar interaktivt. Timeout är 1800 sekunder som standard (30 minuter). Returnerar `(returncode, stdout+stderr)`.

### `parse_apt_updates()`

Kör `apt list --upgradable 2>/dev/null | tail -n +2` och parsar varje rad med regex. En typisk rad ser ut så:

```
vim/jammy 9.1.0-1ubuntu1 amd64 [upgradable from: 9.0.0-1]
```

Parsning:
- **Paketnamn**: Allt före första `/`
- **Kandidatversion**: `parts[1]` (andrakolumnen)
- **Nuvarande version**: Regex `\[upgradable from:\s*([^\]]+)\]`
- **CVE-flag**: Söker efter strängen `security` i raden (t.ex. `jammy-security` i källnamnet)

### `apt_check_counts(packages)`

Försöker använda `/usr/lib/update-notifier/apt-check` (finns på de flesta Ubuntu-installationer) för exaktare räkning. Parsar output med regex `(\d+)\s*;\s*(\d+)`. Faller tillbaka till att räkna `packages`-listan om verktyget saknas.

### `collect_status()`

Kör `apt-get update` (synkroniserar paketlistor), anropar sedan `parse_apt_updates()` och `apt_check_counts()`. Kontrollerar `/var/run/reboot-required` — filen skapas av APT efter en uppdatering som kräver omstart. Läser `/etc/os-release` för OS-version och `platform.release()` för kernelversion.

### `enroll(server_url)`

Anropar `POST /api/v1/agent/enroll` med maskin-ID, hostname, agentversion, OS-version och kernelversion. Om servern svarar med `"message": "machine already enrolled"` skriver agenten ett informationsmeddelande och avslutar med exit code 0 (inte ett fel). Om svaret innehåller `agent_token` skrivs det till `/etc/patchpilot/agent.json` med `chmod 600`.

### `bootstrap_if_needed()`

Kontrollerar om `/etc/patchpilot/agent.json` finns. Om inte, läser den `/etc/patchpilot/bootstrap.json` (sätts av template-installationsskriptet) och kör enrollment automatiskt. Används för VM-template-flödet där enrollment inte sker vid installation utan vid första start av den klonade VM:n.

### `self_update_agent(update_url, expected_sha256)`

1. Laddar ned den nya agentfilen från `update_url` via `urllib.request`
2. Kontrollerar att filen börjar med `#!/usr/bin/env python3` (sanity-check)
3. Beräknar `sha256sum` av det nedladdade innehållet
4. Jämför med `expected_sha256` om det angetts — avbryter vid mismatch
5. Skriver till en temporärfil i **samma katalog** som den befintliga agentfilen (`/usr/local/bin/`) med `tempfile.NamedTemporaryFile(dir=current_path.parent)`
6. Sätter `chmod 755` på tempfilen
7. Skapar backup i `/usr/local/bin/patchpilot-agent.bak-{version}`
8. Anropar `tmp_path.replace(current_path)` — detta är en **atomisk `rename()`** på Linux, aldrig en partiell fil

Anledningen till att tempfilen måste ligga i samma katalog (inte `/tmp`): `rename()` är bara atomisk inom samma filsystem. Om tempfilen är på `/tmp` och målet är på `/usr/local/bin` (vilket kan vara ett annat filsystem) faller operativsystemet tillbaka till copy+delete, vilket inte är atomiskt.

### `execute_job(job)`

Validerar `action` mot `ALLOWED_ACTIONS = {"apt_clean", "check_updates", "reboot", "security_upgrade", "self_update", "upgrade"}` — ett jobbsvar från servern med en okänd action ignoreras med felkod. Kör sedan rätt kommando baserat på action. `reboot` och `upgrade` respekterar `allow_reboot`-flaggan.

### `run_once()`

Huvudflödet vid varje körning:
1. Läs konfiguration (eller bootstrap vid behov)
2. Samla status (`collect_status`)
3. Checka in mot servern (`POST /api/v1/agent/checkin`)
4. Om servern rapporterar att agenten är `pending_approval` — avsluta utan att köra jobb
5. Kontrollera om agenten är utdaterad (`agent_update.outdated`) och om `auto_agent_update` är aktiverat — uppdatera i så fall sig själv och avsluta
6. Iterera över `jobs` i svaret (max 3 per incheckning)
7. Markera varje jobb som startat, kör det, rapportera resultatet

Vid undantag skickas felmeddelandet med vid nästa incheckning som `last_error`.

---

## Server — autentisering och säkerhet

Definierat i `backend/app/security.py` och `backend/app/main.py`.

### Agenttoken

```python
def new_token(prefix: str) -> str:
    return f"{prefix}_{secrets.token_urlsafe(32)}"
```

Genererar ett token med 32 bytes slumpentropi (256 bit), URL-safe base64-kodat. Resulterar i strängar som `pp_agent_xK3mN...` (ca 46 tecken). `secrets.token_urlsafe` använder operativsystemets CSPRNG (`os.urandom`).

```python
def hash_token(token: str) -> str:
    return pwd_context.hash(token)   # bcrypt, kostnadsfaktor 12

def verify_token(token: str, token_hash: str) -> bool:
    return pwd_context.verify(token, token_hash)
```

bcrypt lagrar saltet inbäddat i hashsträngen. `verify` är tidskonstant för att förhindra timing-attacker.

### CSRF-skydd

```python
def make_csrf_token() -> str:
    secret = os.getenv("APP_SECRET")
    hour = str(int(time.time()) // 3600)   # aktuell timme som sträng
    return hmac.new(secret.encode(), hour.encode(), hashlib.sha256).hexdigest()[:32]
```

Tokenet är deterministiskt inom samma timme. Det gör att sidan kan laddas om utan att CSRF-token ogiltigförklaras.

```python
def verify_csrf_token(token: str) -> bool:
    for offset in (0, 1):   # accepterar innevarande och föregående timme
        expected = hmac.new(secret, (current_hour - offset), sha256)[:32]
        if hmac.compare_digest(token, expected):
            return True
    return False
```

`hmac.compare_digest` är tidskonstant — förhindrar timing-baserade gissningsattacker. Tokens är giltiga i upp till 2 timmar, vilket täcker edge-caset att en sida laddas 59 minuter in i en timme och formuläret skickas in 1 minut senare.

### Admin HTTP Basic Auth

```python
@app.middleware("http")
async def admin_auth_middleware(request: Request, call_next):
    admin_password = os.getenv("ADMIN_PASSWORD", "").strip()
    if admin_password and request.url.path.startswith("/admin"):
        ...
        if hmac.compare_digest(pw, admin_password):
            return await call_next(request)
        return Response("Unauthorized", status_code=401,
            headers={"WWW-Authenticate": 'Basic realm="PatchPilot Admin"'})
```

Aktiveras bara om `ADMIN_PASSWORD` är satt. Lösenordet jämförs med `hmac.compare_digest` — tidskonstant. Middleware körs **före** routrar, vilket innebär att autentiseringen aldrig kan kringgås av routing-logik.

### Host-baserad routing

```python
@app.middleware("http")
async def host_path_guard(request: Request, call_next):
    host = request.headers.get("host", "").split(":")[0].lower()
    path = request.url.path

    if host == AGENT_PUBLIC_HOSTNAME:
        if not (path.startswith("/api/") or path in ("/healthz", "/install.sh", ...)):
            return Response(status_code=404)

    if host in ADMIN_INTERNAL_HOSTNAMES:
        if path.startswith("/api/v1/agent/"):
            return Response(status_code=404)
```

Agentens publika hostname kan inte nå `/admin`. Admins interna hostname kan inte nå agent-API:et. Det innebär att även om admin-gränssnittet exponeras av misstag offentligt, kan ingen använda det som agentproxy.

### Rate limiting för enrollment

```python
_enroll_timestamps: dict[str, list[float]] = defaultdict(list)

def _check_enroll_rate(ip: str) -> bool:
    now = time.time()
    valid = [t for t in _enroll_timestamps[ip] if now - t < 3600.0]
    _enroll_timestamps[ip] = valid
    if len(valid) >= 10:
        return False
    _enroll_timestamps[ip].append(now)
    return True
```

In-memory sliding window. Rensar automatiskt gamla timestamps vid varje kontroll. Nollställs vid serveromstart. Max 10 enrollments per IP per timme.

### Agentautentisering

```python
def get_agent(db, x_agent_id, authorization):
    if not x_agent_id or not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401)
    token = authorization[7:]
    machine = db.query(Machine).filter(Machine.machine_id == x_agent_id).first()
    if not machine or not machine.active or not verify_token(token, machine.token_hash):
        raise HTTPException(status_code=401)
    return machine
```

Varje agent-request kräver två headers: `X-Agent-ID` (maskin-ID) och `Authorization: Bearer <token>`. Maskinen slås upp med `machine_id`, och sedan verifieras tokenet mot den lagrade bcrypt-hashen. En agent kan inte komma åt en annan agents jobb — `Job.machine_id` kontrolleras alltid.

---

## Server — agent-API

### `POST /api/v1/agent/enroll`

1. Validerar att `machine_id` och `hostname` finns i payload (400 om de saknas)
2. Kontrollerar rate limit för klientens IP (429 om för många försök)
3. Kontrollerar om maskinen redan är registrerad:
   - Om maskinen är inaktiv/avslagen — returnerar 403
   - Om maskinen finns — returnerar `"message": "machine already enrolled"` utan nytt token
4. Genererar nytt token, skapar maskinpost i databasen
5. `PATCHPILOT_AUTO_APPROVE_AGENTS`-miljövariabeln styr om maskinen godkänns direkt eller hamnar i `pending_approval`
6. Skriver till auditloggen och skickar Discord-notifiering
7. Returnerar `agent_token` i klartext — **den enda gången tokenet syns**

### `POST /api/v1/agent/checkin`

1. Autentiserar agenten (se `get_agent` ovan)
2. Uppdaterar maskinens statusfält i databasen
3. Hanterar paketlistan: raderar alla gamla `PackageUpdate`-rader för maskinen, skriver in nya (max 500 paket)
4. Hämtar latest agent-info (version och SHA256 från den serverade filen)
5. Om maskinen inte är godkänd — returnerar `pending_approval` med tomma `jobs`
6. Hämtar upp till 3 `pending`-jobb, sorterade efter `created_at`
7. Returnerar jobblistea, policy-flags (`auto_patch`, `auto_reboot`, `auto_agent_update`) och agentuppdateringsinformation

### `POST /api/v1/agent/jobs/{id}/started`

Verifierar att jobbet tillhör den autentiserade agenten (`Job.machine_id == machine.id`). Sätter `status = "running"` och `started_at = now`. Returnerar 404 om jobbet inte finns eller tillhör en annan agent.

### `POST /api/v1/agent/jobs/{id}/result`

Tar emot `exit_code` och `output` (trunkeras till 30 000 tecken). Sätter status till `success` (exit 0) eller `failed` (exit != 0). Uppdaterar `last_success_at` eller `last_error`. Skriver till auditloggen. Skickar Discord-notifiering vid fel eller vid lyckad `upgrade`/`security_upgrade`/`reboot`.

### `GET /api/v1/agent/latest`

```python
def latest_agent_info():
    path = Path("app/static/patchpilot-agent.py")
    data = path.read_bytes()
    sha256 = hashlib.sha256(data).hexdigest()
    version = re.search(r'AGENT_VERSION\s*=\s*["\']([^"\']+)', data.decode()).group(1)
    return {"version": version, "sha256": sha256, "url": f"{PUBLIC_AGENT_URL}/agent/patchpilot-agent.py"}
```

Läser agentfilen från disk vid varje anrop, beräknar SHA256 och extraherar versionssträngen med regex. Ingen cachning — reflekterar alltid den aktuella filen.

---

## Server — admin-API

Alla admin-endpoints kräver ett giltigt CSRF-token (injiceras automatiskt av JS i admin-gränssnittet). Utan token returneras 403.

### CSRF-dependency

```python
def require_csrf(csrf_token: str = Form(default="")) -> None:
    if not verify_csrf_token(csrf_token):
        raise HTTPException(status_code=403, detail="Invalid CSRF token")
```

Deklareras som `_: None = Depends(require_csrf)` på varje POST-endpoint. FastAPI kör dependencyn **före** handlerlogiken — om CSRF-valideringen misslyckas når koden aldrig databasoperationerna.

### Jobbskapande

Validerar `action` mot `ALLOWED_ACTIONS` (400 vid ogiltig). Skapar ett `Job`-objekt med `status="pending"`. Skriver auditlogg och Discord-notifiering. Alla admin-POST returnerar `RedirectResponse("/admin", status_code=303)` — efter en formulärsubmit omdirigeras webbläsaren med GET, vilket förhindrar att formuläret skickas om vid page refresh (PRG-mönstret).

### Godkännande av jobb

Sätter `job.status = "pending"` (från `approval_required`). Jobbet plockas upp av agenten vid nästa incheckning.

### Token-rotation

Genererar nytt token, hashar det och sparar i databasen. Returnerar klartext-tokenet direkt i svaret (som ren text). Administratören kopierar det och uppdaterar `/etc/patchpilot/agent.json` manuellt på agentmaskinen.

### Maskinborttagning

Raderar alla relaterade rader i ordning: `jobs` → `package_updates` → `machine_groups` → `machines`. Utan denna ordning skulle foreign key-constraints blockera borttagningen.

### Schemakoppling

Schedules sparas med target-type (`machine` eller `group`) och target-ID. Vid skapande valideras `action`, `target_type`, `day_of_week` mot hårdkodade sets. `time_of_day` valideras med `re.fullmatch(r"\d{2}:\d{2}", ...)`.

---

## Schemaläggaren

```python
scheduler = BackgroundScheduler()

@app.on_event("startup")
def startup():
    scheduler.add_job(run_schedules, "interval", seconds=60, id="patchpilot_scheduler")
    scheduler.start()
```

APScheduler körs som en bakgrundstråd i samma process som FastAPI. `run_schedules()` anropas en gång per minut.

### `run_schedules()`

```python
def run_schedules():
    with SessionLocal() as db:
        now = datetime.now(ZoneInfo(schedule.timezone))
        current_hour_min = now.strftime("%H:%M")
        current_dow = DAYS[now.weekday()]
        run_key = f"{s.id}:{now.date()}"

        if not s.enabled: continue
        if s.last_run_key == run_key: continue  # redan kört idag
        if s.day_of_week != "all" and DAYS[s.day_of_week] != current_dow: continue
        if s.time_of_day != current_hour_min: continue  # exakt matchning

        # Skapa jobb för maskinen eller alla maskiner i gruppen
        status = "approval_required" if s.require_approval else "pending"
        ...
        s.last_run_key = run_key
        s.last_run_at = datetime.utcnow()
```

Tidszonshantering görs med Pythons `zoneinfo` (inbyggt i Python 3.9+). Scheduler-tiderna jämförs i schedulens lokala tidszon — om ett schema är konfigurerat för `03:00 Europe/Stockholm` triggas det vid 03:00 lokal tid oavsett serverns tidszon.

`last_run_key` på formatet `{schedule_id}:{datum}` är en enkel dedupliceringsgaranti: om schedulern råkar köra två gånger i samma minut (t.ex. vid restart) skapas bara en jobbomgång.

---

## Notifieringar

```python
DISCORD_WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL", "")

def notify_discord(message: str):
    if not DISCORD_WEBHOOK_URL:
        return
    try:
        urllib_request.urlopen(
            urllib_request.Request(
                DISCORD_WEBHOOK_URL,
                data=json.dumps({"content": message}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            ),
            timeout=5,
        )
    except Exception:
        pass   # notifieringsfel ska aldrig påverka API-svaret
```

Discord-notifieringar skickas synkront men med kort timeout (5 s) och alla undantag ignoreras tyst. Det innebär att ett Discord-avbrott aldrig blockerar enrollment, incheckning eller jobbresultat.

Notifieringar skickas vid:
- Ny agent enrollad (pending eller auto-godkänd)
- Agent godkänd/avslagen av admin
- Jobb köat av admin
- Jobb misslyckat
- Lyckad `upgrade`, `security_upgrade` eller `reboot`

---

## Installationsskript

Servern genererar installationsskript dynamiskt i minnet — de skrivs aldrig till disk. Det gör att server-URL:en alltid är korrekt och SHA256-summan alltid är färsk.

### `GET /install.sh` — direktinstallation

1. Laddar ned agentfilen till `/usr/local/bin/patchpilot-agent`
2. Hämtar `GET /api/v1/agent/latest` för att få förväntad SHA256
3. Beräknar `sha256sum` lokalt med `sha256sum`-kommandot
4. Jämför — avbryter och raderar agentfilen om checksummorna inte stämmer
5. Kör `patchpilot-agent --enroll --server $SERVER_URL`
6. Installerar systemd-service och systemd-timer
7. Aktiverar timern omedelbart

### `GET /template-install.sh` — VM-templateinstallation

Samma som ovan men:
- Kör **inte** enrollment vid installation
- Skriver `/etc/patchpilot/bootstrap.json` med `{"server_url": "...", "template_mode": true}`
- Raderar `/etc/patchpilot/agent.json` och `/etc/patchpilot/machine-id` (säkerställer att klonade VMs får unika identiteter)
- Aktiverar **inte** timern — den aktiveras av den som deployar VM-templaten

När en VM klonas från templaten och startas kör systemd-timern `patchpilot-agent --once` som anropar `bootstrap_if_needed()`. Den hittar `bootstrap.json`, kör enrollment och skapar ett unikt maskin-ID baserat på den klonade VM:ns hostname.

---

## Testsvit

Definitionerna finns i `backend/tests/`.

### Infrastruktur (`conftest.py`)

Testerna använder SQLite in-memory (via fil `test_patchpilot.db`) istället för PostgreSQL. FastAPIs dependency injection-mekanism används för att byta ut `get_db` mot en funktion som levererar en session mot testdatabasen:

```python
app.dependency_overrides[get_db] = _override_db
```

`_clean_state`-fixture raderar alla tabellrader efter varje test via SQLAlchemys `table.delete()`. `_create_tables` är session-scoped och skapar tabellerna en gång per testsession.

SQLite-guard i `migrate_db()`:
```python
def migrate_db():
    if "sqlite" in str(engine.url):
        return  # SQLite uses create_all; ALTER TABLE IF NOT EXISTS är PostgreSQL-only
```

### `test_api.py` — 30 tester

Testar alla HTTP-endpoints med `fastapi.testclient.TestClient`. Täcker:
- Enrollment: nyregistrering, dubbel-enrollment, saknade fält, rate limiting
- Incheckning: autentisering, rätt/fel token, paketlista, trunkering av stor lista
- Jobb: skapande, started/result-rapportering, att fel agent inte kan nå rätt agents jobb
- CSRF: alla admin-POST-routes returnerar 403 utan token, 403 med fel token, 303 med rätt token
- Admin-autentisering: 401 utan lösenord, 200 med rätt, 401 med fel
- Host-routing: agent-hostname blockerar `/admin`, admin-hostname blockerar `/api/v1/agent/`
- Admin-endpoints: skapande av grupper, scheman (inkl. ogiltigt tidsformat), maskingodkännande

### `test_security.py` — 8 tester

Testar `security.py` isolerat:
- Tokenformat och unicitet
- Bcrypt hash-verify roundtrip
- CSRF-token deterministisk inom timmen
- Föregående timmes token accepteras (max 2 timmar)
- Token från 2 timmar sedan avvisas
- Fel och tomt token avvisas

### `test_agent.py` — 16 tester

Testar agentens rena funktioner utan subprocess och utan nätverksanrop (allt mockat):
- `parse_apt_updates()`: tom output, normalt paket, security-paket, multipla paket, APT-fel
- `self_update_agent()`: saknad URL, ogiltigt filinnehåll, SHA256-mismatch, tempfil i rätt katalog
- `get_machine_id()`: skapar och persisterar nytt ID, läser befintligt ID
- `enroll()`: omregistrering avslutar med exit 0, saknat token avslutar med exit 1
