# Protokoll: Funk, Identität, Verschlüsselung, Nachrichten

Dieses Dokument ist die technische Referenz für alles, was zwischen zwei
Geräten ausgetauscht wird. Es ist unabhängig vom App-Framework; jede
Implementierung (Flutter, nativ, …) muss sich daran halten, damit Geräte
mit unterschiedlichen App-Versionen und Plattformen zusammenarbeiten.

Alle Mehrbyte-Zahlen sind **Big-Endian**. Strings sind **UTF-8**. Strukturierte
Nutzdaten werden mit **CBOR** kodiert (kompakt, schemafrei, auf allen
Plattformen verfügbar). Protokollversion: **1**.

## 1. Bluetooth-Advertising

Ziel: Andere Geräte erkennen, dass hier die App läuft, mit minimalem Payload
(iOS und Android-Legacy erlauben effektiv ~28 Byte) und ohne verfolgbare Kennung.

### 1.1 Advertising-Paket

| Feld | Inhalt |
| --- | --- |
| Service-UUID (128 Bit) | eine feste UUID für die App, z. B. `7E1A3F00-9C4B-4D2E-8F5A-2B6C1D0E9A11` (wird beim Projektstart einmalig generiert und fixiert) |
| Local Name (nur iOS im Vordergrund, Android immer) | `N` + Base64url der 8-Byte-Ephemeral-ID (siehe 2.2) – 12 Zeichen |

- Mehr als das steht **nicht** im Advertising. Alias, Modus, Status werden per GATT gelesen.
- Der Scanner filtert **ausschließlich** auf die Service-UUID (notwendig für
  iOS-Hintergrund-Scan, spart Akku).
- Geräte im Modus **Unsichtbar** senden **kein** Advertising, scannen aber weiter.

### 1.2 Zeitverhalten

| Parameter | Wert |
| --- | --- |
| Advertising-Intervall | 250–500 ms (Balanced) |
| Scan-Zyklus im Vordergrund | 4 s scannen / 2 s Pause |
| Scan-Zyklus im Hintergrund (Android) | 2 s / 10 s |
| „nicht mehr in Reichweite“ | kein Paket seit 20 s |
| RSSI-Glättung | Median der letzten 5 Messungen |

## 2. Identitäten

Es gibt drei Ebenen, jede mit eigener Lebensdauer. Nur die unterste ist im
Funk sichtbar.

| Ebene | Was | Lebensdauer | Sichtbar für |
| --- | --- | --- | --- |
| **Geräte-Identität** | Ed25519-Schlüsselpaar, erzeugt bei Installation. Fingerabdruck = erste 16 Byte von SHA-256 über den Public Key | bis App-Reset | nur Kontakten nach Anfrage-Annahme; Basis für Blockliste |
| **Alias** | Anzeigename + Emoji im Anonym-Modus, z. B. „Grüner Falke 🦅“ | 24 h oder manuell | jedem in Reichweite (per GATT) |
| **Ephemeral-ID (EID)** | 8 Byte, im Advertising | 15 Minuten | jedem in Funkreichweite |

### 2.1 Warum drei Ebenen

- Ein Dritter, der nur BLE mitschneidet, sieht alle 15 Minuten eine neue EID
  → keine Verfolgung über Zeit.
- Wer in Reichweite die App nutzt, sieht einen Alias, der sich täglich ändert
  → keine Wiedererkennung über Tage, aber stabil genug für „den von vorhin“.
- Wer mit mir gechattet hat, kennt meinen Fingerabdruck → Blockieren wirkt
  dauerhaft, Chat-Verlauf bleibt zuordenbar.

### 2.2 Ableitung der EID

```text
epoch  = floor(unix_time / 900)                     // 15-Minuten-Fenster
eid    = HMAC-SHA256(key = alias_secret, msg = "eid" || epoch)[0..8]
```

`alias_secret` ist ein 32-Byte-Zufallswert, der mit dem Alias rotiert. Damit
kann ein Gerät, das meinen aktuellen Alias kennt (z. B. offener Chat), meine
EID über die Fenstergrenze hinweg wiedererkennen und den Chat nahtlos
fortsetzen; Fremde können es nicht.

## 3. GATT-Dienst

Jedes sichtbare Gerät bietet einen GATT-Dienst mit derselben Service-UUID an.

| Characteristic | UUID-Suffix | Eigenschaften | Inhalt |
| --- | --- | --- | --- |
| **Presence** | `…0001` | Read | CBOR: `{v, mode, alias, emoji, status, hasProfile, eid}` – max. 180 Byte |
| **Inbox** | `…0002` | Write (with response) | eingehende Frames (Abschnitt 5), gechunkt |
| **Outbox** | `…0003` | Notify | ausgehende Frames an den verbundenen Client |
| **Profile** | `…0004` | Read | CBOR: signiertes Profil (Name, Bio, Tags, Avatar-Hash); nur bei `hasProfile` |
| **Board** | `…0005` | Read | CBOR-Liste der letzten N Post-IDs + Zeitstempel (für Sync, Abschnitt 6) |

