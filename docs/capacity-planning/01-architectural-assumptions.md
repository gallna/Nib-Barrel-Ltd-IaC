## Sekcja 1: Założenia Architektoniczne i Capacity Planning

### 1.1. Model matematyczny i weryfikacja metryk użytkowników

Do przeliczenia ruchu przyjmujemy następujące stałe operacyjne:

* **Dzienny czas gry ($T_{\text{play}}$):** $12\text{ min} = 720\text{ s}$ (z $86\,400\text{ s}$ w dobie).
* **Średnia liczba jednoczesnych graczy ($\text{Avg CCU}$):**

$$\text{Avg CCU} = \frac{\text{DAU} \times 720}{86\,400} = \frac{\text{DAU}}{120}$$


* **Szczytowy ruch ($\text{Peak RPS}$):**

$$\text{Peak RPS} = \text{Avg CCU} \times 0,15\text{ req/s} \times 3,0 = \text{Avg CCU} \times 0,45$$



**Ważna obserwacja inżynieryjna (rozbieżność DAU vs MAU):**
Porównanie deklarowanego DAU z wartością wyliczoną ze wzoru ($\text{MAU} \times 8,6\%$) pokazuje dwie grupy gier:

1. **Dojrzałe hity masowe** (*Pythodorus 3*, *Agrippa Mosa*) mają stickiness na poziomie ~8,0%, więc formuła z MAU (8,6%) daje lekki zapas bezpieczeństwa.
2. **Nowsze lub niszowe tytuły** (*Theognis per Megara*, *Agrippa Mosa 2*, *Dienekes Plaza*) mają realne stickiness na poziomie **15–20%**.

**Decyzja architektoniczna:** W tabeli poniżej prezentujemy dokładny wynik ze wzoru (dla zgodności z założeniami), ale infrastrukturę wymiarujemy pod **Sizing Envelope** ($\max(\text{DAU}_{\text{wzór}}, \text{DAU}_{\text{deklarowane}})$), aby nie zdławić mniejszych gier w godzinach szczytu.

| Gra | Platforma | API | MAU | DAU (deklar.) | DAU (8,6% MAU) | Avg CCU (wzór) | Peak RPS (wzór) | Peak RPS (Sizing Envelope) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Pythodorus 3** | Android | API #1 | 75,0M | 6,00M | 6,45M | 53 750 | **24 187,5** | **24 188** |
| **Theognis per Megara** | Android | API #2 | 1,0M | 0,20M | 0,086M | 717 | **322,5** | **750** |
| **Agrippa Mosa** | Android | API #3 | 50,0M | 4,00M | 4,30M | 35 833 | **16 125,0** | **16 125** |
| **Agrippa Mosa 2** | Android | API #3 | 2,0M | 0,30M | 0,172M | 1 433 | **645,0** | **1 125** |
| **Dienekes Plaza** | Android | API #4 | 5,0M | 1,00M | 0,43M | 3 583 | **1 612,5** | **3 750** |
| **Dienekes Plaza Web** | Web | API #4 | 1,0M | 0,10M | 0,086M | 717 | **322,5** | **375** |
| **SUMA EKOSYSTEMU** | — | **4 API** | **134,0M** | **11,60M** | **11,524M** | **96 033** | **43 215,0** | **46 313** |

