/*
Wire format and session crypto for yap.

The handshake is Noise IK (the same pattern WireGuard uses): the client
knows the server's static public key up front and sends its own static
key encrypted in the first message, so the whole handshake is 1 RTT.

All integers are little-endian.

	Handshake_Init  [type u8][sender_idx u32][noise msg1]
	Handshake_Resp  [type u8][sender_idx u32][receiver_idx u32][noise msg2]
	Data            [type u8][receiver_idx u32][counter u64][ciphertext + tag]

Each side picks a random 32-bit index for a session and the peer puts
it in every packet addressed to it, so sessions are looked up by index
rather than by IP:port (which can change under NAT).

Data packets carry their nonce (`counter`) explicitly, because UDP
drops and reorders packets and Noise's implicit counter would desync.
The header is passed as AAD so it cannot be tampered with.
*/
package proto

import "core:time"

PROTOCOL_NAME :: "Noise_IK_25519_ChaChaPoly_BLAKE2s"
// Mixed into the handshake transcript; bump it on incompatible changes
// so mismatched peers fail the handshake instead of misparsing data.
PROLOGUE :: "yap v1"

KEY_SIZE :: 32
TAG_SIZE :: 16

// Keep datagrams under a conservative path MTU to avoid IP fragmentation.
MAX_PACKET_SIZE :: 1400

INIT_HEADER_SIZE :: 1 + 4
RESP_HEADER_SIZE :: 1 + 4 + 4
DATA_HEADER_SIZE :: 1 + 4 + 8

MAX_PAYLOAD_SIZE :: MAX_PACKET_SIZE - DATA_HEADER_SIZE - TAG_SIZE

// Timers, loosely modeled on WireGuard's.
// Override for testing with e.g. -define:YAP_REKEY_SECONDS=3
REKEY_AFTER       :: time.Duration(#config(YAP_REKEY_SECONDS, 120)) * time.Second // client starts a fresh handshake
REJECT_AFTER      :: REKEY_AFTER + 60 * time.Second // a session this old is never used
HANDSHAKE_RETRY   :: 1 * time.Second   // resend Handshake_Init if no reply
HANDSHAKE_TIMEOUT :: 5 * time.Second   // server drops unconfirmed sessions
KEEPALIVE_AFTER   :: 10 * time.Second  // send an empty Data packet when idle
SESSION_TIMEOUT   :: 30 * time.Second  // server drops silent sessions

// Hard cap on messages per session, far below nonce exhaustion.
REJECT_AFTER_MESSAGES :: u64(1) << 60

Packet_Type :: enum u8 {
	Invalid        = 0,
	Handshake_Init = 1,
	Handshake_Resp = 2,
	Data           = 3,
}

packet_type :: proc(packet: []byte) -> Packet_Type {
	if len(packet) == 0 {
		return .Invalid
	}
	switch t := Packet_Type(packet[0]); t {
	case .Handshake_Init:
		if len(packet) > INIT_HEADER_SIZE { return t }
	case .Handshake_Resp:
		if len(packet) > RESP_HEADER_SIZE { return t }
	case .Data:
		if len(packet) >= DATA_HEADER_SIZE + TAG_SIZE { return t }
	case .Invalid:
	}
	return .Invalid
}

/*
Application messages, carried as Data plaintext. An empty plaintext is
a keepalive.

	client -> server  Voice  [kind u8][seq u32][frame...]
	server -> client  Voice  [kind u8][speaker u32][seq u32][frame...]
*/
Message_Kind :: enum u8 {
	Voice = 1,
}

VOICE_UP_HEADER_SIZE   :: 1 + 4
VOICE_DOWN_HEADER_SIZE :: 1 + 4 + 4
