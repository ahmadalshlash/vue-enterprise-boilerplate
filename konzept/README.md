# Umkreis – Offline-Kontakt-App

> Menschen im Umkreis von 10 bis 100 Metern entdecken, anonym oder mit Profil
> anschreiben und lokal posten – **ganz ohne Internet, ohne Server, ohne Account.**

Dieses Verzeichnis ist das Fundament für die App. Es ist bewusst
technologie-neutral geschrieben, damit die Entscheidung für den Tech-Stack
(siehe [technik.md](technik.md)) getroffen werden kann, ohne dass das Konzept
sich ändert.

| Dokument | Inhalt |
| --- | --- |
| [README.md](README.md) (dieses) | Vision, Zielgruppe, Funktionen, MVP-Abgrenzung, Nutzerflows, Datenschutz & Sicherheit |
| [technik.md](technik.md) | Wie Offline-Nähe technisch funktioniert, Distanzschätzung, Plattform-Grenzen, Stack-Vergleich mit Empfehlung, Roadmap |
| [protokoll.md](protokoll.md) | Bluetooth-Advertising, Identitäten, Verschlüsselung, Nachrichten- und Post-Format |

---

## 1. Vision

Überall, wo Menschen zusammenkommen (Zug, Uni, Festival, Wartezimmer,
Flugzeug, Katastrophenfall ohne Netz), entsteht ein **lokaler, flüchtiger
Raum**. Die App macht diesen Raum sichtbar:

- Wer ist gerade in meiner Nähe und offen für Kontakt?
- Was posten Leute hier, jetzt?
- Kann ich jemanden ansprechen, ohne mich sofort zu offenbaren?

Das Ganze läuft **Gerät zu Gerät** über Bluetooth Low Energy (BLE). Es gibt
keinen Server, der weiß, wer wo war. Sobald man sich entfernt, ist man weg.

## 2. Zielgruppe & Abgrenzung

**Für wen:** Menschen, die in ihrer physischen Umgebung Kontakt aufnehmen
wollen: kennenlernen, Hilfe fragen, Mitfahrer suchen, spontane Gruppen, aber
auch Krisensituationen ohne Mobilfunknetz.

**Was die App NICHT ist:**

- kein Dating-Produkt (kein Swipen, kein Matching-Algorithmus)
- kein weltweiter Messenger (Reichweite ist bewusst physisch begrenzt)
- kein soziales Netzwerk mit Follower-Zahlen und Feed-Ranking

Diese Abgrenzung ist wichtig für App-Store-Freigabe und Missbrauchsschutz
(siehe Abschnitt 7).

## 3. Kernfunktionen

### 3.1 Radar – Leute in der Nähe

- Liste (und optional eine „Radar“-Ansicht in Ringen) aller Geräte mit der App
  in Funkreichweite.
- Pro Person: Anzeigename **oder** anonymer Platzhalter (z. B. „Blauer Fuchs“),
  Avatar/Emoji, Status-Zeile („Suche Mitfahrgelegenheit nach Köln“), Nähe-Stufe.
