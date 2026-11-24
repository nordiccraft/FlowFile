# Endringslogg for FlowFile

Alle viktige nyheter, forbedringer og feilrettinger i FlowFile dokumenteres her og vises direkte i oppdateringsvinduet i appen.

## [1.2.2] - 2026-11-24

- **Ny offisiell FlowFile-logo og macOS app-ikon:** Dyp marineblå macOS-ikonrute med den nye FlowFile-logoen i Dock, Finder, Spotlight, `.dmg`-installeren, *Om FlowFile*, Velkomstguiden og oppdateringsvinduet.
- **Ny ren Swift `.icns`-generator:** Bygger skarpe 16–1024 px app-ikoner direkte uten avhengighet til `iconutil`.
- **NordicCraft-merking:** Oppdatert opphavsrettsinfo (*Om FlowFile*) og `README.md` med [nordiccraft.io](https://nordiccraft.io).

## [1.2.1] - 2026-11-24

- **Fikset søk og jokertegn (`*.apk`, `*`, `?`):** Både lynfilteret (`⌘F`) og dypsøket (`⇧⌘F`) støtter nå jokertegn som `*.apk`, `rapport*.pdf`, `?.txt` og flere mønstre skilt med semikolon (`*.apk; *.dmg`), samt riktig håndtering av norske `æ/ø/å`-tegn.
- **Raskere og mer pålitelig dypsøk:** Følger nå snarveimapper (f.eks. `~/OneDrive`), hopper over `~/Library`-cacher når du søker fra hjemmemappen, mister aldri treff hvis en fil mangler metadata/tagger, og lar deg bytte mellom *Gjeldende mappe* og *Hele hjemmemappen* direkte i søkevinduet.
- **Tydelig tilgangsvarsel i søk:** Viser tydelig beskjed med snarvei til Systeminnstillinger dersom macOS blokkerer lesetilgang til mappen du søker i, i stedet for å vise «Ingen treff».

## [1.2.0] - 2026-11-21

- **Ny og robust QR- og Wi-Fi-deling:** Kjører nå videre i bakgrunnen med statusindikator og stoppknapp i bunnlinjen, har automatisk selvtest med snarvei til *Lokalt nettverk*-innstillingene, nettverksvelger når Macen har flere grensesnitt, valgfri 4-sifret PIN-kode, nedtelling med «+10 min»-forlengelse, støtte for gjenopptakelse (`HTTP Range`/`HEAD`), nedlastingslogg og veiledning ved bedrifts-/gjestenett.
- **macOS Del-meny og tydeligere skydeling:** Ny «macOS Del…»-knapp som åpner alle systemets delingsutvidelser (Mail, AirDrop, Meldinger, iCloud, Outlook, OneDrive, Dropbox, Slack, Teams). Skykontoer skiller nå tydelig mellom privat- og jobbkonto, Google Drive skriver riktig inn i *Min disk*, og opplasting lager alltid en ny, isolert privat mappe med bekreftelse før opplasting.
- **Tryggere klargjøring og personvern:** Asynkron bakgrunnsklargjøring (ingen frysing av appen), tapsfri fjerning av GPS/EXIF fra `.JPG`, rekursiv bildebehandling inne i mapper med ærlig rapport over filer som ikke kunne renses automatisk, og ekte UTF-8-flagging i `.zip`-filer slik at norske `æ/ø/å`-filnavn åpnes feilfritt på Windows.
- **Bedre stabilitet og oversettelse:** Midlertidige delingsfiler slettes ikke lenger for tidlig under AirDrop/e-post/utklippstavle-overlevering, riktig systemikon for AirDrop, størrelsesvarsel for e-post over 20 MB, og full norsk/engelsk støtte i hele delingssenteret.

## [1.1.1] - 2026-11-21

- **Tryggere mappe-synkronisering:** Stopper umiddelbart hvis venstre mappe er utilgjengelig eller tom i speilmodus, sletter aldri filer permanent uten papirkurv, kopierer via midlertidig fil før atomisk erstatning, forhåndsvelger ikke slettinger og krever bekreftelse.
- **Tryggere duplikat-finner og diskplass-analyse:** Gjenkjenner samme fysiske fil via fil-ID (hindrer at eneste kopi kan merkes som duplikat), hopper over filer som kun ligger i skyen, krever bekreftelse før flytting til Papirkurven, og beskytter hjemme- og systemmapper i diskplass-analysen.
- **Sikkerhetsforbedringer for Git, arkiver og terminal:** Herdet Git-status som blokkerer usikre `.git/config`-oppsett (f.eks. `fsmonitor`/filtre), bevarer macOS karantene-merke ved utpakking av arkiver med advarsel før kjørbare filer åpnes fra innsiden av arkiv, og beskytter den innebygde terminalen mot kontrolltegn i mappenavn.
- **Hardened Runtime og låst oppdateringskilde:** Bygges nå med Hardened Runtime for beskyttelse mot kodeinjeksjon, oppdateringskilden er låst til det offisielle FlowFile-repoet, og oppdateringsloggen er flyttet til `~/Library/Logs/FlowFile/update.log`.
- **Tryggere deling-zip og QR-stabilitet:** Pakking til `.zip` følger ikke lenger snarveier og utelater skjulte filer som `.git`/`.env` i delte mapper, pakker `.app`/`.pages`-pakker riktig før QR-deling, og unngår ugyldige nettverksadresser.

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
