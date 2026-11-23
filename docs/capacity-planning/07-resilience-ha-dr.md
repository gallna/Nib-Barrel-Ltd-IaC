## Sekcja 7: Odporność, High Availability i Disaster Recovery

### 7.1. Dlaczego *Warm Standby* (Active-Passive), a nie *Active-Active Multi-Region*?

Przy nieograniczonym budżecie kuszącą pułapką jest budowa architektury *Active-Active* (jednoczesny zapis do baz w Frankfurcie i Irlandii). W systemach gamingowych z wymogami ACID (`/payments`) i intensywnymi aktualizacjami stanu (`/stats`) jest to **groźny antywzorzec**:

* **Złożoność i spójność:** Rozproszone zapisy wieloregionowe w SQL (np. CockroachDB czy własne shardingi) drastycznie podnoszą opóźnienia p99 (wymagany konsensus między regionami przez sieć WAN ~22 ms) i generują ryzyko konfliktów przy jednoczesnych zakupach lub aktualizacji ekwipunku.
* **Pragmatyzm Principal Engineera:** Skoro wymagane **RTO wynosi 15 minut**, model **Warm Standby** (gdzie region zapasowy ma już uruchomione pełnowymiarowe instancje baz danych, puste klastry Valkey oraz pulę 93 rozgrzanych kontenerów Fargate) daje nam **100% bezpieczeństwa ACID**, prostotę operacyjną pojedynczego punktu zapisu i realny czas odtworzenia poniżej 7 minut.

---

### 7.2. Gwarancja RPO ≤ 5 minut dla każdej warstwy danych

Aby nie stracić więcej niż 5 minut danych w przypadku nagłej, całkowitej awarii regionu Frankfurt (`eu-central-1`), zabezpieczamy trzy warstwy stanowe:

1. **Bazy relacyjne (Aurora Global Database):**
* Replikacja odbywa się bezpośrednio na poziomie warstwy dyskowej AWS (nie obciąża CPU) z opóźnieniem **< 1 sekundy**.
* Włączamy **Aurora Backtrack** (okno 24h) oraz ciągłe kopie zapasowe (**Point-in-Time Recovery — PITR**) w obu regionach, aby chronić się nie tylko przed awarią sprzętu, ale też przed błędnym wdrożeniem (np. przypadkowym `DELETE` bez `WHERE`).


2. **Sesje i uwierzytelnianie (DynamoDB Global Tables):**
* Działa natywnie w trybie *Active-Active* między Frankfurtem a Irlandią (opóźnienie replikacji **< 1 sekundy**). Przełączenie regionu nie wylogowuje graczy.


3. **Zdarzenia w locie na `/stats` (Kolejki SQS):**
* W normalnym trybie kolejka SQS opróżniana jest co **2 sekundy**, więc w przypadku nagłego odcięcia zasilania Frankfurtu tracimy maksymalnie 2 sekundy nieprzetworzonych statystyk (zapas 298 sekund względem RPO 5 min).
* **Zabezpieczenie przed korkiem przed awarią:** Monitorujemy metrykę `ApproximateAgeOfOldestMessage`. Jeśli opóźnienie przetwarzania SQS w `eu-central-1` przekroczy **60 sekund**, API automatycznie przełącza wysyłkę nowych paczek `/stats` na zapasową kolejkę SQS w regionie `eu-west-1` (*Cross-Region Spillover*), gwarantując, że RPO nigdy nie zbliży się do 5 minut.



---


### 7.3. Budżet Czasowy Failoveru (RTO ≤ 15 min -> Cel: 6 min 30 s)

Przełączenie między regionami jest orkiestrowane przez **AWS Systems Manager (SSM) Automation Runbook** oraz **Amazon Route 53 Application Recovery Controller (ARC)** (który działa na płaszczyźnie danych AWS i nie zawiedzie nawet wtedy, gdy API zarządzające AWS w Frankfurcie przestanie odpowiadać).

| Etap Failoveru | Czas trwania | Skumulowany czas (RTO) | Wykonywane akcje techniczne |
| --- | --- | --- | --- |
| **1. Detekcja i Decyzja** | 90 s | **01:30** | Złożone alarmy CloudWatch + Synthetics wykrywają spadek SLI < 99,0% w 3 kolejnych oknach 30s. Dyżurny SRE zatwierdza przełączenie 1 kliknięciem (ochrona przed *split-brain* przy fałszywym alarmie). |
| **2. Przełączenie Ruchu Edge** | 30 s | **02:00** | **Route 53 ARC** zmienia wagi w **Global Accelerator** (`eu-central-1` = 0%, `eu-west-1` = 100%). **CloudFront** przełącza *Origin* dla *Dienekes Plaza Web* na ALB w Irlandii. |
| **3. Promocja Bazy Danych** | 90 s | **03:30** | Wywołanie `FailoverGlobalCluster` (lub `RemoveFromGlobalCluster` przy całkowitej śmierci regionu) promuje instancje w `eu-west-1` na nowe klastry *Writer*. **RDS Proxy** w Irlandii automatycznie kieruje zapisy na nowych liderów. |
| **4. Skalowanie ECS i Rozgrzewanie** | 180 s | **06:30** | Kontenery Fargate w `eu-west-1` (już uruchomione w liczbie 93 szt.) przyjmują ruch i skalują się do docelowych 152 szt., przy jednoczesnym stopniowym otwieraniu limitów na `/stats`. |

