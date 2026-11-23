## Sekcja 9: Observability, SRE i Zarządzanie Incydentami

### 9.1. Stos Obserwowalności (*Three Pillars* w skali 46,3k RPS)

Zamiast budować i utrzymywać własne klastry Elasticsearch/OpenSearch czy Prometheus (co pochłonęłoby czas kilku inżynierów), korzystamy z w pełni zarządzanych usług AWS opartych o otwarty standard **OpenTelemetry**:

1. **Metryki (ADOT Sidecar -> Amazon Managed Prometheus -> Amazon Managed Grafana):**
* Każde zadanie ECS Fargate uruchamia lekki kontener poboczny (**AWS Distro for OpenTelemetry — ADOT Collector**), który zbiera metryki aplikacji (opóźnienia p50/p95/p99, wskaźniki *Cache Hit Ratio* w Valkey, wielkość paczek SQS, czasy odpowiedzi Google Play API) i wysyła je strumieniowo do **AMP**.
* **Amazon Managed Grafana (AMG)** służy jako centralny ekran operacyjny (*Single Pane of Glass*) z gotowymi dashboardami dla każdego z 4 API, bazy Aurora oraz stanu budżetu błędów (SLI 99,5%).


2. **Rozproszone śledzenie zapytań (AWS X-Ray + Tail-Based Sampling):**
* Śledzenie każdego z 46 313 zapytań na sekundę zalałoby system logowania. Konfigurujemy kolektor ADOT w trybie **Tail-Based Sampling**:
* **100% śladów (Traces)** dla żądań zakończonych błędem (`HTTP 5xx`, `429`) lub przekraczających próg opóźnienia SLO (`> 150 ms` dla `/stats`, `> 400 ms` dla `/payments`).
* **0,5% śladów** dla poprawnych, szybkich żądań (`HTTP 200 OK`) jako linia bazowa.


* Dzięki temu w ciągu kilkunastu sekund SRE widzi dokładny *flamegraph* powolnego żądania (np. czy opóźnienie powstało w kontenerze ECS, na blokadzie w RDS Proxy, czy podczas oczekiwania na Google API).


3. **Logi strukturalne (JSON -> CloudWatch Logs + S3 Archival):**
* Kontenery wypisują logi wyłącznie w ustandaryzowanym formacie **JSON** zawierającym `trace_id`, `player_id` (zahashowane), `game_id` oraz `endpoint`.
* Logi operacyjne trzymamy w CloudWatch Logs przez **14 dni** (do szybkiego przeszukiwania przez *CloudWatch Logs Insights*), a następnie automatycznie eksportujemy do S3.



---

### 9.2. Alertowanie oparte o *SLO Burn Rate* (Zero szumu alarmowego)

Przy 22 Senior SRE najgorszym wrogiem jest *alert fatigue* (zmęczenie alarmami wywoływanymi przez chwilowe skoki CPU, które nie wpływają na graczy). **Zasada: budzimy człowieka w nocy (PagerDuty / Opsgenie) wyłącznie wtedy, gdy realnie zagrożony jest nasz budżet błędów SLI 99,5%.**

Stosujemy **Multi-Window, Multi-Burn-Rate Alerts** (zgodnie ze standardem Google SRE Workbook):

| Poziom Krytyczności | Współczynnik spalania (*Burn Rate*) | Okno pomiarowe (Długie / Krótkie) | Zużycie miesięcznego Error Budgetu | Akcja i kanał powiadomień |
| --- | --- | --- | --- | --- |
| **SEV-1 (Page / Telefon)** | **14,4x** | 1 godz. / 5 min | 2% budżetu w 1 godzinę (wyczerpanie w ~2 dni) | Natychmiastowe wybudzenie dyżurnego SRE (*On-Call*); przygotowanie procedury failoveru. |
| **SEV-2 (Page / Telefon)** | **6,0x** | 6 godz. / 30 min | 5% budżetu w 6 godzin (wyczerpanie w ~5 dni) | Pilna interwencja SRE; analiza degradacji bazy lub 3rd-party API. |
| **SEV-3 (Ticket / Slack)** | **1,0x – 3,0x** | 24 godz. / 2 godz. | Powolny wyciek budżetu | Brak budzenia w nocy; zgłoszenie na kanał zespołu przypisanego do danego API w godzinach pracy. |

