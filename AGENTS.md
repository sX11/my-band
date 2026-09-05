# AGENTS.md — My Band

Diretrizes para agentes de IA (Claude, Codex, etc.) que trabalham neste projeto.

---

## Contexto do Projeto

**My Band** é um app iOS/macOS universal em SwiftUI que:
1. Conecta à Mi Band 10 via CoreBluetooth usando protocolo XiaomiSppPacketV2 com autenticação HMAC-SHA256 e AuthKey
2. Sincroniza dados de sono, frequência cardíaca e atividade para o Apple Health (HealthKit)
3. Expõe estado e ações via App Intents para integração com Atalhos e Siri
4. (Futuro) Exibe um mini app customizado na pulseira com botões acionáveis

Plataformas: iOS 17+ e macOS 14+. Distribuição: sideload pessoal.

---

## O que Ler Antes de Qualquer Modificação

1. `CLAUDE.md` — arquitetura completa, protocolo BLE, convenções de código
2. O arquivo que você vai modificar — leia inteiro antes de editar
3. Se tocar em BLE: `BLE/BandProtocol.swift` e `BLE/Services/MiBandUUID.swift`
4. Se tocar em dados: o model SwiftData correspondente em `Models/`

---

## Regras por Área

### BLE (`BLE/`)

- `BandManager` é `@Observable @MainActor NSObject` — acesso ao estado sempre na main thread; não despachar para outra fila sem `Task { @MainActor in ... }`
- O handshake de autenticação é **sequencial e stateful** — não paralelizar etapas
- Ao modificar parsing de pacotes, adicionar um fixture em `Tests/Fixtures/` com bytes reais capturados e um teste correspondente
- Nunca reconectar em loop infinito — usar backoff exponencial com máximo de 5 tentativas
- UUIDs de características GATT ficam apenas em `MiBandUUID.swift` — não hardcodar strings em outros arquivos
- Protocolo V2: `XiaomiSppPacketV2`, serviço `FE95`, TX `005E`, RX `005F`. UUIDs legados FEE0/FEE1 e `0x0009` são para Mi Band 5/6 — não usar.
- Primitivas criptográficas ficam em `BLE/Crypto/XiaomiCrypto.swift`; builders/parsers protobuf em `BLE/Protocol/XiaomiProto.swift` (camada fina sobre os tipos gerados em `xiaomi.pb.swift` via SwiftProtobuf)
- `startScan()` pode ser chamado antes do BT estar pronto — o flag `pendingScan` em `BandManager` lida com isso; não remover essa lógica
- **ACK obrigatório**: o SPP V2 é um transporte confiável com janela. **Toda frame DATA recebida precisa ser confirmada** com `sendAck(seqNum:)` usando o `seqNum` recebido. Sem isso a pulseira retransmite o handshake inteiro a cada ~6 s. Não remover.
- **Init pós-auth**: após `Authentication successful`, enviar `sendPostAuthInit()` (setCurrentTime + device info/state/battery). Sem isso a pulseira considera a sessão incompleta e re-dispara auth.
- **Um HMAC divergente não é sinônimo de AuthKey errada** (ver ADR 0003). Quatro causas, só uma é chave errada: a pulseira ainda espera o aceite do usuário (`sub=16` → `.awaitingPairingConfirmation`), o nonce chegou depois do nosso `CMD_AUTH` (`authStep3Sent` — quem decide é o `sub=27`), corrida de nonce (até `maxNonceMismatches` toleradas), ou a chave está errada mesmo. Só o último caso escala para `retryAuthAfterReconnect()` (limite `maxAuthRetries`, teardown com atraso crescente). Não voltar a derrubar o link na primeira divergência: no pareamento isso dispensa o próprio prompt que estamos esperando.
- **Session config recebido em `.connected` = a pulseira abriu uma sessão nova.** Refazer o handshake e rederivar as chaves (`maxBandSessionRestarts`), como o GadgetBridge faz a todo pacote de session config. Ignorar deixa o app cifrando com chaves mortas — a pulseira ACKa o transporte e descarta o comando em silêncio, e o sync fica pendurado até o timeout com o link parecendo saudável. A guarda de duplicata vale **apenas** para `.authenticating` (bug do 005F).
- **Watchdog de auth**: `armAuthWatchdog()` (20 s; 120 s durante o pareamento) re-armado por todo pacote de auth que progride. `AuthError.timeout` é timeout de verdade; queda de link é `AuthError.linkDropped`. Não confundir os dois de novo.
- Testes de BLE requerem iPhone físico — o Simulator e o Mac não conectam com a Mi Band. **Autenticação confirmada em hardware real (Mi Band 10) em 2026-06-19.**

### Auth / Keychain (`Auth/`)

