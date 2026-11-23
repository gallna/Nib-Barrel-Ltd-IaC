## Sekcja 5: Architektura Krytycznych Ścieżek Biznesowych (`/stats`, `/auth`, `/payments`)

### 5.1. Ścieżka `/stats` (89,0% ruchu — 41 219 Peak RPS)

**Cel:** Opóźnienie **p99 < 150 ms**, SLO **99,90%**, gwarancja *Read-Your-Own-Writes* (gracz natychmiast widzi swój wynik po meczu) bez zabijania bazy relacyjnej tysiącami blokad na wierszach.

#### Architektura przepływu (Wzorzec *Cache-Aside + Write-Behind*):

1. **Odczyt statystyk (`GET /v1/stats/*`):**
* Serwis `service-stats` odpytuje klaster **ElastiCache (Valkey)** (czas odpowiedzi < 2 ms, docelowy *Cache Hit Ratio* > 95%).
* W przypadku *Cache Miss* (np. powrót gracza po kilku dniach), żądanie trafia przez **RDS Proxy (Read-Only)** do repliki odczytowej Aurory, a wynik zapisywany jest w Valkey z **TTL = 24 godziny** (dla gorących profili) oraz losowym *jitterem* (±15 min), aby uniknąć jednoczesnego wygasania kluczy (*Cache Stampede*).


