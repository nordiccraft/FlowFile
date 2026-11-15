# FlowFile for macOS

[![Build & Verify](https://github.com/nordiccraft/FlowFile/actions/workflows/release.yml/badge.svg)](https://github.com/nordiccraft/FlowFile/actions/workflows/release.yml)

**FlowFile** er en rask, native filutforsker for macOS 26 – bygget i ren Swift (`SwiftUI` + `AppKit`) med enkeltpanel, topanelsvisning, faner, innebygde filverktøy og macOS **Liquid Glass**.

---

## Installasjon

### Alternativ A: Sømløs installasjon med Homebrew *(Anbefales – ingen Gatekeeper-advarsel)*
Har du [Homebrew](https://brew.sh) på Macen, installerer disse to linjene `FlowFile.app` rett i `Applications`, kontrollerer `SHA-256`-sjekksummen og klargjør appen så den åpner seg rett på første klikk uten bokser i *System Settings*:

```zsh
brew tap nordiccraft/flowfile https://github.com/nordiccraft/FlowFile
brew install --cask flowfile
```

*(Oppdateres senere enten rett inne i FlowFile via **FlowFile → Se etter oppdateringer...**, eller med `brew upgrade --cask flowfile`.)*

### Alternativ B: Ferdigbygd `.dmg` fra GitHub Releases
1. Last ned siste **`.dmg`-fil** fra **[GitHub Releases](https://github.com/nordiccraft/FlowFile/releases/latest)** og dra `FlowFile.app` over til `Applications`.
2. Dobbeltklikk på `FlowFile` i `Applications`. Fordi prosjektet ikke bruker betalt Apple-notarisering ennå, viser macOS meldingen *"FlowFile Not Opened"* første gang:
   - Klikk **Done** (til venstre).
   - Åpne **System Settings → Privacy & Security**, bla ned til **Security** og klikk **Open Anyway** (*Åpne likevel*).

### Alternativ C: Kompiler selv rett fra kildekoden (tar ca. 20 sekunder)
Vil du kompilere din egen lokale kopi direkte fra kildekoden på egen Mac (krever Xcode / Swift Command Line Tools på macOS 26):

```zsh
git clone https://github.com/nordiccraft/FlowFile.git
cd FlowFile
./scripts/build-app.sh release
cp -R build/FlowFile.app /Applications/
```

---

## Sikkerhet, åpenhet og kildekode

FlowFile er utviklet som et uavhengig prosjekt uten kommersielt Apple Developer-abonnement ennå. For at du (og enhver sikkerhetskontroll) skal kunne verifisere nøyaktig hva programmet gjør, ligger alt åpent:

1. **100 % åpen kildekode uten tredjepartsbiblioteker:**  
   Hele kildekoden ligger åpent i [`Sources/FlowFile/`](Sources/FlowFile), og [`Package.swift`](Package.swift) har **null eksterne avhengigheter** – kun Apples egne rammeverk (`AppKit`, `SwiftUI`, `QuickLook`, `Network`, `CryptoKit`, `CoreImage`). Ingen telemetri, ingen analyse-SDK-er og ingen skjulte bakgrunnsprosesser.
2. **Offentlig kompilering via GitHub Actions:**  
   Utgivelsene under **[Releases](https://github.com/nordiccraft/FlowFile/releases/latest)** og [`Casks/flowfile.rb`](Casks/flowfile.rb) bygges og oppdateres direkte fra kildekoden på GitHub sine egne servere via [`.github/workflows/release.yml`](.github/workflows/release.yml), med åpen byggelogg og tilhørende `SHA256SUMS.txt`.
3. **Standard macOS-rettigheter per mappe:**  
   FlowFile krever ikke full tilgang ved installasjon. macOS spør kun om vanlig mappetillatelse første gang du selv navigerer inn i mapper som *Skrivebord*, *Dokumenter* eller *Nedlastinger* (*Full disktilgang* i Systeminnstillinger er helt valgfritt for de som ønsker å slippe enkeltspørsmål per mappe).
4. **Oppdateringer og integritetskontroll:**  
   Når du selv velger å oppdatere i appen (*FlowFile → Se etter oppdateringer...*), krever oppdatereren en gyldig `SHA256SUMS.txt` over HTTPS (avbryter ved manglende eller avvikende sjekksum), sjekker `CFBundleIdentifier` og `codesign --verify --deep --strict`, og erstatter app-pakken atomisk med automatisk tilbakerulling ved feil. *(Merk: så lenge byggene er ad-hoc-signert uten betalt Apple Developer ID-sertifikat, bygger autentisiteten på GitHub HTTPS/kontosikkerhet og åpne GitHub Actions-bygg – eller på den låste `sha256`-verdien i Homebrew Cask.)*

---

## Hovedfunksjoner

- **Enkeltpanel & Topanelsvisning (`⌘D`):** Bytt sømløst mellom oversiktlig enkeltpanel og side-om-side topanelsvisning med faner (`⌘T`), automatisk fane-gjenoppretting og lagrede **Arbeidsområder** (`⌥⌘S`).
- **Forutsigbar tastaturnavigasjon:** Mapper vises alltid samlet øverst, filendelser er synlige, `Enter` åpner alltid valgt mappe/fil, `Backspace` går ett nivå opp, og `F2` endrer navn.
- **Dypsøk (`⇧⌘F`) & Flat undermappe-visning (`⌥⌘B`):** Søk rekursivt på filnavn, tekstinnhold inni filer, filstørrelse og endringsdato – eller flat ut alle undermapper i én samlet tabell.
- **macOS Fargetagger (`⌃1`–`⌃7`):** 100 % kompatible fargetagger som synkroniseres direkte med macOS og kan filtreres fra sidepanelet.
- **Mappesammenligning (`⇧⌘K`) & Synkronisering (`⌥⇧⌘K`):** Sammenlign og synkroniser mapper én vei, to-veis eller i speilmodus med full forhåndsvisning.
- **Diskplass-analyse (`⌥⌘D`) & Duplikat-finner:** Se visuelt hvilke undermapper og store filer som bruker mest diskplass, og finn identiske duplikatfiler verifisert med `SHA-256`.
- **Innebygde hurtigverktøy:** Konverter og skaler bilder (`HEIC`, `PNG`, `TIFF`, `JPG`), slå sammen PDF-er og bilder til én PDF, og beregn `SHA-256`-sjekksum i infopanelet (`⌘I`).
- **Skylagring i sidepanelet:** Automatisk gjenkjenning av **OneDrive**, **Dropbox**, **Google Drive**, **Box** og **iCloud Drive**, inkludert synkroniseringsstatus og *Frigjør lokal plass* på høyreklikk.
- **Drop-hylle (`⌘J`) & Masse-omdøping (`⌘M`):** Samle filer fra ulike mapper før du kopierer/flytter alt samlet, eller gi nytt navn til mange filer samtidig med forhåndsvisning og angreknapp.
- **Smart Delingssenter (`⇧⌘S`):** Lag rene `.zip`-arkiver (uten `.DS_Store` og `__MACOSX`), konverter `.HEIC` til `.JPG`, eller del filer lokalt på eget nettverk med midlertidig **Wi-Fi QR-kode**.
- **Valgfri standard filutforsker i macOS:** Kan settes som standard for *«Vis i Finder»* fra nettlesere, Spotlight og Terminal under Innstillinger (`⌘,`), med ett-klikks tilbakestilling til Finder.
- **Språkstøtte:** Norsk og engelsk brukergrensesnitt (følger macOS automatisk eller velges i Innstillinger `⌘,`).

---

## Lisens

Kildekoden er åpent tilgjengelig for gjennomsyn, sikkerhetsrevisjon og personlig/intern bruk. Se [`LICENSE`](LICENSE) for detaljer.