*(Zostaje **8 minut i 30 sekund** bezpiecznego bufora na nieprzewidziane opóźnienia sieciowe przed naruszeniem SLA 15 minut).*

---

### 7.4. Rozgrzewanie Zimnego Cache'u (*Cold Cache Protection*) po Failoverze

Największym zabójcą systemów po przełączeniu DR jest **pusty klaster Valkey (Redis)** w regionie zapasowym. Nie replikujemy zawartości RAM między regionami (zbyt duże narzuty sieciowe i ryzyko przeniesienia uszkodzonych danych). Gdy 41,2k req/s z `/stats` uderzy w pusty Valkey w Irlandii, 100% zapytań wygeneruje *Cache Miss* i trafi prosto w bazę Aurora, powodując jej natychmiastowe przeciążenie.

Wdrażamy **trzy mechanizmy ochronne**:

1. **Request Coalescing (Wzorzec *Singleflight* w kodzie API):** Jeśli w tej samej milisekundzie 50 wątków zapyta o profil tego samego gracza (którego nie ma w Valkey), tylko **1 zapytanie** leci do Aurory, a pozostałe 49 czeka na jego wynik z pamięci lokalnej kontenera.
2. **Progresywny *Load Shedding* na `/stats` (T+0 do T+5 min po failoverze):**
* Serwisy `/payments` i `/auth` od pierwszej sekundy działają na **100% przepustowości**.
* Serwis `service-stats` uruchamia się z flagą `DR_WARMUP_MODE=true` (sterowaną przez AWS AppConfig), która stopniowo otwiera przepustowość odczytów: **30% w 1. minucie -> 60% w 3. minucie -> 100% w 5. minucie**. Nadmiarowe odczyty otrzymują `HTTP 429` z nagłówkiem `Retry-After: 20` (klient gry z Sekcji 6 grzecznie czeka i nie zrywa rozgrywki).


3. **Wstępne ładowanie TOP graczy (Background Pre-Warmer):** Zaraz po promocji bazy w `eu-west-1`, lekki worker pobiera z replik odczytowych Aurory profile 500 tys. najaktywniejszych graczy (logujących się w ciągu ostatnich 2 godzin) i wsadowo ładuje je do Valkey za pomocą `PIPELINE`.

---

### 7.5. Macierz Degradacji Usług (*Graceful Degradation* wewnątrz regionu)

Gdy pojedynczy komponent (np. kolejka SQS lub replika odczytowa) ulegnie degradacji wewnątrz `eu-central-1`, system nie pada jako całość, lecz świadomie poświęca mniej krytyczne funkcje, aby chronić budżet błędów SLI 99,5%:

| Priorytet | Ścieżka / Funkcja | Zachowanie podczas kryzysu | Wpływ na gracza |
| --- | --- | --- | --- |
| **P1 (Krytyczny)** | **`/payments`** | Zarezerwowana pula połączeń w RDS Proxy; automatyczne odcięcie ruchu `/stats`, jeśli obciążenie CPU bazy Writer przekroczy 85%. | Gracz zawsze może dokonać zakupu; zero utraconych transakcji. |
| **P2 (Wysoki)** | **`/auth`** | Działa całkowicie niezależnie od Aurory (JWT + DynamoDB). | Gracz zawsze może uruchomić i zalogować się do gry. |
| **P3 (Średni)** | **`/stats` (Zapisy)** | Przy spowolnieniu bazy dane gromadzą się w SQS (retencja do 14 dni); stan w Valkey aktualizuje się na bieżąco. | Gracz widzi postępy na żywo; zapis trwały w SQL następuje z opóźnieniem. |
| **P4 (Niski)** | **`/stats` (Rankingi / Historia)** | Włączenie trybu *Stale-If-Error* (zwracanie lekko nieaktualnych danych z cache lub wyłączenie globalnych tabel wyników). | Gra działa płynnie; globalne rankingi odświeżają się rzadziej. |

---

### 7.6. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 7)

```hcl
locals {
  dr_configuration = {
    primary_region = "eu-central-1"
    dr_region      = "eu-west-1"

    route53_arc = {
      cluster_name        = "gaming-eu-recovery-cluster"
      routing_controls    = ["api-1", "api-2", "api-3", "api-4", "web-dienekes"]
      safety_rule_min_active = 1 # Blokuje jednoczesne wyłączenie obu regionów
    }

    aurora_resilience = {
      backup_retention_period = 14 # dni
      backtrack_window        = 86400 # 24h w sekundach (dla Aurora MySQL/PG)
      deletion_protection     = true
    }

    warmup_ramp_up = {
      stage_1_percent  = 30
      stage_2_percent  = 60
      stage_3_percent  = 100
      step_interval_sec = 120
    }
  }
}

```
