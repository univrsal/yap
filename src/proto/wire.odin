/*
Wire format and session crypto for yap.

The handshake is Noise XX: neither side needs to know the other's
static key in advance. The server sends its static key (encrypted) in
msg2, and the client decides whether to trust it (trust on first use,
checked against a saved key afterwards) *before* revealing its own
static key in msg3. So an impostor server learns nothing about who is
connecting. msg3 also has an encrypted payload, the client's hello
(see names.odin), which carries the server password if there is one:
only the server whose key the client checked ever sees it.

	client                               server
	Handshake_Init    e              ->
	                                 <-  Handshake_Resp    e, ee, s, es
	  (check server key)
	Handshake_Finish  s, se          ->
	                                 <-  Data (empty = confirmation,
	                                           or Refused)

All integers are little-endian.

	Handshake_Init    [type u8][sender_idx u32][noise msg1 + padding]
	Handshake_Resp    [type u8][sender_idx u32][receiver_idx u32][noise msg2]
	Handshake_Finish  [type u8][receiver_idx u32][noise msg3]
	Data              [type u8][receiver_idx u32][counter u64][ciphertext + tag]

Each side picks a random 32-bit index for a session and the peer puts
it in every packet addressed to it, so sessions are looked up by index
rather than by IP:port (which can change under NAT).

Handshake_Init is padded to be at least as large as Handshake_Resp so
the server can't be used to amplify spoofed-source UDP floods.

Data packets carry their nonce (`counter`) explicitly, because UDP
drops and reorders packets and Noise's implicit counter would desync.
The header is passed as AAD so it cannot be tampered with.
*/
package proto

import "core:time"

PROTOCOL_NAME :: "Noise_XX_25519_ChaChaPoly_BLAKE2s"
// Mixed into the handshake transcript; bump it on incompatible changes
// so mismatched peers fail the handshake instead of misparsing data.
PROLOGUE :: "yap v5"

// The server's UDP port unless its config says otherwise, and what the
// client assumes for an address without one.
DEFAULT_PORT :: 7777

KEY_SIZE :: 32
TAG_SIZE :: 16

// Keep datagrams under a conservative path MTU to avoid IP fragmentation.
MAX_PACKET_SIZE :: 1400

INIT_HEADER_SIZE :: 1 + 4
RESP_HEADER_SIZE :: 1 + 4 + 4
FINISH_HEADER_SIZE :: 1 + 4
DATA_HEADER_SIZE :: 1 + 4 + 8

// msg1 is `e`; msg2 is `e` + encrypted `s` + an empty encrypted payload.
MSG2_SIZE :: KEY_SIZE + (KEY_SIZE + TAG_SIZE) + TAG_SIZE
RESP_SIZE :: RESP_HEADER_SIZE + MSG2_SIZE
// msg1's payload is unencrypted zeros, used purely as padding.
INIT_PADDING :: RESP_SIZE - INIT_HEADER_SIZE - KEY_SIZE
INIT_SIZE :: INIT_HEADER_SIZE + KEY_SIZE + INIT_PADDING

MAX_PAYLOAD_SIZE :: MAX_PACKET_SIZE - DATA_HEADER_SIZE - TAG_SIZE

// Timers, loosely modeled on WireGuard's.
// Override for testing with e.g. -define:YAP_REKEY_SECONDS=3
REKEY_AFTER :: time.Duration(#config(YAP_REKEY_SECONDS, 120)) * time.Second // client starts a fresh handshake
REJECT_AFTER :: REKEY_AFTER + 60 * time.Second // a session this old is never used
HANDSHAKE_RETRY :: 1 * time.Second // resend the last handshake packet if no reply
HANDSHAKE_TIMEOUT :: 5 * time.Second // give up on a handshake and start over / drop it
KEEPALIVE_AFTER :: 10 * time.Second // send an empty Data packet when idle
SESSION_TIMEOUT :: 30 * time.Second // server drops silent sessions

// Hard cap on messages per session, far below nonce exhaustion.
REJECT_AFTER_MESSAGES :: u64(1) << 60

Packet_Type :: enum u8 {
	Invalid          = 0,
	Handshake_Init   = 1,
	Handshake_Resp   = 2,
	Handshake_Finish = 3,
	Data             = 4,
}

packet_type :: proc(packet: []byte) -> Packet_Type {
	if len(packet) == 0 {
		return .Invalid
	}
	switch t := Packet_Type(packet[0]); t {
	case .Handshake_Init:
		if len(packet) >= INIT_SIZE {return t}
	case .Handshake_Resp:
		if len(packet) >= RESP_SIZE {return t}
	case .Handshake_Finish:
		if len(packet) > FINISH_HEADER_SIZE {return t}
	case .Data:
		if len(packet) >= DATA_HEADER_SIZE + TAG_SIZE {return t}
	case .Invalid:
	}
	return .Invalid
}
