# Non-Functional Requirements (NFR) & Traffic Baseline

## 1. Zakres Systemu i Gry
Ekosystem obejmuje **4 interfejsy REST API** oraz **1 aplikację Web** wdrożone w kontenerach **Amazon ECS** na AWS w Europie:

| Tytuł gry | Platforma | Przypisane API | Silnik Bazy Danych | Deklarowane DAU | MAU |
| :--- | :--- | :--- | :--- | ---: | ---: |
| **Pythodorus 3** | Android | API #1 | PostgreSQL / Aurora PG | 6,0M | 75,0M |
| **Theognis per Megara** | Android | API #2 | PostgreSQL / Aurora PG | 0,2M | 1,0M |
| **Agrippa Mosa** | Android | API #3 (wspólne) | PostgreSQL / Aurora PG | 4,0M | 50,0M |
| **Agrippa Mosa 2** | Android | API #3 (wspólne) | PostgreSQL / Aurora PG | 0,3M | 2,0M |
| **Dienekes Plaza** | Android | API #4 (wspólne) | MySQL / Aurora MySQL | 1,0M | 5,0M |
| **Dienekes Plaza Web** | Web | API #4 (wspólne) | MySQL / Aurora MySQL | 0,1M | 1,0M |

---

## 2. Parametry Modelu Ruchu (Traffic Assumptions)
* **Stickiness (DAU / MAU):** `8,6%`
* **Średni dzienny czas gry:** `12 minut` (`720 sekund`)
* **Częstotliwość żądań na aktywnego gracza:** `0,15 req/s`
* **Mnożnik szczytu dobowego (Peak Multiplier):** `3,0x`
* **Rozkład ruchu na endpointy:**
  * `/stats`: `89,0%`
  * `/auth`: `9,4%`
  * `/payments`: `1,6%`

---

## 3. Wymagania Niezależności i Odporności (SLA / DR)
* **Dostępność początkowa (SLI):** `≥ 99,5%`
* **Recovery Point Objective (RPO):** `≤ 5 minut`
* **Recovery Time Objective (RTO):** `≤ 15 minut`
* **Lokalizacja danych i infrastruktury:** Wyłącznie Europa (zgodność z GDPR).

---

## 4. Zasoby i Ograniczenia Organizacyjne
* **Zespół operacyjny:** `22 Senior DevOps` + `22 Senior SRE` (łącznie 44 inżynierów).
* **Budżet i czas:** Brak twardych ograniczeń budżetowych; priorytetem jest maksymalna odporność, skalowalność i czystość operacyjna (*no over-engineering*).