- Nähe wird **in Stufen** angezeigt, nicht in exakten Metern:
  - 🟢 **sehr nah** (bis ca. 10 m)
  - 🟡 **nah** (ca. 10–30 m)
  - ⚪ **in Reichweite** (ca. 30–100 m)
  - Grund: Funk-Distanzschätzung ist ungenau, siehe [technik.md](technik.md#3-distanzschätzung).
- Filter: nur Personen mit Profil / alle / nur mit Status.

### 3.2 Sichtbarkeit & Identität (drei Modi)

| Modus | Was andere sehen | Wer kann mich anschreiben |
| --- | --- | --- |
| **Unsichtbar** | nichts – ich sehe aber andere und lese das Board | niemand |
| **Anonym** (Standard) | zufälliger Alias + Emoji, kein Bild, kein echter Name | jeder in Reichweite |
| **Profil** | frei gewählter Name, Bild, Kurz-Bio, Interessen-Tags | jeder in Reichweite |

- Der Alias im Anonym-Modus wechselt regelmäßig (Standard: alle 24 h, manuell
  jederzeit), damit niemand über Tage wiedererkannt werden kann.
- Wechsel zwischen den Modi jederzeit mit einem Tipp, sichtbar in der oberen Leiste.
- Ein **Profil ist rein lokal** auf dem Gerät; es wird nur an Geräte in
  Reichweite gesendet, die es auch anfragen.

### 3.3 Anschreiben – 1:1-Chat

- Erste Nachricht ist eine **Kontaktanfrage** („Hi, bist du auch auf dem Weg
  nach …?“). Der Empfänger sieht sie in einem separaten Bereich „Anfragen“ und
  kann annehmen, ignorieren oder blockieren.
- Nach Annahme: normaler Chat mit Text, Emoji, kleinen Bildern (komprimiert).
- **Ende-zu-Ende verschlüsselt**, Schlüssel werden beim ersten Kontakt
  ausgetauscht ([protokoll.md](protokoll.md#4-verschlüsselung)).
- Nachrichten kommen an, solange beide in Reichweite sind. Entfernt sich der
  andere, wird die Nachricht als „wartet auf Nähe“ markiert und beim nächsten
  Treffen zugestellt (Store-and-Forward, nur lokal).
- Anonyme Chats können jederzeit **„aufgedeckt“** werden: Ich schicke mein
  Profil in den Chat, ohne dass es für alle anderen sichtbar wird.

### 3.4 Board – anonym posten

- Ein **lokales Schwarzes Brett**: Alles, was ich poste, sehen nur Geräte in
  Reichweite. Posts verbreiten sich von Gerät zu Gerät weiter (Mesh, max. 3–5
  Hops), sodass ein Festivalgelände oder ein ganzer Zug abgedeckt sein kann.
- Post = Text (bis 500 Zeichen), optional ein Tag (#hilfe, #mitfahren,
  #verloren, #party, #frage …), optional Ablaufzeit (1 h / 6 h / 24 h).
- Anonym (Alias) oder mit Profil posten – pro Post wählbar.
- Reaktionen (👍 ❤️ 🙋) und Antworten unterhalb des Posts.
- **Jeder Post hat „Melden“ und „Verfasser blockieren“.**

### 3.5 Weitere Funktionen (nach dem MVP)

- **Gruppen-Chats** für einen Ort („Wagen 7“, „Bühne Süd“).
- **Notfall-Modus**: großer roter Button, Post mit #notfall bekommt maximale
  Weiterleitungs-Priorität und Ton auf allen Geräten in Reichweite.
- **Interessen-Match**: Hinweis, wenn jemand in der Nähe gleiche Tags im Profil hat.
- **Optionale Online-Brücke**: Wenn beide Geräte später Internet haben, kann
  ein Chat freiwillig auf einen Relay-Server umziehen. Streng opt-in, nicht im MVP.

## 4. MVP-Abgrenzung (Phase 1)

Das MVP soll zeigen, dass **iPhone ↔ Android** sich offline finden und
schreiben können. Alles andere ist Beiwerk.

**Im MVP:**

1. Radar-Liste mit Nähe-Stufen (iOS ↔ Android, iOS ↔ iOS, Android ↔ Android)
2. Anonym-Modus mit rotierendem Alias; einfaches Profil (Name, Emoji, Status)
3. Kontaktanfrage + 1:1-Textchat, Ende-zu-Ende verschlüsselt
4. Board mit Text-Posts (ohne Mesh-Weiterleitung, nur direkte Reichweite)
5. Blockieren und Melden (Melden = lokal speichern + Blockieren, kein Server)
6. Onboarding mit Erklärung der Bluetooth-Berechtigungen

**Nicht im MVP:** Bilder im Chat, Mesh-Weiterleitung, Gruppen, Notfall-Modus,
Online-Brücke, Hintergrund-Betrieb über längere Zeit auf iOS (siehe Technik).

## 5. Nutzerflows

### 5.1 Erster Start

1. Splash → drei Erklär-Screens (Was ist das? Wie funktioniert Nähe? Deine Kontrolle: Modi & Blockieren).
2. Bluetooth-Berechtigung anfordern, mit klarer Begründung im Systemdialog.
3. Alias wird generiert („Du bist gerade: **Grüner Falke** 🦅“). Option: „Profil anlegen“ oder „Erst mal anonym bleiben“.
4. Landet im Radar.

### 5.2 Jemanden anschreiben

Radar → Person antippen → Detail-Sheet (Alias/Profil, Nähe, Status) →
„Nachricht senden“ → Text eingeben → wird als Anfrage verschickt →
Empfänger: Benachrichtigung „Neue Anfrage von *Grüner Falke* (sehr nah)“ →
Annehmen → Chat.

### 5.3 Anonym posten

Board → „+“ → Text, Tag, Ablaufzeit, Schalter „anonym / als Profil“ →
Posten → erscheint sofort bei allen in Reichweite.

### 5.4 Blockieren

Überall, wo eine Person erscheint: Long-Press / „…“ → „Blockieren“. Blockiert
wird der **kryptografische Fingerabdruck** des Geräts, nicht der Alias – ein
Alias-Wechsel hilft dem Blockierten nicht.

## 6. Informationsarchitektur (Screens)

```text
Tab-Leiste
├── Radar        – Liste/Ringe, Filter, Sichtbarkeits-Schalter oben
├── Board        – Posts in Reichweite, Tag-Filter, „+“
├── Chats        – Anfragen | Aktive Chats
└── Ich          – Modus (Unsichtbar/Anonym/Profil), Profil bearbeiten,
                   Alias neu würfeln, Blockliste, Datenschutz, Über die App
```

## 7. Datenschutz, Sicherheit & Store-Anforderungen

### 7.1 Datenschutz-Prinzipien

- **Kein Server, kein Account, keine Telefonnummer.** Es gibt nichts, das
  gehackt oder herausverlangt werden kann.
- **Datenminimierung im Funk:** Über Bluetooth wird nur ein rotierender,
  nicht rückverfolgbarer Kurz-Identifikator gesendet. Profil und Nachrichten
  gehen nur nach expliziter Verbindung, verschlüsselt.
- **Tracking-Schutz:** Rotierende Kennungen (Standard 15 Minuten auf
  Funk-Ebene, 24 h auf Alias-Ebene) verhindern, dass ein Dritter Bewegungen
  über Zeit verfolgt. Details in [protokoll.md](protokoll.md#2-identitäten).
- **Lokale Daten** (Chats, Profil, Blockliste) liegen verschlüsselt im
  App-Speicher (iOS Keychain / Android Keystore für Schlüssel).
- **DSGVO:** Da keine Verarbeitung durch einen Verantwortlichen im Sinne eines
  Servers stattfindet, ist die Datenschutzerklärung kurz, muss aber existieren
  (Store-Pflicht) und erklären: was gesendet wird, an wen, wie lange.

### 7.2 Missbrauchsschutz (Pflicht für App Store & Google Play)

Apps mit nutzergenerierten Inhalten (UGC) müssen laut Apple-Richtlinie 1.2
und Google Play UGC-Policy mindestens bieten:

- Filter für anstößige Inhalte → lokale Wortliste + Nutzer kann Board-Tags ausblenden
- Melden von Inhalten → „Melden“ auf jedem Post/Chat; ohne Server heißt das:
  lokal blockieren + optional Meldung exportieren; mit späterer Online-Brücke
  echtes Melde-Backend
- Blockieren von Nutzern → per Geräte-Fingerabdruck, siehe 5.4
- Kontaktdaten für Beschwerden → im „Über“-Screen

Zusätzlich sinnvoll:

- **Rate-Limits** auf Funk-Ebene: max. N Posts / Minute pro Gerät, sonst
  werden weitere Posts von diesem Gerät lokal ignoriert (Spam-Schutz).
- **Kontaktanfrage-Prinzip**: niemand kann mir ungefragt eine Nachrichtenflut
  schicken; bis zur Annahme sehe ich nur eine Anfrage-Zeile.
- **Altersfreigabe:** realistisch 17+ (Apple) / 16+ oder 18+ (Google) wegen
  anonymer Kommunikation. Das ist im Store-Listing so anzugeben.

### 7.3 Sicherheitsmodell (Kurzfassung)

| Angriff | Gegenmaßnahme |
| --- | --- |
| Mitlesen im Funk | E2E-Verschlüsselung (X25519 + XChaCha20-Poly1305) |
| Verfolgen einer Person über Zeit | rotierende Funk-IDs und Aliase |
| Sich als jemand anderes ausgeben | Signatur mit Geräteschlüssel; „aufgedecktes“ Profil ist signiert |
| Spam / Flooding | Rate-Limits, Anfrage-Prinzip, Blockliste, TTL auf Posts |
| Nachrichten im Mesh manipulieren | Signierte Posts; Weiterleiter können lesen (Board ist öffentlich), aber nicht ändern |
| Gerät verloren | lokale Daten verschlüsselt, App-Sperre per Biometrie (Phase 2) |

## 8. Offene Produkt-Entscheidungen

Für das MVP wurde entschieden (änderbar):

1. **Tech-Stack**: Flutter → Begründung in [technik.md](technik.md#5-tech-stack-vergleich-und-empfehlung).
2. **Standard-Modus beim ersten Start**: Anonym (niedrige Hürde, sicher).
3. **Name**: *Umkreis* (Arbeitstitel „Nearby“ kollidierte mit Google-Produkten). Alternativen bleiben *Radius*, *Hier*, *Funken*.
4. **Board-Reichweite im MVP**: nur direkte Reichweite; Mesh ist Phase 3.
5. **Alias-Sprache**: DE und EN, je nach App-Sprache.

Offen bleibt die **Kalibrierung der Nähe-Stufen** auf echten Geräten und die
Entscheidung, ob der Android-Hintergrund-Betrieb (Foreground Service) schon in
Phase 2 kommt.
