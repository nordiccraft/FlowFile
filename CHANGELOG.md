# Endringslogg for FlowFile

Alle viktige nyheter, forbedringer og feilrettinger i FlowFile dokumenteres her og vises direkte i oppdateringsvinduet i appen.

## [1.0.4] - 2026-11-13

- Ny og oversiktlig «Hva er nytt og forbedret»-visning i oppdateringsvinduet, helt uten støy fra installasjonskommandoer eller sjekksummer.
- Viser også nyhetene i den installerte versjonen når FlowFile er ferdig oppdatert.
- Fikset feil der oppdateringsvinduet ble stående på «Installerer...» fordi et åpent modalt ark hindret macOS i å avslutte det gamle vinduet ved omstart.
- Raskere og mer responsiv oppdatering: utpakking og signaturkontroll kjører nå i bakgrunnen uten å låse brukergrensesnittet.
- Inkluderer alle sikkerhets- og kvalitetsforbedringer fra 1.0.3: sikker tilbakerulling ved masse-omdøping, korrekt `⌘X`/`⌘C`/`⌘V`/`⌘A` i tekstfelt, forbedret Finder-utklippstavle, tryggere arkivhåndtering og raskere Git-status.

## [1.0.3] - 2026-11-12

- Sikker tilbakerulling (rollback) ved masse-omdøping dersom en filoperasjon feiler underveis, samt støtte for kun endring av store/små bokstaver på APFS.
- Atomisk app-oppdatering med sikkerhetskopi og streng sjekksumkontroll (`SHA256SUMS.txt`).
- Tastatursnarveiene `⌘X`, `⌘C`, `⌘V` og `⌘A` fungerer nå som forventet i tekstfelt (adresselinje, søk og omdøping), og utklippstavlen synkroniseres sømløst med Finder.
- Sikrere arkivhåndtering med beskyttelse mot ugyldige filstier, bedre støtte for spesialtegn (`[`, `*`, `?`) og sammensatte arkivnavn som `.tar.xz`.
- Forbedret innebygd terminal (korrekt UTF-8 ved lange utskrifter) og raskere Git-status uten unødvendige prosesskall.

## [1.0.2] - 2026-11-11

- Sømløs installasjon og oppdatering via Homebrew Cask (`brew install --cask flowfile`) og GitHub Actions (`macos-26`).
- Innebygd oppdateringssjekk direkte fra menyen (*FlowFile → Se etter oppdateringer...*).
