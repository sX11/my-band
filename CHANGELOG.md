# Changelog

Todas as mudanças notáveis neste projeto serão documentadas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
e o projeto adere ao [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **Instalação de watch faces e apps customizados** (`BLE/Upload/`, `UI/Customize/CustomizeView.swift`): porta o gerenciamento de watch faces (GadgetBridge `XiaomiWatchfaceService`, type=4) e quick apps RPK (`XiaomiRpkService`, type=20) para a Mi Band 10, sobre o canal de upload em chunks (`XiaomiDataUploadService`, type=22). As mensagens proto já existiam no `xiaomi.pb.swift` — sem regeneração.
  - **`DataUploadService`** — engine compartilhada: pede o upload (`CMD_UPLOAD_START` com `md5`+`size`), recebe `dataUploadAck` (resumePosition + chunkSize), monta o envelope `[0][type][md5:16][size:u32LE][bytes]`+`crc32` e o envia em chunks `[totalParts][parte][dados]` no canal **DATA (texto claro)**. Pacing contra o buffer de `writeWithoutResponse` do CoreBluetooth via `peripheralIsReady`.
  - **`WatchfaceService`** — list/set/delete/install. Install anuncia (`watchfaceInstallStart{id,size}`), aguarda `installStatus`, faz upload `TYPE_WATCHFACE` e ativa. Arquivo: binário, magic `0x5A 0xA5`, id numérico em `0x28`.
  - **`AppInstallService`** — list/install/delete de RPK. Arquivo: ZIP com `manifest.json` (`package`/`name`/`versionCode`), lido por um extrator de ZIP mínimo (`MiniZip`) com inflate via framework `Compression`.
  - **`CustomizationManager` + `CustomizeView`** — tela (sheet a partir do Dashboard) que lista faces/apps, ativa, apaga e instala. Três formas de importar: document picker (Files), download por URL e share sheet (`onOpenURL` + `CFBundleDocumentTypes` no Info.plist). Barra de progresso durante o upload.
  - **Fora de escopo proposital:** flashing de firmware (`TYPE_FIRMWARE=32`) — risco de brick.
- **Suporte ao preset Treino de Força** (`BLE/PacketParser/WorkoutSummaryParser.swift`, `Health/HealthKitManager.swift`): adicionado `WorkoutKind.strengthTraining`. Confirmado em hardware: a pulseira envia subtype `0x08` (layout Freestyle), version `10`, com campo `workoutType=308`. O código `308` agora mapeia para `.strengthTraining`, que exporta como `HKWorkoutActivityType.traditionalStrengthTraining` (indoor) no Apple Health — em vez de `.other`. Para musculação em academia, usar o preset **Treino de Força** na pulseira.

### Changed

- **Previsão do tempo na pulseira via Open-Meteo** (`BLE/WeatherSyncService.swift`) — busca tempo atual + previsão de 6 dias do [Open-Meteo](https://open-meteo.com/) (grátis, sem chave) para Guarapuava (−25.39, −51.46) e faz push app→band (cifrado) ao final de `syncToHealth()`, espelhando o `XiaomiWeatherService` do GadgetBridge: `CMD_ADD_LOCATION` → `CMD_SET_CURRENT_WEATHER` (condição, temperatura, umidade, vento em Beaufort, UV, pressão) → `CMD_UPDATE_DAILY_FORECAST` (faixa de condição/temperatura + nascer/pôr do sol por dia). Código de condição mapeado de WMO (Open-Meteo) → Xiaomi; timestamps ISO-8601 com offset; chave de localização no formato `accu:<hash>` (réplica do `String.hashCode` do Java). IDs `XiaomiWeatherCmd` (type=10) e builders em `XiaomiProto`. Best-effort: sem rede/falha apenas pula.
- **Sincronização de idioma, calendário e lembretes para a pulseira** (`BLE/CalendarSyncService.swift`) — push app→band (cifrado) executado ao final de `syncToHealth()`, junto com os dados de saúde e exercícios e enquanto o link está ativo (best-effort: falha aqui não derruba o sync de saúde):
  - **Idioma**: `System`/`CMD_LANGUAGE` (type=2, sub=6) com `system.language.code` derivado do locale (`"pt_br"`).
  - **Calendário**: `CMD_CALENDAR_SET` (type=12, sub=1) com `calendar.calendarSync.event` — eventos dos próximos 30 dias via EventKit (≤50), com título/notas/local/início/fim/dia inteiro e o primeiro alarme relativo → `notifyMinutesBefore`. Semântica de substituição (idempotente); `disabled=true` quando não há eventos.
  - **Lembretes**: `Schedule`/`CMD_REMINDERS_CREATE`/`DELETE` (type=17) — lembretes do EventKit com data (≤20). Como o id é atribuído **pela banda** (devolvido em `schedule.ackId`), o serviço captura os acks (novo callback `BandManager.onScheduleAck`), persiste-os e os deleta no próximo sync antes de recriar — espelha o iPhone sem acumular.
  - Builders em `XiaomiProto` (`languageCommand`, `calendarSyncCommand`, `reminderCreate/DeleteCommand`, `reminderDetails`) e IDs de comando `XiaomiCalendarCmd`/`XiaomiScheduleCmd` + `XiaomiSystemCmd.language`. Permissões EventKit (full-access iOS 17) no `Info.plist`.
- **Escrita SPP fragmentada por MTU** (`BandManager.writeSPP`) — frames maiores que o ATT MTU (ex.: calendário com muitos eventos) agora são escritos em chunks de tamanho de MTU; a banda reassembla pelo comprimento da frame (igual ao GadgetBridge). Pacotes pequenos (auth/init) continuam em um único write.
- **App Intent de sincronização** (`Intents/SyncBandIntent.swift`, `Intents/BandShortcuts.swift`) — "Sincronizar pulseira" exposto ao Atalhos e à Siri. `SyncBandIntent` roda em segundo plano (`openAppWhenRun = false`) e chama `BackgroundSyncManager.syncNow()`, novo entry point **foreground-aware**: sincroniza pelo link já aberto se o app estiver conectado, senão conecta/sincroniza/desconecta como o caminho em background. Retorna um `ProvidesDialog` em pt-BR resumindo o que foi gravado (sessões de sono, treinos, resumos diários, medições). `BandShortcuts` registra frases Siri com `\(.applicationName)`.
- **Encontrar telefone** (`BLE/FindPhoneService.swift`) — implementa a função "find phone" da Mi Band 10. A pulseira envia `System` (type=2, subtype=17 `CMD_FIND_PHONE`); `BandManager` decodifica `system.findDevice` (0 = iniciar, ≠0 = parar, conforme GadgetBridge) e chama o callback `onFindPhone`. O serviço dispara um alarme audível mesmo com o botão de silencioso ativo e com o app em segundo plano: `AVAudioSession` em categoria `.playback` tocando em loop uma sirene de dois tons sintetizada em memória (sem asset), vibração pulsada por timer e notificação local com som crítico. Auto-encerra em 45 s caso a pulseira saia de alcance sem enviar o STOP. `XiaomiSystemCmd.findPhone` (17) e background mode `audio` no `Info.plist`.
- **Sync automático ao fim do treino** — `WorkoutGpsService` expõe `onWorkoutFinished`, disparado quando a pulseira reporta `workoutStatusWatch` status=finished. `BandSyncer` engancha esse evento e, após ~8 s de espera (a pulseira precisa fazer flush do arquivo de atividade), roda um `syncToHealth()` se ainda conectado — puxando o treino recém-gravado para o Apple Health sem ação do usuário. A espera + sync são envoltos em um `beginBackgroundTask` (≈30 s) para sobreviver quando o evento chega via callback BLE em segundo plano.

- **Sincronização em segundo plano** (`BLE/BackgroundSyncManager.swift`, `AppDelegate.swift`) — `BGProcessingTask` (`com.myband.sync`) que, com o app suspenso, reconecta à pulseira conhecida (sem scan — `retrievePeripherals` + auto-connect via background mode `bluetooth-central`), roda um `syncToHealth()` completo e reagenda a próxima execução (intervalo mínimo ~30 min). O handler é registrado no `application(_:didFinishLaunchingWithOptions:)` (único momento permitido pelo `BGTaskScheduler.register`) via `@UIApplicationDelegateAdaptor`; as dependências são injetadas no `.onAppear` e o handler aguarda-as em launch a frio disparado pela própria task. Um pedido de sync é agendado sempre que o app vai para segundo plano (`scenePhase`). `Info.plist`: `BGTaskSchedulerPermittedIdentifiers` + background mode `processing`.
- **`BandManager.ensureConnected(identifier:timeout:)`** — conecta a um periférico conhecido e aguarda (com timeout) o link autenticado, resolvendo na conclusão da auth e falhando em erro/desconexão. Usado pela task de sync em segundo plano para dirigir a conexão até o fim antes de buscar dados.
- **`WorkoutGpsService`** — implementa o handshake GPS do protocolo Xiaomi (GadgetBridge `XiaomiHealthService`): intercepta `workoutOpenWatch` (type=8, subtype=30) emitido pela pulseira ao iniciar um treino ao ar livre, inicia CoreLocation, responde com `workoutOpenReply{0,2,2}` ao obter o primeiro fix (ou `{3,2,10}` se GPS indisponível, o que deixa a pulseira iniciar sem GPS) e, após a pulseira confirmar início via `workoutStatusWatch`, transmite `workoutLocation` (subtype=48) a cada posição. Sem essa resposta a pulseira ficava travada em "aguardando GPS" indefinidamente.
- **Subtypes de workout** em `XiaomiHealthCmd` (`workoutStatus=26`, `workoutOpen=30`, `workoutLocation=48`) e builders `workoutOpenReplyCommand` / `workoutLocationCommand` em `XiaomiProto`.
- **Permissões de localização "Sempre"** em `Info.plist` (`NSLocationWhenInUseUsageDescription` + `NSLocationAlwaysAndWhenInUseUsageDescription` + `NSLocationAlwaysUsageDescription`) e background mode `location`. O `WorkoutGpsService` faz o prompt em duas etapas (iOS força `WhenInUse` primeiro, depois libera o upgrade para `Always`), liga `allowsBackgroundLocationUpdates` e desliga `pausesLocationUpdatesAutomatically` — sem isso a pulseira perde o sinal de GPS assim que a tela do iPhone bloqueia durante o treino.

### Changed

- **Fim de treino busca os arquivos nomeados pela pulseira em vez de relistar o backlog** (`BLE/BandManager.swift`, `BLE/WorkoutGpsService.swift`, `BLE/BandSyncer.swift`): o `workoutStatusWatch` (status=finished) carrega os `activityFileIds` do treino recém-gravado, que antes eram descartados — o app só lia o `status` e disparava um `syncToHealth()` completo (FETCH_TODAY + FETCH_PAST). Agora `BandManager` repassa os ids no callback `onWorkoutStatusWatch(status, fileIds)`; `WorkoutGpsService.onWorkoutFinished(fileIds)` os entrega ao `BandSyncer`, que chama o novo `syncWorkoutFiles(_:)` — busca, parseia, grava no Apple Health e ACKa **exatamente** os arquivos do treino (resumo + rota GPS), pulando a listagem. Firmware que omita os ids cai no `syncToHealth()` completo. O loop de processamento de arquivos foi extraído para `processActivityFiles(_:manager:context:)`, compartilhado pelos dois caminhos. Totais diários (que um treino também atualiza) ficam para o próximo sync regular/em segundo plano.

### Fixed

- **Rota de GPS esparsa durante o treino** (`BLE/WorkoutGpsService.swift`): o `distanceFilter` do CoreLocation estava em 5 m, então um novo ponto só era entregue (e transmitido à pulseira) a cada 5 m percorridos — cadência atrelada ao ritmo (~1,5 s correndo, ~3,6 s caminhando) e **nenhum ponto** parado ou muito lento. Trocado para `kCLDistanceFilterNone`, entregando todos os fixes que o CoreLocation calcula (~1 Hz, uniforme no tempo) para uma rota mais suave.
- **Rota de GPS do treino não era exportada (e podia abortar o sync)** (`Health/HealthKitManager.swift`): `writeWorkouts` montava cada `CLLocation` da rota com `horizontalAccuracy: hdop ?? -1`. O CoreLocation trata acurácia negativa como amostra **inválida**, e o `HKWorkoutRouteBuilder.insertRouteData` rejeita o lote inteiro se houver qualquer inválida — então tracks V1 (sem hdop) faziam a escrita lançar, propagando para fora de `syncToHealth()` **depois** do treino já gravado e antes do ACK. Além disso, o hdop (adimensional) era usado diretamente como metros. Agora o hdop é convertido em uma estimativa de metros (×5 m UERE; valor fixo conservador quando ausente/zero), os fixes são ordenados e deduplicados para timestamps estritamente crescentes (exigência do builder), e a anexação da rota é isolada em `do/catch` — uma falha de rota apenas é logada, sem derrubar o lote nem o ACK. A rota também passou a carregar `speed`/`course` quando disponíveis.
- **Rota podia não casar com o treino por diferença de timestamp** (`Health/HealthKitManager.swift`): o arquivo de resumo e o de GPS recebem o mesmo timestamp de início, mas os dois file-ids podem divergir 1–2 s; o casamento por chave exata descartava a rota nesse caso. Agora, sem correspondência exata, escolhe-se o track mais próximo dentro de 120 s.
- **GPS continuava sendo transmitido com o treino pausado** (`BLE/WorkoutGpsService.swift`): `workoutStatusWatch` status=2 (pausado) não era tratado, então o app seguia enviando `workoutLocation` durante a pausa, podendo inflar distância/rota na pulseira. Agora a pausa interrompe o envio de posições (mantendo o CoreLocation ativo para retomada instantânea) e a retomada (status=1) volta a transmitir. Corrigido também o comentário de cabeçalho que listava os códigos de status errados (o correto, confirmado no proto, é `0=started, 1=resumed, 2=paused, 3=finished`).
- **Previsão do tempo não aparecia na pulseira** (`BLE/WeatherSyncService.swift`, `BandManager.swift`): a Mi Band 10 puxa o tempo por request/response — envia `CMD_REQUEST_CONDITIONS_FOR_LOCATION` (type=10, subtype=3) ao conectar e ao abrir a tela de tempo —, mas o app só fazia push proativo no fim do `syncToHealth()` e **descartava** o request da banda (caía no `default` do `handleProtoCommand`). A tela de tempo da pulseira fica aguardando a resposta a esse request, então o push avulso não a populava. Agora `BandManager` roteia type=10 (`handleWeatherCommand`): subtype=3 dispara o novo callback `onWeatherConditionsRequest`, e `WeatherSyncService` responde com um push de tempo. A resposta ecoa a chave/nome de localização que a banda pediu (`requestedKey`/`requestedName`) para que ela vincule os dados à localização correta; status≠0 nas respostas da banda aos nossos pushes agora é logado. Confirmado contra o `XiaomiWeatherService` do GadgetBridge (`onConditionRequestReceived`).
- **Previsão diária cobria um dia a menos** (`BLE/WeatherSyncService.swift`): enviávamos 6 entradas (hoje..+5); o GadgetBridge cobre hoje + 6 dias = 7 entradas (hoje..+6). `forecast_days` do Open-Meteo passou para 7 e o loop envia até 7 entradas.
- **Dado de sono perdido por ACK prematuro** (`BLE/BandSyncer.swift`): o `CMD_ACTIVITY_FETCH_ACK` era enviado dentro do loop por arquivo, **antes** da escrita em lote no HealthKit (sono/manual/treino são acumulados e gravados após o loop). Se a escrita falhasse ou o app fosse morto entre o ACK e a gravação, a banda marcava o arquivo como sincronizado e não o re-oferecia — perda permanente. Agora o ACK de cada categoria é enviado só após a escrita correspondente ser confirmada (resumo/detalhe diário ACKados inline; sono/manual/treino após o `write...` em lote). O ACK de transporte SPP (type=1, por frame) é independente e não foi afetado.
- **Idioma enviado à pulseira saía como `en_br`** (`BLE/CalendarSyncService.swift`): `Locale.current.language.languageCode` reflete o locale **resolvido** do app, que cai para inglês quando o bundle não tem localização em português, mesmo com o aparelho em pt-BR. Trocado para `Locale.preferredLanguages.first`, que devolve a escolha real do usuário (`pt_br`).
- **Crash na autorização do HealthKit** (`NSInvalidArgumentException: Authorization to share the following types is disallowed: HKCategoryTypeIdentifierAppleStandHour`): `.appleStandHour` é um tipo reservado, calculado pelo sistema (Apple Watch), e não pode constar em `requestAuthorization(toShare:)` de apps de terceiros. Removido do conjunto de tipos e da escrita em `writeDailySummary`. A máscara de horas em pé da pulseira permanece apenas local (não há tipo "stand hour" gravável por terceiros no HealthKit).

### Added

- **Parsers de medições manuais e treinos** (`BLE/PacketParser/`) — três ports do GadgetBridge cobrindo dados que antes eram totalmente descartados:
  - `ManualSamplesParser` (`ACTIVITY_MANUAL_SAMPLES`, v2): medições pontuais sob demanda — FC (`0x11`), SpO₂ (`0x12`), estresse (`0x13`) e **temperatura corporal** (`0x44`, centi-°C).
  - `WorkoutSummaryParser` + builder posicional (`XiaomiSimpleActivityParser`): resumos de treino para todas as modalidades da Mi Band 10 (corrida, caminhada, esteira, ciclismo indoor/outdoor, livre, natação, HIIT, elíptico, remo, pular corda), com blueprint por (subtype, versão). Extrai duração, calorias, distância, passos, FC méd/máx/mín, zonas de FC, VO₂máx, braçadas/estilo de natação, voltas e saltos.
  - `WorkoutGpsParser`: trilha GPS de treinos (V1/V2) → série lat/lon/hdop/velocidade.
- **Escrita de treinos e novos tipos no Apple Health** (`Health/HealthKitManager.swift`):
  - `writeWorkouts` cria `HKWorkout` via `HKWorkoutBuilder` (mapeando modalidade → `HKWorkoutActivityType`, piscina/águas abertas → `swimmingLocationType`), com totais de energia/distância (`distanceCycling`/`distanceSwimming`/`distanceWalkingRunning`), braçadas (`swimmingStrokeCount`), VO₂máx (`vo2Max`) e **rota GPS** via `HKWorkoutRouteBuilder`.
  - `writeManualSamples` grava temperatura corporal (`bodyTemperature`), FC e SpO₂ pontuais.
  - Frequência cardíaca **de repouso** (`restingHeartRate`) do resumo diário, que era parseada mas nunca gravada.
  - Novos tipos adicionados à autorização do HealthKit e à descrição em `Info.plist`.
- **`XiaomiActivityFileMeta`** — helpers de roteamento `isManualSamples`, `isWorkoutSummary`, `isWorkoutGps`; `BandSyncer.syncToHealth()` agora roteia esses arquivos para os novos parsers/escritas (com contadores `manualSamples`/`workouts` no `HealthSyncOutcome`).
- **Sincronização com Apple Health** (`Health/HealthKitManager.swift`) — autorização + escrita de sono (`sleepAnalysis`), passos, calorias ativas, distância, frequência cardíaca e SpO₂. Deduplicação via `HKMetadataKeySyncIdentifier`/`SyncVersion` (re-sync substitui em vez de duplicar). Capability HealthKit + `NSHealth{Update,Share}UsageDescription` adicionados.
- **Parsers de atividade** (`BLE/PacketParser/`) — `DailySummaryParser` (totais do dia: passos, calorias, HR máx/mín/médio, SpO₂ máx/mín, ports do GadgetBridge v3/v5), `DailyDetailsParser` + `XiaomiBitGroupReader` (séries por minuto de HR/SpO₂/distância via parser de grupos de bits) e `XiaomiActivityFileMeta` (parsing do id de 7 bytes: versão/subtipo/detailType).
- **`BandSyncer.syncToHealth()`** — busca os arquivos de atividade do dia, roteia por tipo (sono/summary/details) → SwiftData + HealthKit, faz ACK de cada arquivo e atualiza `lastHealthSyncDate`.
- **Bateria** — `BandManager` parseia `System.power.battery` (nível + carregando) das respostas do dispositivo e publica `batteryLevel`/`batteryCharging`.
- **Dashboard** (`UI/Dashboard/DashboardView.swift`) — status da pulseira, bateria, última sincronização com o Apple Health e botão "Sincronizar com Apple Health". Componentes `MBCard`/`MBMetricTile`. `RootView` passou a abrir o Dashboard no estado conectado.
- **Design system em SwiftUI** (`UI/DesignSystem/`) — port dos tokens do handoff do Claude Design: `Theme.swift` (paleta midnight, accent Aurora, cores de saúde/sono/status, tipografia iOS, spacing 4-pt, radii contínuos) + componentes `MBButton`, `MBIconButton`, `MBTextField`, `MBStatusPill`.
- **Fluxo de Setup** (`UI/Setup/`) — `SetupView` (intro + entrada de AuthKey com campo mono/mascarado e validação 32-hex) e `ConnectingView` (handshake animado dirigido pelo `BandManager.connectionState` real, com retry em erro). `RootView` roteia Setup → Connecting → tela conectada (placeholder até o Dashboard). AuthKey é salvo no Keychain pela UI; o scan/conexão deixou de ser disparado no `onAppear` do App.
- **`ConnectionState` → UI** (`UI/ConnectionStatus+UI.swift`) — rótulos/tom de pill e passos do handshake em pt-BR.
- **SwiftProtobuf 1.38** adicionado como dependência SPM (`apple/swift-protobuf`). Vinculado ao target "My Band" via `XCRemoteSwiftPackageReference` no `project.pbxproj`.
- **`xiaomi.pb.swift`** — 129 tipos Swift gerados automaticamente a partir do `xiaomi.proto` do GadgetBridge (protoc 29.3 + protoc-gen-swift 1.38). Cobre toda a hierarquia de mensagens do protocolo Xiaomi: `Xiaomi_Command`, `Xiaomi_Auth`, `Xiaomi_Health`, `Xiaomi_System`, `Xiaomi_Clock`, `Xiaomi_AuthDeviceInfo`, `Xiaomi_WatchNonce`, etc.

### Removed

- **`ContentView.swift` e `Item.swift`** — boilerplate do template Xcode, substituídos por `RootView` e pelos modelos SwiftData reais.

### Changed

- **`XiaomiProto.swift`** — encoder/decoder manual (≈260 linhas de varint artesanal) substituído por camada fina sobre os tipos gerados pelo SwiftProtobuf. Mesma API pública (`phoneNonceCommand`, `authStep3Command`, `authDeviceInfo`, `setCurrentTimeCommand`, `healthCommand`), zero parsing manual.
- **`BandAuthenticator.parseWatchNonce`** — migrado de `bytesField(31, from:)` aninhado para `Xiaomi_Command(serializedBytes:)` diretamente via `cmd.auth.watchNonce`.
- **`BandManager.handleProtoCommand`** — roteamento de tipo/subtipo migrado de `XiaomiProto.uint32Field` para `Xiaomi_Command.type` / `.subtype`.
- **`BandSyncer.extractFileIds`** — parsing de IDs de arquivo migrado de `bytesField(10/7, from:)` para `cmd.health.activityRequestFileIds`.

### Added

- **Reconexão direta por identificador (`BandManager.reconnectToKnownDevice`)**: no relaunch, em vez de escanear do zero, o app recupera o periférico conhecido via `retrievePeripherals(withIdentifiers:)` e emite um `connect()` sem timeout (o iOS reconecta sozinho assim que a pulseira entra no alcance). `RootView` usa um `@Query` de `BandDevice` para obter o identificador de forma determinística no bootstrap, com fallback para scan quando não há periférico conhecido. Combinado com a state restoration já existente, minimiza a reconexão manual entre execuções.
- ~~**Sincronização de horas em pé (Stand) com o Apple Health**~~ — **revertido** (ver _Fixed_): `HKCategoryType(.appleStandHour)` é reservado e não pode ser compartilhado por apps de terceiros.

### Changed

- **Sync busca o histórico completo, não só o dia atual (`BandSyncer.fetchFileIds`)**: o fluxo agora encadeia `CMD_ACTIVITY_FETCH_TODAY` → `CMD_ACTIVITY_FETCH_PAST` (subtype 2) e mescla as duas listas de file IDs, espelhando o `XiaomiHealthService.handleActivityFetchResponse` do GadgetBridge. Antes só `FETCH_TODAY` era enviado, então noites anteriores (registros "past") nunca eram oferecidas pela pulseira. `FETCH_PAST` é best-effort (resposta vazia ou timeout não aborta o sync). Novos builders `XiaomiProto.fetchTodayCommand`/`fetchPastCommand`.
- **Escrita no HealthKit desacoplada da deduplicação do SwiftData (`BandSyncer.syncToHealth`)**: as sessões de sono agora são sempre (re)gravadas no Apple Health — a deduplicação por `HKMetadataKeySyncIdentifier` torna a operação idempotente, então dados apagados manualmente do app Saúde voltam a aparecer ao ressincronizar. O `persistIfNew` continua evitando registros locais duplicados no SwiftData.

### Fixed

- **ACK de arquivo de atividade usava o campo proto errado (`BandSyncer.sendAck`)**: `CMD_ACTIVITY_FETCH_ACK` gravava o file ID em `activityRequestFileIds` em vez do campo dedicado `activitySyncAckFileIds` (GadgetBridge `ackRecordedData`). Como o campo de ack ficava vazio, a pulseira não marcava o arquivo como sincronizado — podia reoferecê-lo ou manter no armazenamento. Novo builder `XiaomiProto.ackCommand`.
- **Estágios de sono não apareciam no Apple Health (`BLE/PacketParser/SleepPacketParser.swift`)**: o parser tinha três bugs de protocolo que impediam a extração dos pacotes de estágio. (1) O magic do pacote de estágio é lido em **little-endian** pelo GadgetBridge (bytes `FB FA FC FF`), mas o parser procurava `FF FC FA FB` — então nunca encontrava os estágios. (2) O timestamp `ts` do pacote é **little-endian**, mas era lido como big-endian. (3) Os bits[11:0] de cada entrada do tipo 17 são a **duração** daquele estágio (acumulada a partir do cursor), não um offset absoluto — o cálculo anterior de duração (`próximo − atual`) produzia fases truncadas/inválidas. Reescrito como port fiel do `SleepDetailsParser.java` (header versionado via `validData`, cursor cumulativo). Agora os estágios `awake`/`core`/`deep`/`rem` populam o Apple Health.
- **Frequência cardíaca durante o sono ausente na aba "Comparisons" do Apple Health**: o parser de sono descartava a seção de HR/SpO₂ embutida no arquivo de sono (amostras `u8` com `unit`/`count`/`firstRecordTime`). Essas amostras agora são extraídas (`ParsedSleep.heartRates`/`spo2`) e gravadas no HealthKit dentro da janela de sono via `BandSyncer.syncToHealth`, permitindo que o Apple Health correlacione HR/SpO₂ com o sono. `writeSleep` passou a gravar também uma amostra `inBed` envolvente para "tempo na cama".
- **Reassembly de frames BLE fragmentados (arquivos de atividade grandes)**: `005E` é um *byte stream* — um frame SPP V2 pode exceder o MTU e chegar dividido em várias notificações (ex.: arquivo de daily details de 912 B chegando como 495 + 417). O código tratava 1 notificação = 1 frame, rejeitava as duas metades como "Malformed", nunca dava ACK no `seq`, e a banda retransmitia a cada ~6 s indefinidamente — o daily details nunca era montado (timeout). Adicionado buffer de RX em `BandManager.drainFrames()` que acumula bytes e extrai frames completos pelo `payloadLen` (com resync ao preâmbulo `A5 A5`), espelhando `XiaomiSppProtocolV2.processPacket`. `ActivityFileReceiver` agora completa em `num == total` (semântica do GadgetBridge).
- **`writeSPP` ignora escritas em peripheral fora do estado `.connected`**: evita `API MISUSE: can only accept commands while in the connected state` quando um ACK é enfileirado logo após o disconnect de retry de auth.
- **Loop de re-autenticação a cada ~6 s: faltava ACK dos frames DATA**: O SPP V2 é um transporte confiável com janela (TX_WIN/seqNum). Toda frame DATA recebida da pulseira precisa ser confirmada com um `AckPacket` carregando o mesmo `seqNum` (GadgetBridge `XiaomiSppProtocolV2.processPacket` → `sendAck`). O app processava os pacotes mas nunca enviava ACK, então a pulseira assumia perda e retransmitia o handshake inteiro (sub=26/sub=27) indefinidamente — mesmo após auth e envio do init. Adicionado `BandManager.sendAck(seqNum:)`, chamado para cada frame DATA recebida.
- **Primeiro emparelhamento: HMAC da pulseira falhava e travava em `.error`**: No primeiro pareamento a banda envia `sub=16` e o primeiro watch nonce produz um HMAC que não bate; só uma reconexão limpa gera um handshake verificável. Antes o app ia para `.error` permanente (só recuperava se a própria banda derrubasse o link). Agora `retryAuthAfterReconnect()` derruba e reconecta automaticamente (até `maxAuthRetries=4`) ao detectar HMAC inválido, replicando o caminho que comprovadamente autentica. `didDisconnectPeripheral` honra o flag `retryAuthOnDisconnect` para reconectar mesmo em desconexão "limpa".
- **Logs de diagnóstico de autenticação**: dump hex de cada pacote do canal auth por subtype, nonces (phone/watch) e comparação HMAC banda-vs-app, e tentativa de extrair watch nonce de pacotes `sub=16`. Nonces/HMACs são logados (não são segredos); o AuthKey e as chaves de sessão nunca são logados.
- **Pós-autenticação: pulseira re-disparava auth a cada ~6 s (loop "Duplicate auth response")**: Após `CMD_AUTH` bem-sucedido, o app só enviava `setCurrentTime`. O GadgetBridge (`XiaomiSupport.onAuthSuccess`) envia `setCurrentTime` **+** `SystemService.initialize()` — começando por `CMD_DEVICE_INFO` (type=2, sub=2), `CMD_DEVICE_STATE_GET` (sub=78) e `CMD_BATTERY` (sub=1). Sem esse handshake de inicialização a banda considera a sessão incompleta e reenvia a confirmação de auth indefinidamente. Adicionado `BandManager.sendPostAuthInit()` e `XiaomiProto.systemCommand(subtype:)` + enum `XiaomiSystemCmd`.
- **`BandManager.centralManager(_:didDiscover:)` — auto-connect bloqueado por state restoration**: Quando `willRestoreState` populava `self.peripheral` antes do scan iniciar, o guard `if self.peripheral == nil` impedia que `connect(to:)` fosse chamado ao redescobrir a pulseira. O log parava em "Discovered: Xiaomi Smart Band 10 …" sem nenhuma tentativa de conexão. Corrigido: agora conecta se `self.peripheral == nil` OU se o periférico descoberto tem o mesmo `identifier` do peripheral já conhecido.

- **`authDeviceInfo` — device_type corrigido para iOS (1)**: O campo `unknown1` era `0` (ANDROID). Confirmado via análise do AstroBox-NG (`DeviceType::Ios = 1` para conexões BLE em iOS). Alterado para `1`.
- **`authDeviceInfo` — app_capability corrigido para `0xFFFF_FFFF`**: O campo `unknown3` era `224`. AstroBox envia `0xFFFFFFFF` (todos os bits = todas as capacidades habilitadas).

### Fixed

- `Info.plist` manual criado em `$(SRCROOT)/Info.plist` (fora da pasta sincronizada). `GENERATE_INFOPLIST_FILE = NO` no pbxproj. Corrige crash em device físico: `INFOPLIST_KEY_UIBackgroundModes` gerava `<string>` no plist gerado, mas `CBCentralManager` exige `UIBackgroundModes` como `<array>` — o runtime rejeitava o state restoration com `NSInternalInconsistencyException`.
- `BandManager.init` — `CBCentralManagerOptionRestoreIdentifierKey` agora condicionado a `#if !targetEnvironment(simulator)` (simulator não suporta state restoration do CoreBluetooth).
- `My_BandApp` — `sharedModelContainer` alterado de `var` para `static let`. App structs do SwiftUI podem ser recriadas durante setup de cena; um `var` recriava o `ModelContainer` (e o store SQLite) a cada vez, causando double-init visível no console como pares de mensagens CoreData.
- `BandManager.startScan()` — race condition com a inicialização do `CBCentralManager`. Chamar `startScan()` de `.onAppear` antes de `centralManagerDidUpdateState(.poweredOn)` fazia o guard falhar silenciosamente e deixava o scan nunca iniciar. Adicionado flag `pendingScan`; `centralManagerDidUpdateState` consome o flag e dispara o scan quando o BT ficar pronto.
- `My_BandApp.sharedModelContainer` — recuperação automática de store corrompido. Watchdog kills durante gravação deixam o arquivo SQLite em estado inválido. Se `ModelContainer` falhar na primeira tentativa, o store corrompido é deletado e recriado antes de chamar `fatalError`.

### Changed

#### Protocolo BLE — Reescrita completa baseada no GadgetBridge (análise direta do código-fonte)

Todos os arquivos da camada BLE foram reescritos com base na análise completa do repositório GadgetBridge
(`XiaomiSppPacketV2`, `XiaomiAuthService`, `MiBand10Coordinator`, `XiaomiHealthService`,
`XiaomiActivityFileFetcher`, `SleepDetailsParser`). A implementação anterior era baseada no protocolo
Mi Band 5/6 (AES-128-ECB + UUIDs FEE0/FEE1) e não funcionava com a Mi Band 10.

- **`MiBandUUID`** — UUIDs corrigidos para o protocolo V2 confirmado: `0051` (cmd notify), `0052` (cmd write), `0053` (activity notify). Serviço de Heart Rate GATT padrão removido (não é assim que a Mi Band 10 reporta HR). UUIDs legados `005E`/`005F` eliminados.

- **`BandProtocol` / `XiaomiSppPacket`** — Reescrito para `XiaomiSppPacketV2`:
  - Header reduzido de 10 para **8 bytes**: `[0xA5][0xA5][type][seqNum][lenLo][lenHi][crcLo][crcHi]`
  - CRC-16/ARC calculado **apenas sobre o payload** (não sobre o frame inteiro)
  - Algoritmo CRC exato do GadgetBridge: processamento bit-a-bit com intermediário 32-bit e bit-reversal
  - Tipos de pacote corrigidos: `ACK=1`, `SESSION_CONFIG=2`, `DATA=3` (eram 0/1/2)
  - Estrutura interna do DATA packet: `[rawChannel & 0xf][opCode][dados]` — canal estava incorretamente no header externo
  - Session config: payload binário fixo (não protobuf), tipo `SESSION_CONFIG`, com resposta `OPCODE_START_SESSION_RESPONSE=2` antes de iniciar auth

- **`BandAuthenticator`** — Reescrito para o protocolo HMAC-SHA256 V2:
  - `CMD_NONCE` (type=1, sub=26): nonce do phone como `Command { auth { phoneNonce { nonce } } }` (proto aninhado)
  - Parsing da resposta da banda: `Command.auth(3).watchNonce(31).nonce(1)` e `.hmac(2)`
  - Verificação do HMAC usando `decryptionKey` derivada (não o `secretKey` bruto)
  - `CMD_AUTH` (type=1, sub=27): `AuthStep3 { encryptedNonces, encryptedDeviceInfo }` — `encryptedNonces` é HMAC-SHA256(encKey, phoneNonce||watchNonce); `encryptedDeviceInfo` é AES-128-CCM(AuthDeviceInfo proto)

- **`XiaomiCrypto`** — Corrigida a derivação PRK:
  - **Antes (errado):** `HMAC-SHA256(key=secretKey, data=phoneNonce||watchNonce)`
  - **Depois (correto):** `HMAC-SHA256(key=phoneNonce||watchNonce, data=secretKey)` — key/data invertidos vs RFC 5869
  - Adicionada implementação de AES-128-CCM manual via AES-ECB (CommonCrypto não expõe CCM): CBC-MAC sobre B₀ + plaintext em blocos de 16, seguido de encrypt-then-tag com blocos contador; tag de 4 bytes, nonce de 12 bytes, sem AAD

- **`XiaomiProto`** — Adicionados builders de comandos de auth com proto aninhado correto:
  - `phoneNonceCommand`: `Command { auth { phoneNonce(field 30) { nonce(1) } } }`
  - `authStep3Command`: `Command { auth { authStep3(field 32) { encryptedNonces(1), encryptedDeviceInfo(2) } } }`
  - `healthCommand`: `Command { type=8, subtype, health(field 10) { activityRequestFileIds(field 7) } }`
  - Removido `import Foundation` duplicado e extensão `Locale` morta no final do arquivo

- **`BandManager`** — Máquina de estados atualizada para o fluxo V2:
  - Características corretas: `0051` (notify), `0052` (write), `0053` (activity notify)
  - Novo estado `sessionConfig`: envia config binária, aguarda `OPCODE_START_SESSION_RESPONSE` antes de iniciar nonce
  - Roteamento de DATA packets via `rawChannel` + `opCode` do payload interno
  - Descriptografia AES-CTR com `decryptionKey` para pacotes `opCode=ENCRYPTED`
  - Callbacks adicionados: `onProtoCommandReceived` (respostas proto pós-auth em 0051) e `onActivityChunkReceived` (chunks de atividade em 0053)
  - `handleProtoCommand`: respostas não-auth encaminhadas via `onProtoCommandReceived`

- **`BandSyncer`** — Fluxo de sincronização de atividade reescrito:
  - Receptor de chunks (`ActivityFileReceiver`): formato `[totalChunks:2LE][currentChunk:2LE][data...]`, CRC-32 nos últimos 4 bytes do arquivo remontado
  - Fluxo correto: `subtype=1` (fetchToday) → IDs de arquivo em proto no `onProtoCommandReceived` → `subtype=3` (fetchRequest, por arquivo) → chunks em `onActivityChunkReceived` → `subtype=5` (fetchAck)
  - `fetchFileIds` corrigido para usar `onProtoCommandReceived` (IDs chegam como proto Command em 0051, não como chunks de atividade em 0053)
  - `XiaomiActivityFileId`: helper que identifica arquivos de sono por flags (`subtype==0x03||0x08`)

- **`SleepDetailsParser`** (era `SleepPacketParser`) — Reescrito para o formato real de arquivo de atividade:
  - Lê `bedTime`/`wakeupTime` do header fixo (offsets 10/14, UInt32 LE)
  - Varre o arquivo buscando magic `0xFFFC FAFB`, parseia header de 17 bytes dos stage packets
  - Tipo `0x11`: entradas UInt16 BE onde `bits[15:12]=stage`, `bits[11:0]=offset_minutes`
  - Tipo `0x10`: resumo com durações (deep/light/rem/wake) em minutos, usado como fallback

### Added

- `BLE/Crypto/XiaomiCrypto.swift` — Primitivas criptográficas sem dependências externas (CommonCrypto apenas): HMAC-SHA256, HKDF-expand (RFC 5869 §2.3), AES-ECB (bloco único), AES-CTR manual com IV=key (peculiaridade V2 — "I wish I was kidding"), AES-128-CCM manual com CBC-MAC + encrypt-then-tag, derivação de `SessionKeys`.
- `BLE/Protocol/XiaomiProto.swift` — Encoder/decoder protobuf mínimo in-house: varint encode/decode, campos uint32/string/bytes/message, builders para comandos de auth e health, leitor de campos para parsing de respostas da banda.

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
