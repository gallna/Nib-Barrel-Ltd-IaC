## Sekcja 6: Integracje Zewnętrzne (3rd-Party), Współdzielona Tożsamość i Odporność Klienta

### 6.1. Izolacja Zależności Zewnętrznych (*3rd-Party SPOFs*)

Ścieżki `/auth` i `/payments` muszą komunikować się z zewnętrznymi systemami: **Google Play Games Services** (weryfikacja tokenów OAuth), **Google Play Developer API** (weryfikacja paragonów Android) oraz **bramkami płatniczymi Web** (np. Stripe / Adyen dla *Dienekes Plaza Web*). Bez izolacji, 10-sekundowe opóźnienie po stronie Google zablokuje wątki kontenerów ECS i położy nasze API.

#### Mechanizmy ochrony na styku ze światem zewnętrznym:

1. **Dedykowane pule wątków i twarde timeouty:** Wywołania HTTP do dostawców zewnętrznych używają osobnej puli połączeń z rygorystycznym limitem czasu (**Connection Timeout = 1,5 s**, **Read Timeout = 3,0 s**).
2. **Circuit Breaker per dostawca (w Valkey):** Jeśli odsetek błędów lub timeoutów od Google Play Billing przekroczy **20% w oknie 10 sekund**, Circuit Breaker przechodzi w stan `OPEN` i natychmiast przełącza ścieżkę płatności w tryb asynchroniczny (*Pending Verification*).
3. **Asynchroniczna Rekoncyliacja Płatności (Webhook + Polling):**
* Gdy bramka płatnicza lub Google API odpowiada wolno lub zwraca `503`, API zapisuje transakcję ze statusem `PENDING_EXTERNAL`, wrzuca zadanie do kolejki **SQS Reconciliation Queue** (z opóźnieniem 15s -> 60s -> 300s) i informuje klienta gry o przetwarzaniu zakupu.
* Dodatkowo nasłuchujemy na **Google Play Real-Time Developer Notifications (RTDN)** (przez Pub/Sub -> HTTPS Webhook na ALB) oraz webhooki bramki Web, aby natychmiast księgować zwroty (*chargebacks*), anulowania i opóźnione płatności.



---

### 6.2. Współdzielona Tożsamość i Izolacja Danych (API #3 oraz API #4)

Dwa z naszych klastrów obsługują więcej niż jeden kanał lub tytuł:

* **API #3:** współdzielony przez *Agrippa Mosa* (50M MAU) i *Agrippa Mosa 2* (2M MAU).
* **API #4:** współdzielony przez *Dienekes Plaza* (Android, 5M MAU) oraz *Dienekes Plaza Web* (1M MAU).

#### Architektura konta i ochrona przed wzajemnym zakłócaniem:

1. **Unified Player ID (UUIDv7) + Federated Identities:**
* Każde konto otrzymuje wewnętrzny identyfikator `player_id` (UUIDv7, sortowalny po czasie, co zapobiega fragmentacji indeksów B-Tree w PostgreSQL i MySQL).
* W tabeli `player_identities` (w DynamoDB Global Tables dla szybkiego logowania) mapujemy zewnętrzne identyfikatory (`google_play_id`, `email_hash`, `apple_id`) na jeden `player_id`.
* **Dla API #4 (Cross-Platform Android + Web):** gracz logujący się na Androidzie i w przeglądarce otrzymuje ten sam `player_id`, współdzieląc postępy i portfel. W warstwie Web (BFF) token JWT jest przechowywany w zaszyfrowanym ciasteczku `HttpOnly; Secure; SameSite=Strict` z ochroną przed CSRF, podczas gdy klient Android przesyła ten sam token w nagłówku `Authorization: Bearer`.


2. **Izolacja domenowa w API #3 (*Agrippa Mosa* vs *Agrippa Mosa 2*):**
* **Wspólne konto, oddzielne postępy:** Obie gry dzielą tabelę `accounts` (jeden login gracza w uniwersum *Agrippa Mosa*), ale tabele statystyk, ekwipunku i płatności mają osobne schematy SQL (`schema_mosa1`, `schema_mosa2`) oraz osobne kolejki SQS dla `/stats`.
* **Ochrona budżetu zasobów:** W nagłówkach JWT zaszywamy pole `app_id` (`mosa_1` vs `mosa_2`). Jeśli nowa gra *Agrippa Mosa 2* wygeneruje niespodziewany szturm zapytań przez błąd w kodzie klienta, limiter w Valkey dławi ruch wyłącznie dla `app_id = mosa_2`, chroniąc 50M graczy w *Agrippa Mosa*.



---

### 6.3. Odporność po Stronie Klienta Mobilnego (*Client-Side Resilience Contract*)

Przy 11,6 mln graczy mobilnych dziennie, najczęstszym źródłem sztucznych ataków DDoS na własne serwery jest źle napisany kod sieciowy w kliencie gry po utracie zasięgu (np. wyjazd pociągu z tunelu).

Wprowadzamy obowiązkowy **kontrakt sieciowy SDK** dla wszystkich 5 gier Android oraz klienta Web:

1. **Exponential Backoff + Full Jitter:**
* Przy błędzie sieciowym, timeoutcie lub kodzie HTTP `503`/`429`, klient nie może ponowić żądania natychmiast.
* Czas oczekiwania wyliczany jest wzorem: $\text{sleep} = \text{random}(0, \min(\text{cap}, \text{base} \times 2^{\text{attempt}}))$ (gdzie $\text{base} = 500\text{ ms}$, $\text{cap} = 30\text{ s}$, maks. 5 prób). Rozprasza to falę ponowień w czasie i eliminuje efekt *Thundering Herd*.


2. **Lokalny bufor zdarzeń `/stats` na urządzeniu:**
* Ponieważ `/stats` stanowi 89% ruchu, klient gry nie wysyła każdego pojedynczego zdarzenia osobno. Zdarzenia są grupowane w lokalnej bazie SQLite na urządzeniu i wysyłane paczką co **15–30 sekund** (lub na koniec meczu) z użyciem kompresji **Gzip/Brotli** oraz nagłówka `Batch-Id` (zapobiegającego duplikacji przy ponowieniu).
* Jeśli serwer zwróci `429 Too Many Requests` z nagłówkiem `Retry-After: 60`, klient wstrzymuje wysyłkę statystyk na 60 sekund, bez przerywania rozgrywki graczowi.


3. **Kolejka płatności na urządzeniu:**
* Token zakupu otrzymany z Google Play Billing jest natychmiast zapisywany w trwałej pamięci urządzenia przed wysłaniem do `/payments`. Klient ponawia wysyłkę z tym samym `Idempotency-Key` aż do otrzymania statusu `CONFIRMED` lub `REJECTED` od naszego API (nigdy nie konsumuje zakupu w Google Play przed potwierdzeniem zapisu w naszej bazie).



---

### 6.4. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 6)

```hcl
locals {
  reconciliation_queues = {
    for api_key in ["api_1", "api_2", "api_3", "api_4"] : api_key => {
      delay_seconds              = 15
      visibility_timeout_seconds = 60
      max_receive_count          = 5 # Ponowienia z backoffem do 15 min
      message_retention_seconds  = 1209600 # 14 dni na ręczną inspekcję DLQ
    }
  }

  client_rate_limits_per_minute = {
    stats_per_player    = 30  # Średnio 9/min; 30/min daje ponad 3x zapasu na szczyty
    auth_per_ip         = 20  # Ochrona przed brute-force / credential stuffing
    payments_per_player = 10  # Ochrona przed pętlami błędów w SDK płatności
  }
}

```