*(Uwaga dla usługi Web: dla Dienekes Plaza Web oprócz zapytań do API #4 należy doliczyć ok. **375 req/s** ruchu HTTP dla samego kontenera front-endowego ECS).*

---

### 1.2. Dekompozycja ruchu na API i endpointy (`/stats`, `/auth`, `/payments`)

Zgodnie z profilem ruchu (**89,0% `/stats**`, **9,4% `/auth**`, **1,6% `/payments**`), obciążenie poszczególnych klastrów API rozkłada się następująco (wartości w nawiasach oznaczają bezpieczny *Sizing Envelope*):

| Klaster | Obsługiwane gry | Silnik DB | Łączny Peak RPS | `/stats` (89,0%) | `/auth` (9,4%) | `/payments` (1,6%) |
| --- | --- | --- | --- | --- | --- | --- |
| **API #1** | Pythodorus 3 | Aurora PostgreSQL | **24 188** *(24 188)* | 21 527 *(21 527)* | 2 274 *(2 274)* | 387 *(387)* |
| **API #2** | Theognis per Megara | Aurora PostgreSQL | **323** *(750)* | 287 *(668)* | 30 *(71)* | 5 *(12)* |
| **API #3** | Agrippa Mosa + Mosa 2 | Aurora PostgreSQL | **16 770** *(17 250)* | 14 925 *(15 353)* | 1 576 *(1 622)* | 268 *(276)* |
| **API #4** | Dienekes Plaza (App + Web) | Aurora MySQL | **1 935** *(4 125)* | 1 722 *(3 671)* | 182 *(388)* | 31 *(66)* |
| **RAZEM** | **6 gier (5 Android, 1 Web)** | — | **43 215** *(46 313)* | **38 461** *(41 219)* | **4 062** *(4 355)* | **691** *(741)* |

**Kluczowe wnioski dla architektury:**

1. **Asymetria skali:** API #1 i API #3 obsługują łącznie **94,8%** całego ruchu (40 958 req/s). API #2 i API #4 są o rząd wielkości mniejsze, ale muszą zachować identyczny standard odporności (DR, izolacja), ponieważ awaria któregokolwiek z nich psuje wspólne SLI.
2. **Dominacja zapisu/odczytu statystyk:** Blisko **41,2 tys. req/s** na `/stats` w szczycie oznacza ponad **106 milionów żądań na godzinę**. Bezpośrednie uderzanie każdego z tych zapytań w relacyjną bazę danych (szczególnie zapisów `UPDATE` na tych samych wierszach graczy) wywołałoby blokady na poziomie wierszy (*row-level lock contention*) i wysycenie IOPS.
3. **Krytyczność płatności:** **741 req/s** na `/payments` to stosunkowo niewielki wolumen dla nowoczesnej bazy relacyjnej, ale każde odrzucone lub zdublowane żądanie to bezpośrednia strata finansowa i reklamacje. Ta ścieżka musi być fizycznie odizolowana od korków na `/stats`.

---

### 1.3. Model SLI / SLO i zarządzanie Error Budgetem

Wymaganie wejściowe to **SLI ≥ 99,5%** w skali miesiąca (30 dni = 43 200 minut).

* **Całkowity miesięczny Error Budget (dla 99,5%):** **216 minut** (3 godziny i 36 minut) niedostępności lub błędów serwera (HTTP 5xx / przekroczenie czasu odpowiedzi).
* **Wpływ celów DR:** Nasze RTO wynosi **15 minut**. Oznacza to, że jedna pełna awaria regionu i przełączenie ruchu do regionu zapasowego zużywa **~7% całego miesięcznego budżetu błędów**.

Aby nigdy nie naruszyć zewnętrznego progu 99,5%, definiujemy wewnętrzne cele **SLO (Service Level Objectives)** zróżnicowane według krytyczności biznesowej endpointów:

| Ścieżka / Komponent | Wewnętrzne SLO | Miesięczny Error Budget | Docelowe opóźnienie (p99) | Uzasadnienie inżynieryjne |
| --- | --- | --- | --- | --- |
| **`/payments`** | **99,99%** | 4,32 min | < 400 ms | Transakcje finansowe; brak tolerancji na utratę żądań. |
| **`/auth`** | **99,95%** | 21,60 min | < 100 ms | Bramka wejścia do gry; awaria odcina 100% graczy. |
| **`/stats`** | **99,90%** | 43,20 min | < 150 ms | Najwyższy wolumen; dopuszczalna chwilowa kolejka lub *graceful degradation*. |
| **Dienekes Plaza Web** | **99,90%** | 43,20 min | < 250 ms | Warstwa prezentacji chroniona przez CloudFront (cache). |

**Definicja SLI (Success Rate):**


$$\text{SLI} = \frac{\text{Liczba poprawnych żądań (HTTP 2xx/3xx/4xx z wyłączeniem 429) poniżej progu latency p99}}{\text{Całkowita liczba żądań na poziomie ALB}} \times 100\%$$

*(Uwaga: Błędy klienta HTTP 400/401/403 nie obciążają naszego budżetu błędów, natomiast błędy `429 Too Many Requests` wynikające z przeciążenia naszej infrastruktury — tak).*

---

### 1.4. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 1)

Poniższe stałe stanowią kontrakt wejściowy (`variables.tf` / `locals.tf`), na podstawie którego będziemy wymiarować kolejne warstwy infrastruktury:

```hcl
locals {
  traffic_profile = {
    api_1 = { peak_rps = 24188, stats_rps = 21527, auth_rps = 2274, payments_rps = 387, db_engine = "aurora-postgresql" }
    api_2 = { peak_rps = 750,   stats_rps = 668,   auth_rps = 71,   payments_rps = 12,  db_engine = "aurora-postgresql" }
    api_3 = { peak_rps = 17250, stats_rps = 15353, auth_rps = 1622, payments_rps = 276, db_engine = "aurora-postgresql" }
    api_4 = { peak_rps = 4125,  stats_rps = 3671,  auth_rps = 388,  payments_rps = 66,  db_engine = "aurora-mysql" }
  }
  slo_targets = {
    external_sli = 0.995
    payments_slo = 0.9999
    auth_slo     = 0.9995
    stats_slo    = 0.9990
  }
}

```