*(Dodatkowo utrzymujemy tylko 3 twarde alarmy infrastrukturalne wyprzedzające awarię: zapełnienie puli IP w podsieci > 85%, wiek najstarszej wiadomości w kolejce SQS `/stats` > 60 s oraz opóźnienie replikacji Aurora Global Database > 30 s).*

---

### 9.3. Synthetic Monitoring (Testy Syntetyczne End-to-End)

Metryki wewnętrzne nie wykryją sytuacji, w której błąd konfiguracji WAF lub certyfikatu TLS na krawędzi odcina graczy z konkretnego kraju w Europie, zanim ruch w ogóle dotrze do naszego ALB.

* Uruchamiamy **Amazon CloudWatch Synthetics (Canaries)** z 4 europejskich lokalizacji (**Frankfurt, Irlandia, Paryż, Sztokholm**).
* Co **60 sekund** dedykowane boty testowe (na specjalnych kontach technicznych oznaczonych flagą `is_synthetic=true`, odfiltrowanych ze statystyk BI) wykonują pełną ścieżkę krytyczną dla każdego z 4 API oraz *Dienekes Plaza Web*:
1. Logowanie (`/auth`) i pobranie tokenu JWT.
2. Zapis i natychmiastowy odczyt paczki statystyk (`/stats`).
3. Symulacja zakupu testowego (`/payments` w trybie sandbox).


* Niepowodzenie w 2 lokalizacjach jednocześnie traktowane jest na równi z alarmem **SEV-1**.

---

### 9.4. Chaos Engineering i Regularne *GameDays* (AWS FIS)

Plany Disaster Recovery (RTO 15 min) i polityki *Circuit Breaker*, które nie są regularnie testowane pod obciążeniem, w dniu prawdziwej awarii nie zadziałają.

* **Ciągłe testy odporności (AWS Fault Injection Service — FIS):**
* W środowisku **Perf/Opt (1:1)** raz w tygodniu, a na **Produkcji** raz w miesiącu w godzinach niskiego ruchu (okno kontrolowane z dyżurnymi SRE), uruchamiamy automatyczne eksperymenty FIS:
* **Symulacja awarii Strefy Dostępności (AZ Blackhole):** odcięcie ruchu sieciowego w `eu-central-1a` na 15 minut i weryfikacja, czy ALB, ECS, Valkey i Aurora przejmują ruch w pozostałych 2 AZ bez utraty SLI 99,5%.
* **Failover instancji Writer w Aurorze:** wymuszenie przełączenia lidera bazy i pomiar czasu maskowania przerwy przez RDS Proxy (cel: < 3 s).
* **Awaria węzła ElastiCache (Valkey):** restart głównego sharda i weryfikacja odporności bazy na chwilowy wzrost *Cache Miss*.
* **Wstrzyknięcie opóźnień Google Play API (+5 s latency):** weryfikacja, czy Circuit Breaker poprawnie przełącza płatności w tryb asynchroniczny.




* **Kwartalne *GameDays*:** pełne ćwiczenie przełączenia między regionami (`eu-central-1` -> `eu-west-1`) z pomiarem stoperem rzeczywistego RTO (cel: poniżej 7 minut) i weryfikacją procedury rozgrzewania zimnego cache'u.

---

### 9.5. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 9)

```hcl
locals {
  observability_config = {
    adot_collector_image = "public.ecr.aws/aws-observability/aws-otel-collector:v0.41.0"
    xray_sampling = {
      error_rate       = 1.0   # 100% błędów 5xx/429 i przekroczeń SLO
      baseline_rate    = 0.005 # 0.5% poprawnych żądań
    }
    log_retention_days = 14
  }

  slo_burn_rate_alerts = {
    sev1_fast_burn = { burn_rate = 14.4, long_window_min = 60,  short_window_min = 5 }
    sev2_med_burn  = { burn_rate = 6.0,  long_window_min = 360, short_window_min = 30 }
    sev3_slow_burn = { burn_rate = 1.0,  long_window_min = 1440, short_window_min = 120 }
  }

  synthetics_locations = ["eu-central-1", "eu-west-1", "eu-west-3", "eu-north-1"]
}

```