- AuthKey **nunca** em SwiftData, UserDefaults, logs ou prints
- Credenciais Xiaomi Cloud (email, senha) **nunca** persistidas — usar apenas em memória durante o fluxo de extração
- Ao escrever no Keychain: usar `kSecAttrAccessibleAfterFirstUnlock` para acessibilidade em background
- **A AuthKey é o único estado que o app não reconstrói sozinho** (ver ADR 0004). O `service` do item é uma constante fixa, não o bundle id — mudá-la sem migração perde a chave. `save` atualiza no lugar (nunca `delete`+`add`). `isStored` distingue `.notFound` de `.locked`: um Keychain bloqueado (relaunch em background antes do primeiro desbloqueio pós-boot) **não** é "sem chave" — responder `false` ali manda um usuário pareado de volta ao setup.

### HealthKit (`Health/`)

- Sempre verificar autorização antes de escrever — `HKHealthStore.authorizationStatus(for:)`
- Implementar deduplicação: consultar amostras existentes no mesmo período antes de inserir
- Usar `HKQueryAnchor` persistido em SwiftData para sincronizações incrementais (não re-sincronizar tudo a cada vez)
- Fases de sono: mapear para `HKCategoryValueSleepAnalysis` (.inBed, .asleepCore, .asleepDeep, .asleepREM, .awake)
- **Nunca** incluir `HKCategoryType(.appleStandHour)` em `requestAuthorization(toShare:)` — é reservado e lança `NSInvalidArgumentException` (apps de terceiros não podem gravá-lo)
- Treinos: usar `HKWorkoutBuilder` (não o init depreciado de `HKWorkout`); rota GPS via `HKWorkoutRouteBuilder.insertRouteData` + `finishRoute(with:)`

### App Intents (`Intents/`)

- Cada Intent deve ter `title` e `description` claros para aparecer bem no app Atalhos
- `perform()` deve retornar resultado útil — não retornar vazio quando há dado disponível
- Parâmetros de data devem ter valores default razoáveis (ex: "hoje" para `GetSleepDataIntent`)
- Registrar frases Siri em `BandShortcuts.swift` via `AppShortcutsProvider`
- Um intent feito para rodar dentro de uma Automação Pessoal (que dispara sozinha, com frequência) deve ser **silencioso no caso comum** — sem diálogo quando não há nada a dizer, como o `CheckBandBatteryIntent`, que só notifica abaixo do limite. Diálogo a cada execução vira ruído e a pessoa desliga a automação.
- Intent que depende do link BLE não deve falhar quando a pulseira está fora de alcance: sincronizar é best-effort e a resposta cai no último dado conhecido — uma exceção derruba a automação inteira

### UI (`UI/`)

- **Design system**: a UI segue o handoff do Claude Design (`My Band — Design System`). Antes de criar telas, ler o README do bundle e os tokens (`tokens/colors.css`, `typography.css`, `spacing.css`) e os componentes em `components/`. Recriar fielmente em SwiftUI — não copiar a estrutura HTML, e sim o resultado visual.
- **Dark-mode first**, paleta midnight (`#0A0B10` base, cards `#14161F`), um único accent Aurora indigo `#7C7FFF`. Cores de saúde espelham o Apple Health; rampa de fases de sono dusk→deep-night.
- Copy em **pt-BR**, sentence case, sem emoji; números são heróis (tabular). Status sempre por cor + SF Symbol (nunca cor sozinha).
- SwiftUI puro — sem UIKit direto exceto onde absolutamente necessário (ex: `UIApplication` para background tasks)
- Suporte a macOS via `#if os(macOS)` / `#if os(iOS)` quando comportamentos divergem
- Não criar telas separadas para Mac e iPhone — usar `NavigationSplitView` para adaptar layout
- Dados de sono são a funcionalidade prioritária — dashboard deve exibi-los em destaque
- Status de conexão e frescor do sync são first-class — presentes em toda tela, nunca enterrados

### Models (`Models/`)

- SwiftData models são a fonte de verdade para dados históricos
- `BandDevice` guarda apenas identificadores — AuthKey fica no Keychain
- Ao adicionar campo a um model, sempre definir valor default para migração automática

---

## O que Não Fazer

