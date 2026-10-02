# RTSP Overlay

[English](README.md) · **Italiano**

App nativa macOS leggerissima (< 1 MB, nessuna dipendenza) per vedere in diretta telecamere IP e NVR via RTSP,
anche come finestre flottanti sempre in primo piano. Funziona con qualunque sorgente RTSP H.264/H.265;
per le telecamere che non usano lo schema di URL predefinito basta impostare il percorso personalizzato.

L'interfaccia è in inglese e in italiano: la lingua segue quella di macOS.

![Tre telecamere in overlay sopra le altre finestre e il menu nella barra](docs/screenshot.it.svg)
<sub>Immagine illustrativa.</sub>

## Installazione

### 1. Requisiti
- macOS 14 (Sonoma) o successivo, su Apple silicon o Intel.
- Strumenti da riga di comando per sviluppatori di Apple (Swift 5.9 o successivo). Se non li hai (né Xcode):
  ```bash
  xcode-select --install
  ```
  Per verificare: `swift --version`.

### 2. Clona il repository
```bash
git clone https://github.com/andreagenovese/RTSPOverlay.git
cd RTSPOverlay
```

### 3. Compila
```bash
./build.sh
```
Compila in modalità release e crea `build/RTSPOverlay.app` (firmata ad hoc, meno di 1 MB).

### 4. Installa
```bash
cp -R build/RTSPOverlay.app /Applications/
open /Applications/RTSPOverlay.app
```
L'app non ha icona nel Dock: cerca l'icona 📹 nella barra dei menu. Al primo avvio si apre la finestra delle impostazioni.

### 5. Primo avvio
- macOS chiede il permesso per la **rete locale**: va concesso, altrimenti l'app non raggiunge le telecamere.
  Si può cambiare in seguito da Impostazioni di Sistema → Privacy e sicurezza → Rete locale.
- Aggiungi le telecamere nella finestra delle impostazioni (vedi [Configurazione](#configurazione)).
- Facoltativo: per avviarla automaticamente, aggiungila in Impostazioni di Sistema → Generali → Elementi login.

Dato che l'app la compili tu, Gatekeeper non la blocca. Se copi l'app compilata su un altro Mac
e macOS si rifiuta di aprirla, esegui `xattr -dr com.apple.quarantine /Applications/RTSPOverlay.app`.

### Aggiornamento
```bash
cd RTSPOverlay
git pull
./build.sh
rm -rf /Applications/RTSPOverlay.app && cp -R build/RTSPOverlay.app /Applications/
```
Chiudi l'app dal suo menu prima di sostituirla. Telecamere e impostazioni vengono mantenute.

### Disinstallazione
Elimina `/Applications/RTSPOverlay.app`. Per rimuovere anche impostazioni e password:
```bash
defaults delete local.rtspoverlay.app
security delete-generic-password -s RTSPOverlay
```

## Uso
- Icona 📹 nella barra dei menu: elenco telecamere (clic = apri/chiudi overlay), griglia, impostazioni.
- **Overlay**: trascina per spostare, ridimensiona dai bordi (mantiene le proporzioni).
  - Doppio clic: passa da stream secondario (leggero) a principale (HD).
  - Tasto destro: sempre in primo piano, opacità, ignora clic, ricollega.
- Posizione, dimensione e overlay aperti vengono ricordati al riavvio.
- Le password stanno nel Portachiavi di macOS.

## Configurazione
| Campo | Valore tipico |
|---|---|
| Indirizzo | IP locale (192.168.1.100) oppure DDNS/IP pubblico |
| Porta RTSP | 554 (o la porta inoltrata sul router) |
| Canale | 1 per telecamera singola; per NVR il numero dell'ingresso |

URL generato: `rtsp://host:554/Streaming/Channels/<canale>01` (principale) / `…02` (secondario).
Il pulsante "duplica" crea velocemente la voce del canale successivo dello stesso NVR.

Codec supportati: H.264 e H.265 (decodifica hardware). MJPEG non è supportato.

## Diagnostica
```bash
build/RTSPOverlay.app/Contents/MacOS/RTSPOverlay --probe 'rtsp://admin:password@192.168.1.100:554/Streaming/Channels/102'
```
Si collega, decodifica circa 5 secondi di video e stampa codec, risoluzione, fps ed eventuali errori (in inglese).

## Licenza
[MIT](LICENSE)
