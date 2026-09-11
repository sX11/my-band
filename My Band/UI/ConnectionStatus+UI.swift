import SwiftUI

// MARK: - ConnectionState → UI
//
// Maps the BLE connection state to glanceable status (pill label/tone) and to the
// monospace step line shown during the connecting handshake. pt-BR, sentence case.

extension ConnectionState {

    /// Short label for a status pill, present on every screen.
    var pillLabel: String {
        switch self {
        case .connected:           "Conectada"
        case .scanning:            "Procurando…"
        case .connecting, .discoveringServices, .sessionConfig, .authenticating:
                                   "Conectando…"
        case .awaitingPairingConfirmation: "Confirme o pareamento"
        case .disconnected:        "Desconectada"
        case .bluetoothUnavailable: "Bluetooth desligado"
        case .error:               "Erro de conexão"
        }
    }

    var pillTone: MBStatusPill.Tone {
        switch self {
        case .connected: .ok
        case .scanning, .connecting, .discoveringServices, .sessionConfig, .authenticating,
             .awaitingPairingConfirmation: .warn
        case .disconnected, .bluetoothUnavailable, .error: .danger
        }
    }

    /// Whether the status dot should pulse (transient/in-progress states).
    var pillPulses: Bool {
        switch self {
        case .scanning, .connecting, .discoveringServices, .sessionConfig, .authenticating,
             .awaitingPairingConfirmation: true
        default: false
        }
    }

    /// Detailed, technical-honest line for the connecting screen (monospace).
    var handshakeStep: String {
        switch self {
        case .scanning:            "Procurando Xiaomi Smart Band 10…"
        case .connecting:          "Conectando ao dispositivo…"
        case .discoveringServices: "Descobrindo serviço FE95…"
        case .sessionConfig:       "Negociando sessão…"
        case .authenticating:      "Handshake HMAC-SHA256…"
        case .awaitingPairingConfirmation:
                                   "Aguardando sua confirmação."
        case .connected:           "Conectada."
        case .disconnected:        "Desconectada."
        case .bluetoothUnavailable: "Ative o Bluetooth para continuar."
        case .error(let msg):      msg
        }
    }

    var isConnecting: Bool {
        switch self {
        case .scanning, .connecting, .discoveringServices, .sessionConfig, .authenticating,
             .awaitingPairingConfirmation: true
        default: false
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        if case .bluetoothUnavailable = self { return true }
        return false
    }
}
