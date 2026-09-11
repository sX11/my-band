---
status: accepted
---

# O handshake espera a pulseira e o usuário, em vez de retentar

Até 2026-09-05 o handshake da Mi Band 10 era conduzido pelo app: qualquer watch-nonce que não verificasse o HMAC significava "AuthKey errado", e a reação era derrubar o link e reconectar (`retryAuthAfterReconnect`, `maxAuthRetries = 4`). A premissa vinha do primeiro teste em hardware (2026-06-19), onde o primeiro nonce de fato falhava e uma reconexão limpa autenticava.

Os logs de hardware de 2026-09-05 mostraram que a premissa era estreita demais. Um nonce que não verifica tem pelo menos quatro causas, e só uma delas é chave errada:

1. **A pulseira ainda espera o usuário.** No primeiro pareamento ela envia `auth sub=16` e só emite um nonce verificável depois que o usuário aceita na pulseira **e** confirma a folha de pareamento Bluetooth do iOS. Antes disso ela assina com um bond que não existe.
2. **O nonce chegou atrasado.** Depois do nosso `CMD_AUTH`, a pulseira reemite um nonce próprio. Verificá-lo contra o phone-nonce já superado sempre falha — mas ela confirma o handshake original de qualquer forma.
3. **Corrida de nonce.** Um nonce que já estava no ar quando o nosso `CMD_NONCE` saiu foi assinado contra um phone-nonce que ela ainda não viu.
4. **A AuthKey está errada de verdade.**

Derrubar o link nos casos 1–3 é ativamente destrutivo: no caso 1 dispensa o próprio prompt que estamos esperando, e no caso 2 mata um handshake a um pacote do sucesso (o mesmo nonce atrasado, quando chegava depois do `sub=27`, era inofensivo — os dois casos aparecem no mesmo log).

## Decisão

O app passa a acompanhar o ritmo da pulseira e do usuário, não o contrário:

- `sub=16` entra em `.awaitingPairingConfirmation`, com janela de watchdog de 120 s. Divergências de HMAC durante essa espera são logadas e ignoradas — o link fica de pé, e a UI instrui o usuário a aceitar nos dois lados.
- Nonces recebidos com `CMD_AUTH` em voo são ignorados; quem decide é o `sub=27`.
- Fora do pareamento, até 2 divergências por troca de nonce são toleradas antes de escalar para reconexão.
- Um `session-config-accept` recebido em `.connected` refaz o handshake em vez de ser ignorado (ver a seção seguinte).
- O teardown de retentativa passou a ter atraso crescente (1–4 s) em vez de reconectar na hora.

### Seguir o GadgetBridge no restart de sessão

`XiaomiBleProtocolV2.processPacket` chama `startEncryptedHandshake()` a **todo** pacote de session config, sem olhar estado. Isso parecia descuidado e o app tinha uma guarda de idempotência — mas a pulseira usa esse pacote para abrir uma sessão nova (zera o contador de sequência, novo nonce, novo `sub=27`), e quando ela faz isso as chaves antigas morrem do lado dela. Ignorar o pacote deixava o app cifrando com chaves mortas: a pulseira ACKava o frame de transporte e descartava o comando em silêncio, e o sync ficava pendurado até o timeout com o link parecendo saudável.

Passamos a seguir o GadgetBridge, com **um desvio deliberado**: um repeat que chega com o handshake ainda em voo (`.authenticating`) continua ignorado. Isso protege a falha do 005F (o mesmo accept entregue duas vezes, microssegundos depois, disparava dois `CMD_NONCE` com phone-nonces diferentes e a pulseira não respondia a nenhum). A causa-raiz daquele bug já foi corrigida — 005F não é mais assinado para notify — então a guarda é cinto-e-suspensório, e é o primeiro lugar a olhar se o handshake voltar a divergir do GadgetBridge.

## Consequências

- **Uma AuthKey errada demora mais para aparecer.** Antes falhava em segundos; agora precisa esgotar 2 divergências por troca de nonce mais 4 retentativas com atraso crescente, ou a janela de 120 s do pareamento. É o preço de não confundir "espere o usuário" com "chave errada", e o caminho de erro final continua sendo `AuthError.badHMAC`.
- **O restart de sessão é limitado** (`maxBandSessionRestarts = 3` por conexão). Uma pulseira que reinicie em loop vira log ruidoso, não um loop de re-handshake.
- **Existe agora um watchdog de auth de verdade** (20 s, 120 s no pareamento). Antes `AuthError.timeout` só saía de uma desconexão — "Tempo esgotado" na prática significava "o link caiu" (hoje `AuthError.linkDropped`), e uma pulseira que emudecesse ficava pendurada indefinidamente.
- **`.awaitingPairingConfirmation` é um estado de UI de primeira classe**, não um detalhe interno: o usuário precisa saber que a bola está com ele.

