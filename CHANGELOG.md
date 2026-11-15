# Endringslogg for FlowFile

Alle viktige nyheter, forbedringer og feilrettinger i FlowFile dokumenteres her og vises direkte i oppdateringsvinduet i appen.

## [1.1.0] - 2026-11-15

- **Dypsøk i undermapper og filinnhold (`⇧⌘F`):** Rekursivt søk på filnavn, tekstinnhold inni filer (med forhåndsvisning av trefflinje), filstørrelse, endringsdato og fargetagger.
- **Automatisk fane-gjenoppretting & lagrede Arbeidsområder (`⌥⌘S`):** Husker åpne faner og enkelt-/topanelsoppsett automatisk ved omstart, og lar deg lagre navngitte arbeidsområder i sidepanelet og Command Palette (`⌘P`).
- **macOS Fargetagger (`⌃1`–`⌃7`):** 100 % kompatible fargetagger som vises direkte på filradene, i kontekstmenyen, i infopanelet (`⌘I`) og i sidepanelet.
- **Flat undermappe-visning (`⌥⌘B`):** Samler alle filer fra undermapper i én oversiktlig og sorterbar liste med tydelig visning av relativ undermappesti.
- **Diskplass-analyse (`⌥⌘D`):** Visuell oversikt over hvilke undermapper og enkeltfiler som bruker mest plass, med direkte utforsking nedover i mappetreet.
- **Mappe-synkronisering (`⌥⇧⌘K`):** Synkroniser venstre og høyre mappe (oppdater én vei, to-veis nyeste vinner, eller speilmodus) med full forhåndsvisning av planlagte filoperasjoner.
- **Duplikat-finner (`SHA-256`):** Finner 100 % identiske duplikatfiler i én eller begge mapper og lar deg beholde nyeste eller eldste kopi med ett klikk.
- **Innebygde hurtigverktøy:** Konverter og skaler bilder (`HEIC`, `PNG`, `TIFF`, `JPG` → `JPEG`/`PNG`), slå sammen valgte PDF-er og bilder til én samlet PDF, og beregn `SHA-256`-sjekksum i infopanelet.
- **Rent og enhetlig begrepsbruk:** Oppdaterte menyer (*Verktøy*), knapper og ledetekster med egne norske og engelske termer uten referanser til andre tredjepartsprogrammer.

## [1.0.6] - 2026-11-14

- Nytt valg for å sette FlowFile som standard filutforsker i macOS – tilgjengelig med ett klikk både i Innstillinger (`⌘,`) og som et frivillig steg i Velkomstguiden, inkludert enkel tilbakestilling til Finder.
- Full støtte for «Vis i Finder» fra nettlesere, Spotlight og Terminal (`open` / `open -R`): åpner foreldremappen og markerer + scroller direkte til den aktuelle filen eller `.app`-pakken.
- «Smart ny fane» ved ekstern åpning: bevarer mappen du jobber i ved å åpne i ny fane, men gjenbruker eksisterende fane automatisk hvis mappen allerede er åpen (kan byttes til «Aktiv fane» i Innstillinger).
- «Vis i Finder» inne i selve FlowFile åpner fortsatt ekte macOS Finder uten å gå i løkke tilbake til FlowFile.

## [1.0.5] - 2026-11-13

- Ny direktemotor for oppdatering og omstart: bytter ut app-pakken atomisk før avslutning og starter ny utgave direkte via macOS LaunchServices, uten eksterne hjelpeskript som kan stoppes i bakgrunnen.
- Viser tydelig tilbakemelding i oppdateringsvinduet dersom macOS ber om tillatelse til Appadministrasjon i `/Applications`.
- Oversiktlig «Hva er nytt og forbedret»-visning i oppdateringsvinduet, uten installasjonskommandoer eller sjekksummer.
- Viser også endringsloggen for installert versjon når FlowFile allerede er oppdatert.

## [1.0.4] - 2026-11-13

- Ny og oversiktlig «Hva er nytt og forbedret»-visning i oppdateringsvinduet, helt uten støy fra installasjonskommandoer eller sjekksummer.
- Viser også nyhetene i den installerte versjonen når FlowFile er ferdig oppdatert.
- Raskere og mer responsiv oppdatering: utpakking og signaturkontroll kjører i bakgrunnen uten å låse brukergrensesnittet.

## [1.0.3] - 2026-11-12

- Sikker tilbakerulling (rollback) ved masse-omdøping dersom en filoperasjon feiler underveis, samt støtte for kun endring av store/små bokstaver på APFS.
- Atomisk app-oppdatering med sikkerhetskopi og streng sjekksumkontroll (`SHA256SUMS.txt`).
- Tastatursnarveiene `⌘X`, `⌘C`, `⌘V` og `⌘A` fungerer nå som forventet i tekstfelt (adresselinje, søk og omdøping), og utklippstavlen synkroniseres sømløst med Finder.
- Sikrere arkivhåndtering med beskyttelse mot ugyldige filstier, bedre støtte for spesialtegn (`[`, `*`, `?`) og sammensatte arkivnavn som `.tar.xz`.
- Forbedret innebygd terminal (korrekt UTF-8 ved lange utskrifter) og raskere Git-status uten unødvendige prosesskall.

## [1.0.2] - 2026-11-11

- Sømløs installasjon og oppdatering via Homebrew Cask (`brew install --cask flowfile`) og GitHub Actions (`macos-26`).
- Innebygd oppdateringssjekk direkte fra menyen (*FlowFile → Se etter oppdateringer...*).