- **Não usar Combine** — projeto usa async/await e @Observable exclusivamente
- **Não usar UserDefaults para dados sensíveis** — apenas Keychain
- **Não adicionar dependências externas (SPM)** sem discutir. Dependências aprovadas até agora: **SwiftProtobuf** (`apple/swift-protobuf`, usado para os tipos gerados em `xiaomi.pb.swift`). Qualquer nova precisa de justificativa e aprovação.
- **Não criar arquivos de documentação ad-hoc** (NOTES, TODO solto) — usar comentários inline só quando WHY não é óbvio
- **Sempre atualizar `CHANGELOG.md`** ao adicionar, alterar ou corrigir qualquer coisa notável. Entradas vão em `## [Unreleased]` nas categorias `Added / Changed / Deprecated / Removed / Fixed / Security` conforme [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Não registrar refatorações internas triviais, apenas mudanças que um futuro leitor do histórico precisaria saber.
- **Não mockar CBCentralManager em testes** — testar apenas camadas de parsing independentes de BLE
- **Não escrever dados no HealthKit sem autorização explícita do usuário** — verificar `authorizationStatus` sempre
- **Não criar `Info.plist` dentro de `My Band/My Band/`** — o projeto usa `PBXFileSystemSynchronizedRootGroup` (Xcode 16), que inclui automaticamente todos os arquivos da pasta no build. Um Info.plist ali dentro causa "Multiple commands produce Info.plist". O `Info.plist` fica em `$(SRCROOT)/Info.plist` (raiz do projeto), com `GENERATE_INFOPLIST_FILE = NO` e `INFOPLIST_FILE = "Info.plist"` no pbxproj.

---

## Compilar e Testar

```bash
# Build no simulador
xcodebuild -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 15 Pro" build

# Testes de unidade (parsers, conversões, lógica HA)
xcodebuild test -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 15 Pro"
```

- Testes de protocolo BLE: usar dados de fixture (bytes capturados de sessão real), nunca dispositivo ao vivo
- Testes de HealthKit: usar `HKHealthStore` com mock via protocolo — nunca escrever no Health real em CI

---

## Fase Futura: Mini App na Pulseira

A Mi Band 10 suporta mini apps via protocolo proprietário ainda em processo de engenharia reversa. Quando chegar a hora:
- Criar módulo `MiniApp/` separado
- O mini app roda na pulseira e envia eventos de botão via BLE para o `BandManager`
- Esses eventos devem disparar `AppIntent` correspondentes
- Não implementar nada em `MiniApp/` até que haja documentação de protocolo confirmada

---

## Fluxo de Desenvolvimento Recomendado

- [x] **Camada BLE V2** — `MiBandUUID` (FE95/005E/005F), `BandProtocol` (XiaomiSppPacketV2 + CRC-16/ARC), `BandAuthenticator` (HMAC-SHA256), `BandScanner`, `BandManager`, `AuthKeyStore` — compilando em 2026-06-07
- [x] **Crypto + Proto** — `XiaomiCrypto` (HMAC-SHA256, HKDF, AES-CTR/CCM via CommonCrypto) e `XiaomiProto` (migrado para SwiftProtobuf + `xiaomi.pb.swift` gerado do GadgetBridge)
- [x] **Persistência base** — `BandDevice`, `SleepSession`, `ActivityDay` SwiftData; `BandSyncer`; `SleepPacketParser` (2-byte entries V2)
- [x] **Info.plist manual** — corrige crash `NSInternalInconsistencyException` do CBCentralManager (UIBackgroundModes como `<array>`)
- [x] **Teste em hardware real (2026-06-19)** — auth completa na Mi Band 10: handshake HMAC-SHA256, retry de primeiro pareamento, ACK de transporte, init pós-auth, comunicação cifrada estável. AuthKey validado.
- [x] **UI: design system + Setup (2026-06-19)** — tokens e componentes (`MBButton`/`MBIconButton`/`MBTextField`/`MBStatusPill`), `SetupView` (intro + AuthKey) e `ConnectingView` ligados ao `BandManager` real; `RootView` roteando os estados
- [x] **HealthKit + Dashboard (2026-06-19)** — `HealthKitManager` (sono/passos/calorias/distância/HR/SpO₂ com dedup), parsers `DailySummary`/`DailyDetails`, `BandSyncer.syncToHealth()`, bateria no `BandManager` e `DashboardView` (bateria + última sync + botão). **Pendente validação em hardware** (formato dos arquivos de atividade, passos cumulativo vs delta).
- [x] **Parsers de medição manual + treinos (2026-06-19)** — `ManualSamplesParser` (FC/SpO₂/estresse/temperatura), `WorkoutSummaryParser` (+ builder posicional, todas as modalidades) e `WorkoutGpsParser`; `HealthKitManager` grava `HKWorkout`/rota GPS/VO₂máx/temperatura/FC de repouso. Corrigido crash de autorização do `appleStandHour`. **Pendente validação em hardware.**
- [ ] **UI: SleepDetail + Settings** → próximas telas do handoff do Claude Design
- [ ] **Parsers de device info / bateria** → `Proto command type=2` ainda só logados; parsear para alimentar o Dashboard
- [x] **HealthKit** → `HealthKitManager` + reconciliação por minuto + deduplicação
- [x] **App Intents** → `SyncBandIntent` + `GetSleepStateIntent` + `CheckBandBatteryIntent` + `BandShortcuts`
- [x] **AuthKey via Xiaomi Cloud** → `XiaomiCloudAuth` por usuário/senha (fluxo alternativo ao manual)
- [ ] **Mini App** → (fase futura, aguardar definição de protocolo)
