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