- MTU wird nach Verbindung ausgehandelt (Ziel 512 Byte, Fallback 185 Byte, Minimum 23).
- Alle Frames größer als MTU−3 werden **gechunkt** (Abschnitt 5.1).
- Verbindungen werden nach 10 s Inaktivität getrennt; ein Gerät hält maximal 4–6
  gleichzeitige Verbindungen.

## 4. Verschlüsselung

### 4.1 Primitive

| Zweck | Algorithmus |
| --- | --- |
| Identität / Signaturen | Ed25519 |
| Schlüsselaustausch | X25519 (ephemer und statisch) |
| Handshake | Drei Nachrichten nach dem Muster von Noise `XX`: erst ephemer-ephemer, dann beidseitig verschlüsselt übertragene statische Schlüssel; Authentifizierung über Ed25519-Signaturen über das Transkript |
| Nachrichten-Verschlüsselung | XChaCha20-Poly1305 (24-Byte-Zufalls-Nonce, Drahtformat `nonce ‖ ciphertext ‖ mac`) |
| Hashing / KDF | SHA-256, HKDF-SHA256 |

### 4.2 Ablauf Kontaktanfrage

```text
A → B  msg1 = eA                                             (Frame HELLO)
B → A  msg2 = eB ‖ AEAD(kResp, {sB, idB, sigB})              (Frame HANDSHAKE, step 2)
A → B  msg3 = {b: AEAD(kInit, {sA, idA, sigA}), p: AEAD(keyA→B, erste Nachricht)}
                                                             (Frame HANDSHAKE, step 3)

transcript = "umkreis/hs/1" ‖ eA ‖ eB
ee = DH(eA, eB)   es = DH(eA, sB)   se = DH(sA, eB)
kResp  = HKDF(ee,            salt = transcript, info = "resp-static")
kInit  = HKDF(ee ‖ es,       salt = transcript, info = "init-static")
master = HKDF(ee ‖ es ‖ se,  salt = transcript, info = "session")
keyA→B = HKDF(master, salt = transcript, info = "a2b")
keyB→A = HKDF(master, salt = transcript, info = "b2a")
sigX   = Ed25519(idX, transcript ‖ rolle ‖ sX)      rolle ∈ {"init", "resp"}
```

1. A liest Presence von B, entscheidet anzuschreiben.
2. A → B: `HELLO` mit As ephemerem X25519-Key.
3. B → A: `HANDSHAKE` Schritt 2 mit Bs ephemerem Key und Bs verschlüsseltem, signiertem statischem Bündel.
4. A prüft Bs Signatur, sendet `HANDSHAKE` Schritt 3 mit eigenem Bündel **plus**
   erster Chat-Nachricht = die Kontaktanfrage.
5. Ab hier: ein Schlüssel pro Richtung; jede Nachricht einzeln AEAD-verschlüsselt.
6. B sieht die Anfrage. Erst bei **Annahme** wird der Chat aktiv;
   bei Ablehnung bleibt er stumm; bei Blockieren wird As Fingerabdruck gespeichert.
   Ist A bereits blockiert, verwirft B den Handshake still.

Ein Mitschneidender sieht nie eine Identität im Klartext (Tests prüfen, dass
keine Public Keys in msg1–msg3 vorkommen), und ein Angreifer, der `eB`
austauscht, scheitert an Bs Signatur über das Transkript.

### 4.2.1 Kontakt-Schlüssel (Wiedererkennung über EIDs)

Nach Annahme schickt jede Seite dem Kontakt **verschlüsselt** ihr aktuelles
`alias_secret` (Nachrichten-Art `contactKey`), ebenso nach jeder
Alias-Rotation. Damit kann der Kontakt meine EIDs (Abschnitt 2.2) berechnen
und wartende Nachrichten zustellen, sobald ich wieder in Reichweite bin.
Fremde können das nicht.

### 4.3 Board-Posts

Posts sind **öffentlich** in Reichweite, deshalb **nicht verschlüsselt, aber
signiert**:

- Anonyme Posts werden mit einem **Post-Schlüssel** signiert, der pro Alias-Periode
  neu erzeugt wird → Antworten können dem gleichen Verfasser zugeordnet werden,
  aber nicht dem Geräte-Fingerabdruck.
- Profil-Posts werden mit dem Geräteschlüssel signiert.
- Blockieren eines anonymen Posters blockiert den Post-Schlüssel (für die
  laufende Alias-Periode) **und**, sobald eine Verbindung besteht, die EID-Kette;
  vollständiges Blockieren per Fingerabdruck ist erst nach einem Chat möglich.
  Das ist ein bewusster Trade-off zugunsten der Anonymität.

## 5. Frame-Format (Inbox/Outbox)

Jede logische Nachricht ist ein **Frame**:

```text
+--------+--------+----------+------------------+
| ver(1) | type(1)| len(2)   | payload (CBOR)   |
+--------+--------+----------+------------------+
```

