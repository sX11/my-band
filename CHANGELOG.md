# Changelog

Todas as mudanças notáveis neste projeto serão documentadas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
e o projeto adere ao [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed

- `Info.plist` manual criado em `$(SRCROOT)/Info.plist` (fora da pasta sincronizada). `GENERATE_INFOPLIST_FILE = NO` no pbxproj. Corrige crash em device físico: `INFOPLIST_KEY_UIBackgroundModes` gerava `<string>` no plist gerado, mas `CBCentralManager` exige `UIBackgroundModes` como `<array>` — o runtime rejeitava o state restoration com `NSInternalInconsistencyException`.
- `BandManager.init` — `CBCentralManagerOptionRestoreIdentifierKey` agora condicionado a `#if !targetEnvironment(simulator)` (simulator não suporta state restoration do CoreBluetooth).
- `My_BandApp` — `sharedModelContainer` alterado de `var` para `static let`. App structs do SwiftUI podem ser recriadas durante setup de cena; um `var` recriava o `ModelContainer` (e o store SQLite) a cada vez, causando double-init visível no console como pares de mensagens CoreData.
- `BandManager.startScan()` — race condition com a inicialização do `CBCentralManager`. Chamar `startScan()` de `.onAppear` antes de `centralManagerDidUpdateState(.poweredOn)` fazia o guard falhar silenciosamente e deixava o scan nunca iniciar. Adicionado flag `pendingScan`; `centralManagerDidUpdateState` consome o flag e dispara o scan quando o BT ficar pronto.
- `My_BandApp.sharedModelContainer` — recuperação automática de store corrompido. Watchdog kills durante gravação deixam o arquivo SQLite em estado inválido. Se `ModelContainer` falhar na primeira tentativa, o store corrompido é deletado e recriado antes de chamar `fatalError`.

### Changed

#### Protocolo BLE — Correção completa para Mi Band 10 V2

- `MiBandUUID` — UUIDs substituídos pelos corretos do protocolo V2 (GadgetBridge): service `0000FE95`, TX `0000005E`, RX `0000005F`. UUIDs legados FEE0/FEE1 removidos.
- `BandProtocol` — Reescrito com formato `XiaomiSppPacketV2`: preamble `[0xA5, 0xA5]`, header 8 bytes (type, channel, seqNum, payloadLen LE, flags, CRC-16/ARC), canais COMMAND(1)/DATA(2)/ACTIVITY(5). Comandos de fetch e session config agora corretos.
- `BandAuthenticator` — Substituído AES-128-ECB pelo protocolo HMAC-SHA256 V2 confirmado (GadgetBridge `XiaomiAuthService`): `CMD_NONCE` (type=1, sub=26) com nonce aleatório de 16 bytes → banda retorna `watchNonce+HMAC` → `HKDF-expand("miwear-auth", 64)` deriva 4 chaves de sessão → `CMD_AUTH` (type=1, sub=27) com confirmação cifrada em AES-CTR.
- `BandScanner` — Nome de dispositivo atualizado para `"Xiaomi Smart Band 10"` (padrão confirmado no GadgetBridge `MiBand10Coordinator`).
- `BandManager` — Fluxo de autenticação refatorado para V2: session config → troca de nonce → derivação de chaves → confirmação. Gerenciamento de `seqNum` por canal. Novo estado `sessionConfig` na máquina de estados.
- `SleepPacketParser` — Entradas reescritas para formato 2 bytes UInt16 BE (bits 15–12 = stage, bits 11–0 = offset_minutes). Adicionado suporte ao header de detalhes (Type 16) com bedtime/waketime/durações por fase.
- `BandSyncer` — Comando de fetch substituído por `XiaomiSyncCmd` (type=8, sub=2) via `XiaomiProto.command`. `ChunkedReceiver` substituído por `DataChannelReceiver` compatível com payloads V2.

### Added

- `BLE/Crypto/XiaomiCrypto.swift` — Primitivas criptográficas: HMAC-SHA256 (CommonCrypto), HKDF-expand (RFC 5869 §2.3), AES-CTR manual via blocos AES-ECB (IV=key, peculiaridade V2), derivação de `SessionKeys`.
- `BLE/Protocol/XiaomiProto.swift` — Encoder/decoder protobuf mínimo in-house (zero dependências SPM): varint, tags, fields uint32/bytes, builder de `Command{type, subtype, payload}`, leitor de campo bytes para parsing de respostas da banda.

---

## [0.1.0] - 2026-06-07

### Added

#### Camada BLE (`BLE/`)
- `BandManager` — orquestrador central `@Observable @MainActor NSObject` com máquina de estados completa: `disconnected → scanning → connecting → discoveringServices → authenticating → connected`
- `BandAuthenticator` — handshake AES-128-ECB via CommonCrypto: request random → decrypt challenge → re-encrypt → confirm
- `BandScanner` — filtros de descoberta BLE por nome (`Mi Band 10`, `Xiaomi Band 10`) e UUID de serviço
- `BandProtocol` — encoding de pacotes de autenticação, chunked transfer e fetch
- `BandSyncer` — orquestrador de sincronização: reassembla frames chunked, parseia payload binário, persiste no SwiftData com deduplicação por hash; timeout de 30s via `withThrowingTaskGroup`
- `BLE/Services/MiBandUUID` — constantes de UUID dos serviços e características GATT da Mi Band 10
- `BLE/PacketParser/SleepPacketParser` — parser de payload binário de sono em `[SleepSession]`, com detecção de sessões por gap ≥ 30 min e mapeamento de stages (light/deep/REM/awake)
- Reconexão automática com backoff exponencial (máximo 5 tentativas, delay 2^n segundos)
- State restoration do `CBCentralManager` para reconectar após suspensão pelo sistema
- Background BLE habilitado via `UIBackgroundModes = bluetooth-central`

#### Auth (`Auth/`)
- `AuthKeyStore` — Keychain read/write/delete para o AuthKey de 16 bytes com `kSecAttrAccessibleAfterFirstUnlock`; parser de string hex de 32 caracteres; extensão `Data(hexString:)` e `Data.hexString`

#### Modelos SwiftData (`Models/`)
- `BandDevice` — dispositivo pareado: nome, `peripheralIdentifier`, data de adição, última sincronização; relacionamentos com `SleepSession` e `ActivityDay`
- `SleepSession` — sessão de sono: start/end, array de `SleepPhase` (Codable), flag `healthKitSynced`, `rawDataHash` para deduplicação; computed properties: `efficiency`, `deepDuration`, `remDuration`, `lightDuration`
- `ActivityDay` — atividade diária: passos, calorias, distância, minutos ativos, flag `healthKitSynced`
- `SleepPhase` — struct Codable com `startDate`, `endDate`, `SleepPhaseType` (awake/light/deep/rem)

#### Infraestrutura
- `My_BandApp` — schema SwiftData com os 3 modelos; `BandManager` e `BandSyncer` injetados no environment via `@State`
- Permissões declaradas via `INFOPLIST_KEY_*` no `project.pbxproj`: `NSBluetoothAlwaysUsageDescription`, `NSHealthUpdateUsageDescription`, `NSHealthShareUsageDescription`, `UIBackgroundModes`
- Documentação: `CLAUDE.md` (arquitetura, protocolo BLE, armadilhas), `AGENTS.md` (diretrizes para agentes IA), `README.md`, `CHANGELOG.md`

[Unreleased]: https://github.com/matheusdanoite/my-band/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/matheusdanoite/my-band/releases/tag/v0.1.0
