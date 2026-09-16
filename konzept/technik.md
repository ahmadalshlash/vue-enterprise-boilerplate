# Technik: Wie Offline-Nähe funktioniert und womit wir bauen

## 1. Grundproblem

Zwei Smartphones sollen sich **ohne Internet und ohne Server** finden und
Daten austauschen, und zwar **über Plattformgrenzen hinweg** (iPhone ↔ Android).
Dafür kommen nur Funktechniken in Frage, die beide Plattformen Apps zugänglich machen.

## 2. Technologie-Vergleich

| Technik | iOS ↔ Android | Reichweite | Datenrate | Hintergrund | Bewertung |
| --- | --- | --- | --- | --- | --- |
| **Bluetooth Low Energy (BLE), GATT** | ✅ ja | 10–50 m innen, bis ~100 m außen | niedrig (Kilobyte/s) | eingeschränkt, aber möglich | **Basis für Entdeckung und Text** |
| BLE L2CAP-Kanal | ✅ ja (iOS 11+, Android 10+) | wie BLE | mittel (zehn Kilobyte/s+) | wie BLE | Upgrade für Bilder |
| Wi-Fi Direct / Wi-Fi Aware | ❌ iOS gibt Apps keinen Zugriff | 100 m+ | hoch | nein | nur Android ↔ Android |
| Apple MultipeerConnectivity | ❌ nur Apple | ~50 m | hoch | schlecht | nur iOS ↔ iOS |
| Google Nearby Connections | ⚠️ iOS-SDK existiert, wenig verbreitet | variabel | hoch | nein | Risiko: Google-Abhängigkeit, Reifegrad iOS |
| Ultra-Wideband (UWB) | ⚠️ nur neuere Geräte, iOS stark eingeschränkt | 10 m | – | nein | Zukunft für exakte Distanz, nicht als Basis |
| Bluetooth Classic | ❌ iOS gibt Apps keinen Zugriff | 10 m | mittel | nein | ungeeignet |

**Entscheidung:** BLE ist die einzige Technik, die auf beiden Plattformen für
Apps offen ist und Entdeckung *und* Datenaustausch ermöglicht. Das ist auch
der Weg, den etablierte Offline-Messenger (Bridgefy, Bitchat, Briar über BT)
gehen. Wi-Fi Direct / MultipeerConnectivity können später als **optionaler
Turbo** für gleiche Plattformen dienen, sind aber nie die Basis.

## 3. Distanzschätzung

BLE liefert keine Distanz, sondern eine **Signalstärke (RSSI in dBm)**. Daraus
lässt sich Distanz nur grob schätzen:

```text
d ≈ 10 ^ ((TxPower − RSSI) / (10 · n))     n = 2 (frei) … 4 (Innenraum, Körper)
```

Realistische Fehler liegen bei ±50 % und mehr: Handy in der Hosentasche,
Menschenmenge, Wände, unterschiedliche Sendeleistung je Gerätemodell.
**Deshalb zeigen wir keine Meter an, sondern drei Stufen** und glätten den
RSSI über ein gleitendes Fenster (z. B. Median der letzten 5–8 Messungen):

| Stufe | RSSI (Richtwert, gemittelt) | Anzeige |
| --- | --- | --- |
| sehr nah | > −65 dBm | 🟢 bis ca. 10 m |
| nah | −65 … −80 dBm | 🟡 ca. 10–30 m |
| in Reichweite | < −80 dBm | ⚪ ca. 30–100 m |

Die Schwellen werden pro Plattform kalibriert und per Config anpassbar
gehalten. Wer die App nicht mehr sieht (kein Advertising seit ~20 s), fällt
aus der Liste.

Die geforderten „10 bis 100 Meter“ sind mit BLE **außen und bei freier Sicht**
erreichbar; in Innenräumen sind 10–40 m realistisch. Das Board-Mesh
(Weiterleitung über andere Geräte) erweitert die effektive Reichweite später
deutlich über 100 m.

## 4. Plattform-Grenzen, die das Design bestimmen

### 4.1 iOS (CoreBluetooth)

- **Advertising im Vordergrund:** nur Service-UUIDs + lokaler Name, ca. 28 Byte nutzbar.
- **Advertising im Hintergrund:** der lokale Name fällt weg, Service-UUIDs
  wandern in einen „Overflow“-Bereich, den nur andere iPhones im Vordergrund
  sehen. → **Im Hintergrund ist ein iPhone für Android praktisch unsichtbar.**
- **Scannen im Hintergrund:** funktioniert, wenn nach einer konkreten Service-UUID
  gescannt wird (Background Mode `bluetooth-central`). Ergebnisse kommen verzögert.