| type | Name | Payload |
| --- | --- | --- |
| `0x01` | HELLO | msg1 (32 Byte ephemerer X25519-Key) |
| `0x02` | HANDSHAKE | `{step: 2\|3, data}` (Abschnitt 4.2) |
| `0x10` | MSG | verschlüsselt: `{id, ts, kind: text\|image\|reveal\|ack\|contactKey, body}` |
| `0x11` | ACK | verschlüsselt: MSG mit `kind: ack`, `body` = Base64(CBOR `{ids: [...]}`) |
| `0x20` | POST | `{id, ts, ttl, alias, emoji, tag, text, replyTo?, sig, pubkey, hops}` |
| `0x21` | POST_REACT | `{postId, reaction, sig, pubkey}` |
| `0x22` | POST_SYNC_REQ | `{have: [ids...]}` |
| `0x30` | REVEAL | verschlüsselt: signiertes Profil (Chat-Aufdeckung) |
| `0x7F` | ERROR | `{code, msg}` |

### 5.1 Chunking

Frames, die nicht in MTU−3 passen, werden zerlegt:

```text
+---------+---------+---------+----------------+
| seq(2)  | total(2)| frameId(2)| bytes         |
+---------+---------+---------+----------------+
```

Empfänger sammelt bis `seq == total−1`, prüft Gesamtlänge, dekodiert. Nach 5 s
ohne Fortsetzung wird der Puffer verworfen. Maximale Frame-Größe im MVP: 4 KiB
(Text); Bilder (Phase 2) laufen über L2CAP mit eigenem Streaming.

### 5.2 Zustellung & Store-and-Forward

- Jede MSG hat eine 16-Byte-ID (zufällig). Der Empfänger antwortet mit ACK.
- Ohne ACK bleibt die Nachricht in der lokalen **Outbox-Queue** mit Status
  „wartet auf Nähe“. Sobald die EID-Kette des Empfängers (Abschnitt 2.2) oder
  nach Aufdeckung sein Fingerabdruck wieder gesehen wird, wird erneut zugestellt.
- Queue-Einträge verfallen nach 7 Tagen.

## 6. Board-Verbreitung

### 6.1 MVP (nur direkte Reichweite)

Sobald ein Peer im Radar aufgelöst ist, liest das Gerät dessen
**Board**-Characteristic (IDs + Zeitstempel), schickt ihm direkt alle eigenen
Posts, die er nicht hat, und fragt mit `POST_SYNC_REQ` (eigene IDs) nach dem
Rest; der Peer antwortet mit `POST`-Frames. Neue eigene Posts und Reaktionen
werden zusätzlich sofort an alle aufgelösten Peers gepusht.

Empfangene Posts werden verworfen, wenn Signatur, Länge, TTL (max. 24 h) oder
Rate-Limit nicht passen; Treffer des Wortfilters werden gespeichert, aber
ausgeblendet.

### 6.2 Mesh (Phase 3)

- Jeder Post trägt `hops` (Start 0) und `ttl` (Ablaufzeit).
- Ein Gerät leitet Posts weiter, solange `hops < 4` und `ttl` nicht abgelaufen;
  vor Weiterleitung `hops + 1`.
- **Dedup** über Post-ID mit Bloom-Filter/Set der letzten 24 h.
- Signaturen werden vor Weiterleitung geprüft; ungültige Posts werden verworfen,
  nicht weitergeleitet.
- Priorität: Tag `#notfall` wird zuerst synchronisiert und darf `hops < 8`.

## 7. Rate-Limits & Missbrauch (lokal erzwungen)

| Regel | Wert |
| --- | --- |
| Kontaktanfragen pro Ziel | 1 offen; erneut erst nach Ablehnung + 1 h |
| Posts pro Absender-Schlüssel | max. 5 / 10 min, sonst lokal ignoriert |
| Post-Text | max. 500 Zeichen; Wortfilter lokal (ausblenden, nicht löschen) |
| Verbindungsversuche pro Gerät | max. 3 / min |
| Blockliste | Fingerabdrücke + Post-Schlüssel + EID-Ketten, unbegrenzt, lokal, exportierbar |

## 8. Versionierung

- `ver` im Frame-Header und `v` in Presence. Unbekannte höhere Version →
  Gerät wird im Radar mit Hinweis „App-Update nötig“ angezeigt, Chat nicht möglich.
- Neue Frame-Typen sind additiv; unbekannte Typen werden ignoriert und nicht weitergeleitet.
- Die Service-UUID ändert sich **nie** (sonst finden sich alte und neue Versionen nicht).

## 9. Testfälle für Phase 0 (Spike)

1. iPhone (Vordergrund) und Android (Vordergrund) sehen sich innerhalb 5 s.
2. RSSI-Stufe wechselt korrekt beim Entfernen von 1 m → 15 m → 40 m (außen).
3. HELLO → HANDSHAKE → MSG „Hallo“ kommt in beide Richtungen an, Klartext nie im BLE-Sniffer (nRF Connect) sichtbar.
4. EID wechselt nach 15 Minuten; offener Chat bleibt zuordenbar.
5. Unsichtbar-Modus: Gerät verschwindet bei anderen innerhalb 20 s, sieht selbst weiter alle.
6. Android bleibt sichtbar, wenn App im Hintergrund (Foreground Service); iPhone-Verhalten dokumentieren.