Nada disso foi exercitado num pareamento novo de verdade — os logs vieram de uma pulseira já pareada e de tentativas que falhavam. A janela de 120 s e o caminho de restart de sessão pós-aceite continuam **a validar em hardware**.

## Adendo (2026-09-09) — a espera é uma janela, não um estado de conexão

A decisão acima trata a espera como um estado da conexão viva. Revendo o fluxo real, isso não cobre o formato do problema: **o pareamento inicial pede duas confirmações, em telas diferentes, e o link não sobrevive intacto entre elas.** A pulseira levanta o próprio diálogo; só depois o iOS levanta a folha de pareamento Bluetooth — e para estabelecer o bond o iOS **derruba a conexão**. Um estado por conexão morre exatamente aí, no meio da sequência, com o usuário ainda parado na frente de um prompt.

O descompasso entre os dois lados produzia quatro finais errados, todos com a mesma assinatura na UI (a tela parece travada e depois acusa chave errada):

1. `resetState` limpava `awaitingPairingConfirmation` na desconexão de bonding; a reconexão voltava com watchdog de 20 s e tolerância normal, com o diálogo da pulseira ainda aceso.
2. Quando o `sub=16` vinha **com** nonce parseável, `beginPairingConfirmationWait` nunca era chamado — duas divergências depois o link caía, dispensando o diálogo.
3. `beginPairingConfirmationWait` retornava cedo em repetições, então o `sub=16` reemitido a cada ~6 s não estendia nada e o watchdog de 120 s vencia por baixo de uma pulseira que estava perguntando.
4. `didWriteValueFor` chamava `failAuth` em `CBATTError.insufficientAuthentication` — isto é, matava o handshake **no instante** em que o iOS subia a folha, já que esse erro é a forma de o iOS dizer "vou pedir o pareamento".

### Decisão

A espera passa a ser um **deadline de 180 s que atravessa conexões** (`pairingDeadline`), não um estado da conexão corrente:

- Sobrevive ao teardown de bonding. `resetState` limpa só o flag por conexão; `startNonceExchange` restaura a postura paciente se a janela ainda estiver aberta.
- É **estendida** por toda evidência de que o humano ainda está no meio do fluxo (`sub=16` repetido, nonce pré-bond, erro ATT de segurança).
- Uma divergência de HMAC numa pulseira contra a qual **nunca** autenticamos (`everAuthenticated`, persistido) inicia a espera em vez de contar como chave errada — antes do bond, a pulseira não tem como assinar um nonce verificável.
- Dentro da janela, o orçamento de `retryAuthAfterReconnect` **não é gasto** e o watchdog se re-arma; só o vencimento da janela falha, com `AuthError.pairingNotConfirmed` (acionável) em vez de `badHMAC` ("AuthKey incorreto").
- `CBATTError.insufficientAuthentication` deixa de ser falha e vira o sinal de que o segundo prompt está com o usuário.

`PairingStage` (`.band` → `.phone`, **só avança**) existe para a UI dizer onde olhar: a tela de conexão mostra os dois passos como checklist com o ativo destacado e o tempo restante. O estágio é inferido — de `sub=16`, do erro ATT, e (heurística) de uma queda de link durante a espera — e **nunca** decide lógica de protocolo, só copy.

`CBError.peerRemovedPairingInformation` ganhou tratamento próprio: a pulseira esqueceu um bond que o iPhone ainda guarda, e nenhuma reconexão conserta isso — `AuthError.staleBond` manda o usuário esquecer o dispositivo em Ajustes › Bluetooth. `CBError.encryptionTimedOut` (folha dispensada ou expirada) mantém a janela aberta.

### Consequências

- **Uma AuthKey errada demora ainda mais para aparecer num dispositivo novo** — a janela de 180 s tem de vencer antes de qualquer escalada. Num dispositivo já pareado (`everAuthenticated`) nada muda: divergência escala como antes.
- **`everAuthenticated` é estado novo em `UserDefaults`**, indexado pelo UUID do `CBPeripheral`. Apagar o app o zera, o que só custa uma janela de espera a mais numa reconexão.
- **O avanço para `.phone` numa queda limpa é heurística.** Assumimos que uma desconexão durante a espera significa "a pulseira foi aceita, o iOS está fazendo o bond". Se estiver errada, a consequência é copy adiantada, não um handshake perdido.
- Continua tudo **a validar em hardware** — inclusive, agora, se a folha do iOS de fato produz um `insufficientAuthentication` observável neste fluxo, ou se ela sobe sem que nenhum write nosso seja rejeitado.