2. **Zapis statystyk (`POST/PUT /v1/stats/*`):**
* **Krok 1 (Natychmiastowa widoczność):** Kontener atomowo aktualizuje stan gracza w **Valkey** (np. operacje `HINCRBY` / `ZADD` dla rankingów).
* **Krok 2 (Asynchroniczne buforowanie):** Kontener wysyła zdarzenie zmiany stanu do dedykowanej kolejki **Amazon SQS** (osobna kolejka per API) i natychmiast zwraca graczowi kod `202 Accepted` / `200 OK` (całość trwa < 15 ms).
* **Krok 3 (Zapis wsadowy do Aurory):** Dedykowany, lekki serwis roboczy (`ecs-worker-stats`) pobiera wiadomości paczkami, grupuje je w pamięci przez **maksymalnie 2 sekundy** (lub do zebrania 500 unikalnych graczy) i wykonuje jedno zapytanie zbiorcze do instancji *Writer* Aurory:
* PostgreSQL: `INSERT INTO player_stats ... ON CONFLICT (player_id) DO UPDATE SET ...`
* MySQL (API #4): `INSERT INTO player_stats ... ON DUPLICATE KEY UPDATE ...`





**Dlaczego to działa przy RPO ≤ 5 min?**
Opóźnienie między przyjęciem żądania przez API a trwałym zapisem w Aurorze wynosi średnio **2–4 sekundy** (zostaje ponad 4 minuty zapasu względem limitu RPO 5 min). Jednocześnie zamieniamy **41 219 małych zapisów/s** na około **80–100 zoptymalizowanych zapytań wsadowych/s**. Jeśli baza chwilowo zwolni, kolejka SQS bezpiecznie wchłonie ruch (*backpressure*), a nieudane paczki po 3 próbach trafiają do **Dead Letter Queue (DLQ)** do automatycznego ponowienia.

---

### 5.2. Ścieżka `/auth` (9,4% ruchu — 4 355 Peak RPS)

**Cel:** Opóźnienie **p99 < 100 ms**, SLO **99,95%**, odporność na lawinowe logowania po wydaniu aktualizacji gry (*Thundering Herd*).

#### Architektura bezstanowa i współdzielenie sesji:

1. **Weryfikacja żądań w locie (Zero zapytań do bazy):**
* Po zalogowaniu gracz otrzymuje krótkotrwały **Access Token (JWT, ważny 15 minut)** podpisany asymetrycznie algorytmem **ES256 (ECDSA P-256)** oraz długotrwały **Refresh Token (ważny 30 dni)**.
* Kontenery ECS pobierają klucz publiczny z **AWS Secrets Manager / KMS** przy starcie i cachują go w pamięci RAM. Każde kolejne wywołanie `/stats` czy `/payments` weryfikuje podpis JWT lokalnie w czasie **< 0,5 ms**, bez dotykania bazy danych czy sieci.


2. **Logowanie i odświeżanie tokenów w Amazon DynamoDB Global Tables:**
* Zamiast obciążać relacyjną Aurorę ciągłymi zapisami sesji, stan logowań, *Refresh Tokeny* oraz listę unieważnionych sesji przechowujemy w **Amazon DynamoDB** w trybie **On-Demand** z włączoną replikacją **Global Tables** między `eu-central-1` a `eu-west-1`.
* **Korzyść operacyjna:** DynamoDB zapewnia jednocyfrowe opóźnienia (2–5 ms) przy dowolnym skoku ruchu, natywny mechanizm **TTL** automatycznie usuwa wygasłe sesje bez obciążania systemu, a replikacja między regionami działa w trybie *Active-Active* (< 1 s). Podczas awarii regionu gracz nie musi logować się ponownie.



---

### 5.3. Ścieżka `/payments` (1,6% ruchu — 741 Peak RPS)

**Cel:** Opóźnienie **p99 < 400 ms**, SLO **99,99%**, gwarancja **ACID** i absolutny zakaz podwójnego obciążenia gracza lub utraty zakupionego przedmiotu.

#### Wzorzec *Idempotent Execution + Transactional Outbox*:

1. **Wymuszona Idempotencja na wejściu:**
* Klient gry/Web musi przesłać nagłówek `Idempotency-Key` (UUIDv7 wygenerowany przy kliknięciu „Kup”).
* Serwis `service-payments` sprawdza ten klucz w **Valkey** (`SET key "IN_PROGRESS" NX EX 300`). Jeśli klient ponowi identyczne żądanie (np. przez zerwane połączenie w metrze), API zwraca zapisany wynik poprzedniej transakcji zamiast przetwarzać płatność drugi raz.


2. **Weryfikacja zewnętrzna i transakcja ACID w Aurorze:**
* Po pozytywnej weryfikacji tokenu zakupu w Google Play Developer API lub bramce płatniczej Web (szczegóły izolacji w Sekcji 6), serwis otwiera transakcję na instancji **Writer Aurory** (przez RDS Proxy Read/Write) i w jednym bloku `BEGIN ... COMMIT` wykonuje trzy operacje:
1. Wstawia rekord do `payment_transactions` (z ograniczeniem `UNIQUE (idempotency_key)` i `UNIQUE (external_transaction_id)` jako ostateczną barierą na poziomie silnika SQL).
2. Aktualizuje saldo waluty premium / ekwipunek gracza w tabeli `player_wallets`.
3. Zapisuje zdarzenie rozliczeniowe w tabeli `outbox_events` (**Transactional Outbox**).




3. **Asynchroniczna dystrybucja zdarzeń:**
* Lekki proces w tle odczytuje nowe wiersze z `outbox_events` i publikuje je do kolejek analitycznych/audytowych, oznaczając je jako wysłane. Dzięki temu nawet chwilowa niedostępność systemów raportowych nigdy nie cofnie transakcji zakupu gracza.



---

### 5.4. Podsumowanie separacji wzorców per ścieżka

| Ścieżka | Wzorzec spójności | Główny magazyn odczytu | Główny magazyn zapisu | Strategia przy przeciążeniu bazy |
| --- | --- | --- | --- | --- |
| **`/stats`** | *Eventual Consistency* (< 4s) | ElastiCache (Valkey) | Valkey -> SQS -> Aurora (Batch) | Buforowanie w SQS (kolejka rośnie, API nadal zwraca `202 OK`). |
| **`/auth`** | *Strong / Multi-Region* | Pamięć lokalna ECS (JWT) | DynamoDB Global Tables | Pełna niezależność od Aurory; autoryzacja działa nawet podczas awarii SQL. |
| **`/payments`** | *Strict ACID* | Aurora Writer (RDS Proxy) | Aurora Writer (RDS Proxy) | Priorytetowy dostęp do puli połączeń; odcięcie ruchu `/stats` przy degradacji. |

---

### 5.5. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 5)

```hcl
locals {
  stats_queues = {
    api_1 = { visibility_timeout = 30, max_receive_count = 3, batch_size = 500, flush_window_sec = 2 }
    api_2 = { visibility_timeout = 30, max_receive_count = 3, batch_size = 100, flush_window_sec = 2 }
    api_3 = { visibility_timeout = 30, max_receive_count = 3, batch_size = 500, flush_window_sec = 2 }
    api_4 = { visibility_timeout = 30, max_receive_count = 3, batch_size = 200, flush_window_sec = 2 }
  }

  dynamodb_auth_tables = {
    billing_mode     = "PAY_PER_REQUEST" # On-Demand dla nagłych skoków logowań
    ttl_attribute    = "expires_at"
    replica_regions  = ["eu-central-1", "eu-west-1"]
    point_in_time_recovery = true
  }
}

```
