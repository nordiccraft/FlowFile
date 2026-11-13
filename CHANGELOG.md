# Endringslogg for FlowFile

Alle viktige nyheter, forbedringer og feilrettinger i FlowFile dokumenteres her og vises direkte i oppdateringsvinduet i appen.

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