- **Konsequenz:** iOS-Nutzer werden ehrlich informiert („Du bist nur sichtbar,
  solange die App geöffnet ist“). Im MVP gilt: App im Vordergrund = voll
  sichtbar. Hintergrund-Optimierungen sind Phase 3.
- Berechtigung: `NSBluetoothAlwaysUsageDescription` (Pflicht, Text muss den Zweck erklären).

### 4.2 Android

- **Advertising:** Legacy 31 Byte; mit Bluetooth 5 (Android 8+) Extended
  Advertising bis 254 Byte – aber nicht von iPhones lesbar. → Wir bleiben im
  **Legacy-Format**, damit iOS mitliest.
- **Scannen im Hintergrund:** braucht einen **Foreground Service** mit
  sichtbarer Benachrichtigung („Nearby sucht nach Leuten in der Nähe“).
- **Berechtigungen:** Android 12+: `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`,
  `BLUETOOTH_CONNECT` (mit `neverForLocation`-Flag, sonst zusätzlich Standort).
  Android 6–11: `ACCESS_FINE_LOCATION` ist für BLE-Scan Pflicht – Onboarding
  muss erklären, dass **kein Standort erfasst** wird.
- Herstellerspezifische Akku-Optimierungen (Xiaomi, Huawei, Samsung) können
  den Service killen → Hinweis-Screen mit Link in die Systemeinstellungen.

### 4.3 Gemeinsame Konsequenzen

- Jedes Gerät ist **gleichzeitig Peripheral (sendet Advertising, bietet
  GATT-Dienst) und Central (scannt, verbindet)**. Das ist der Kern; Bibliotheken,
  die nur eine Rolle können, scheiden aus.
- Advertising trägt **nur eine Kennung**; alles weitere (Alias, Status, Profil)
  wird nach Verbindung über GATT gelesen. Details in [protokoll.md](protokoll.md).
- Verbindungen sind teuer (Zeit, Akku): Radar-Infos werden gecacht und nur
  bei neuer Kennung oder nach Ablauf (60 s) nachgeladen.
- Akku-Ziel: < 5 % pro Stunde im Vordergrund. Scan-Intervalle adaptiv (Duty-Cycle),
  nicht dauerhaft.

## 5. Tech-Stack: Vergleich und Empfehlung

Die harte Anforderung „BLE Peripheral **und** Central auf iOS **und** Android“
entscheidet den Vergleich.

| Option | BLE beide Rollen, beide Plattformen | Ein Code für beide Plattformen | Team-Nähe zu Web/Vue | Bewertung |
| --- | --- | --- | --- | --- |
| **Flutter** (Dart) | ✅ Paket `bluetooth_low_energy` (Central + Peripheral, iOS/Android) oder `flutter_blue_plus` + `flutter_ble_peripheral` | ✅ ~95 % | mittel (deklaratives UI ähnlich Vue) | **Empfehlung** |
| **Nativ** (Swift + Kotlin) | ✅ volle Kontrolle über CoreBluetooth / Android BLE | ❌ alles doppelt | gering | Beste Qualität, ~1,8× Aufwand. Weg von Bitchat |
| **React Native / Expo** | ⚠️ `react-native-ble-plx` nur Central; Peripheral-Pakete schlecht gepflegt → eigenes Native-Modul nötig | ✅ | hoch (JS/TS) | nur mit eigenem BLE-Modul, Risiko |
| **Capacitor + Vue** (dieses Repo) | ❌ `@capacitor-community/bluetooth-le` nur Central; kein gepflegtes Peripheral-Plugin → eigenes Plugin in Swift **und** Kotlin | ✅ Web-UI | sehr hoch | Vue-Kenntnisse helfen, aber der schwierige Teil (BLE) muss trotzdem nativ zweimal gebaut werden |
| Kotlin Multiplatform + Compose MP | ⚠️ BLE muss selbst pro Plattform angebunden werden | ✅ Logik, UI weitgehend | gering | interessant, aber Ökosystem für BLE noch dünn |

### Entscheidung: Flutter (umgesetzt)

Die App ist mit Flutter gebaut; die Begründung im Detail:

1. **Einzige Cross-Platform-Option mit fertigen, gepflegten Paketen für beide
   BLE-Rollen** – der riskanteste Teil des Projekts ist damit nicht selbst zu bauen.
2. Ein Code für UI, Krypto, Datenbank, Zustand.
3. Reifes Ökosystem für den Rest: `cryptography` (X25519, Ed25519, ChaCha20-Poly1305),
   `drift` oder `isar` (lokale DB), `riverpod` (State), `flutter_secure_storage` (Schlüssel).
4. Wenn an einer Stelle eine Plattform Sonderbehandlung braucht (iOS-Hintergrund,
   Android Foreground Service), geht das über kleine Platform-Channels, nicht
   über einen kompletten Rewrite.

