TIMESVC.R4X
===========

TIMESVC.R4X ist der Zeit- und Zeitzonen-Konfigurationsservice.

Projektstruktur seit 0.51.19:
- `build.zig` baut den Service als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, Imports, Startdaten und Contract.

Build:

    cd Code\System\Services\TimeService
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Services\TimeService\zig-out\TIMESVC.R4X

Contract:
- R4XStart-Entry: `timesvc_main`
- App-Klasse: `service`
- R4L-Imports: `R4SYS:Query:1`, `R4STD:SETTINGS_V1:1`,
  `R4STD:DATE_V1:1`, `R4STD:TIME_V1:1`, `R4STD:CONFIG_V1:1`
- Service-Name: `TIMESVC`
- Standardargumente: `/RUN`
- Zielpfad im Image: `C:\R4OS\SERVICES\TIMESVC.R4X`
