<div align="center">

<img src="assets/icon.png" width="160" alt="UpdateBar icon">

# UpdateBar

**Gli aggiornamenti di macOS, a colpo d'occhio. Stile Windows Update, ma per Mac.**

Un'app leggerissima per la menu bar che controlla gli aggiornamenti di sistema<br>
e te li segnala con due frecce e un puntino colorato.

[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](#requisiti)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)](UpdateBar.swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Xcode](https://img.shields.io/badge/Xcode-non%20richiesto-lightgrey)](#installazione)

[Funzionalità](#-funzionalità) · [Installazione](#-installazione) · [Come funziona](#-come-funziona) · [FAQ](#-faq) · [Roadmap](#-roadmap)

</div>

---

## ✨ Perché

Su Windows sai sempre se c'è un aggiornamento: l'icona nella barra delle applicazioni ti avvisa senza disturbare.
Su macOS il badge rosso finisce dentro Impostazioni di Sistema, dove nessuno guarda.

**UpdateBar** porta quell'indicatore nella menu bar del Mac, e ci aggiunge un'informazione in più: **che tipo** di aggiornamento ti aspetta.

<div align="center">
<img src="assets/states.png" width="820" alt="Stati dell'icona in menu bar">
</div>

## 🎨 I colori

| Icona | Stato | Esempio |
|:---:|---|---|
| ⚪️ nessun puntino | Sei aggiornato | — |
| 🔵 blu | Altri aggiornamenti | Command Line Tools, Safari, risposte rapide di sicurezza |
| 🟡 giallo | Aggiornamento minore di macOS | 27.1 → 27.2 |
| 🔴 rosso | Nuova versione maggiore di macOS | 26 → 27 |

Se ci sono più aggiornamenti insieme, il puntino mostra **il più importante**.
Mentre controlla, le frecce diventano semitrasparenti.

## 🚀 Funzionalità

- **Controllo automatico** all'avvio e poi ogni 4 ore
- **Controlla ora** dal menu, con scorciatoia <kbd>⌘</kbd> <kbd>R</kbd>
- **Notifiche native** di macOS, una sola volta per ogni nuovo aggiornamento
- **Elenco degli update** disponibili, con avviso se richiedono il riavvio
- **Un click** su un aggiornamento apre direttamente *Impostazioni → Aggiornamento Software*
- **Avvia al login** con un interruttore (usa `SMAppService`, niente LaunchAgent a mano)
- **Nessuna icona nel Dock**: vive solo in menu bar
- **Si adatta** automaticamente a menu bar chiara e scura
- **Zero dipendenze**: un solo file Swift, compilabile senza Xcode

## 📦 Installazione

Serve solo un Mac con i **Command Line Tools** (non Xcode):

```bash
xcode-select --install
```

Poi:

```bash
git clone https://github.com/AndreaPolazzo/UpdateBar.git
cd UpdateBar
./build.sh
```

Lo script compila, firma ad-hoc, installa l'app in `/Applications` e la avvia.
Da quel momento la cartella clonata non serve più: puoi cancellarla.

> [!TIP]
> Apri il menu di UpdateBar e attiva **Avvia al login** per averla sempre attiva.

### Aggiornare UpdateBar

```bash
git pull && ./build.sh
```

### Disinstallare

1. Menu di UpdateBar → disattiva **Avvia al login** → **Esci**
2. Trascina `/Applications/UpdateBar.app` nel Cestino

## ⚙️ Come funziona

UpdateBar non usa API private né servizi esterni. Sotto il cofano:

```
                 ogni 4 ore / ⌘R
                        │
                        ▼
        /usr/sbin/softwareupdate --list
                        │
                        ▼
     parsing di "Label" + "Title, Version, Action"
                        │
                        ▼
  ┌─────────────────────┼──────────────────────┐
  │                     │                      │
 non è macOS     macOS, stessa major     macOS, major > attuale
  🔵 blu            🟡 giallo                🔴 rosso
```

- La versione attuale viene letta con `ProcessInfo.operatingSystemVersion`
- L'icona è disegnata a runtime partendo dal simbolo SF `arrow.triangle.2.circlepath`, colorata con `labelColor` per seguire il tema della menu bar
- Il puntino ha un bordo trasparente, come l'indicatore di Windows

### Struttura del progetto

```
UpdateBar/
├── UpdateBar.swift   # tutta l'app: modello, checker, icona, menu
├── Info.plist        # LSUIElement = niente Dock
├── AppIcon.icns      # icona dell'app
├── build.sh          # compila, firma, installa, avvia
└── assets/           # immagini del README
```

## ❓ FAQ

<details>
<summary><b>Perché non è sull'App Store?</b></summary>
<br>
Per leggere gli aggiornamenti deve eseguire <code>softwareupdate</code>, cosa che la sandbox dell'App Store non permette.
</details>

<details>
<summary><b>Installa gli aggiornamenti da sola?</b></summary>
<br>
No, di proposito. Installare aggiornamenti di sistema richiede privilegi di amministratore: UpdateBar si limita ad avvisarti e ad aprire Aggiornamento Software.
</details>

<details>
<summary><b>Il primo controllo è lento</b></summary>
<br>
È normale: <code>softwareupdate --list</code> contatta i server Apple e può impiegare 20–60 secondi. Nel frattempo le frecce sono semitrasparenti.
</details>

<details>
<summary><b>Non vedo il puntino rosso anche se esiste una nuova versione di macOS</b></summary>
<br>
Su alcuni Mac (gestiti da un'organizzazione o con aggiornamenti posticipati) <code>softwareupdate</code> non elenca gli upgrade maggiori, quindi UpdateBar non può vederli.
</details>

<details>
<summary><b>macOS dice che l'app non può essere aperta</b></summary>
<br>
Se l'hai ricevuta già compilata da qualcun altro, la firma è ad-hoc: tasto destro sull'app → <b>Apri</b>. Compilandola tu con <code>build.sh</code> non succede.
</details>

<details>
<summary><b>Errore su <code>@State</code> / <code>SwiftUIMacros</code> in compilazione</b></summary>
<br>
I soli Command Line Tools non includono il plugin delle macro di SwiftUI. UpdateBar è scritta apposta senza macro, quindi se vedi questo errore stai compilando una versione modificata.
</details>

## 🗺️ Roadmap

- [ ] Aggiornamenti Homebrew (`brew outdated`)
- [ ] Aggiornamenti App Store (`mas outdated`)
- [ ] Intervallo di controllo configurabile
- [ ] Release precompilate e firmate
- [ ] Localizzazione in inglese
- [ ] Sito con GitHub Pages

## 🤝 Contribuire

Issue e pull request sono benvenute. Per modifiche grosse apri prima una issue per discuterne.

1. Fai un fork del progetto
2. Crea un branch: `git checkout -b feature/nome-feature`
3. Fai commit: `git commit -m "Aggiunge nome-feature"`
4. Push: `git push origin feature/nome-feature`
5. Apri una Pull Request

## 📄 Licenza

Distribuito sotto licenza MIT. Vedi [`LICENSE`](LICENSE).

---

<div align="center">

Fatto con ☕ da [**Andrea Polazzo**](https://andreapolazzo.com)

Se ti è utile, lascia una ⭐

</div>