**Wann stattdessen nativ:** Wenn Hintergrund-Betrieb auf iOS und maximale
Akku-Effizienz von Tag 1 Priorität haben und zwei Entwickler (Swift, Kotlin)
verfügbar sind.

**Was mit dem Vue-Repo passiert ist:** Das ursprüngliche Vue-2-Boilerplate
(Vue CLI, Vuex 3, Jahrgang 2020) war für eine Mobile-App mit Bluetooth
ungeeignet und wurde vollständig durch das Flutter-Projekt ersetzt. Eine
Web-Landingpage kann später separat entstehen.

## 6. Architektur (Flutter, wie umgesetzt)

```text
lib/
├── main.dart
├── app/                 App-Shell mit Tab-Leiste, Theme, Lokalisierung (DE/EN),
│                        Bootstrap (BLE oder Demo), Berechtigungen
├── features/
│   ├── onboarding/      Erklär-Screens, Berechtigung, Alias
│   ├── radar/           Liste mit Nähe-Stufen, Modus-Umschalter, Detail-Sheet
│   ├── board/           Posts, Tags, Reaktionen, Antworten, Melden
│   ├── chat/            Anfragen, Chat-Liste, 1:1-Chat
│   ├── me/              Modus, Alias, Status, Profil-Editor, Blockliste, Datenschutz
│   └── shared/          UI-Bausteine
├── core/
│   ├── protocol/        Konstanten, Frame-Codec, Chunking, CBOR, Datenmodelle
│   ├── crypto/          Identität, EID-Ableitung, Alias, Handshake, Session, KeyStore
│   ├── ble/             NearbyTransport-Interface, BleTransport (Central + Peripheral),
│   │                    FakeWorld/FakeTransport, RSSI-Glättung und Nähe-Stufen
│   ├── storage/         sembast-Datenbank und Repositories
│   ├── moderation/      Blockliste/Meldungen, Rate-Limiter, Wortfilter
│   └── services/        IdentityService, RadarService, ChatService, BoardService,
│                        Engine (verbindet alles, routet Frames, rotiert EIDs)
└── demo/                Simulierte Personen (vollständige Engines mit Autopilot)
```

Schichten kommunizieren nur nach unten: `features → services → core`.
`core/ble` kennt keine Chat-Logik, es transportiert Bytes. Das erlaubt später
einen zweiten Transport (Wi-Fi Direct, Online-Relay), ohne die Features
anzufassen, und macht die **Fake-Welt** möglich: mehrere Engines laufen im
selben Prozess über einen simulierten Funk mit Distanz-basiertem RSSI.

**Tests (umgesetzt):** Protokoll-Codec, Chunking, Krypto (inkl. Handshake-
Angriffe) als Unit-Tests; End-to-End-Tests, in denen zwei bis drei komplette
Engines über die Fake-Welt chatten, Posts synchronisieren, blockieren und
neu starten; Widget-Tests der Screens über dieselbe Fake-Welt. Echte
BLE-Tests brauchen **zwei physische Geräte** (Simulatoren haben kein Bluetooth);
Testmatrix minimal: 1 iPhone + 1 Android (idealerweise ein günstiges Gerät
eines Herstellers mit aggressiver Akku-Optimierung).

## 7. Roadmap

| Phase | Ziel | Umfang |
| --- | --- | --- |
| **0 – Spike (1–2 Wochen)** | Beweis: iPhone ↔ Android sehen sich und tauschen 1 Textnachricht offline aus | Flutter-Projekt, Advertising + Scan, GATT-Verbindung, RSSI-Stufen, roher Chat |
| **1 – MVP (6–8 Wochen)** | Testbare App für Freunde/Beta | Radar, Modi, Kontaktanfrage, E2E-Chat, Board ohne Mesh, Blockieren/Melden, Onboarding, DE/EN |
| **2 – Beta (4–6 Wochen)** | Store-reif | Bilder im Chat (L2CAP), Store-and-Forward, Akku-Tuning, Android Foreground Service, Wortfilter, Datenschutzerklärung, TestFlight / Play Internal Testing |
| **3 – Reichweite** | „Ganzer Zug, ganzes Festival“ | Board-Mesh (3–5 Hops, TTL, Dedup), Gruppen-Chats, Notfall-Modus |
| **4 – Optional online** | Komfort ohne Zwang | Opt-in-Relay für Chats, echtes Melde-Backend, Push |

Phase 0 ist der wichtigste Meilenstein: Wenn Cross-Platform-BLE mit dem
gewählten Stack nicht sauber läuft, wird **vor** dem MVP der Stack gewechselt,
nicht danach.
