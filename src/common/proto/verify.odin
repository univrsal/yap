package proto

// Verifying an account's email address, on a server whose registration
// requires one (src/server/verify.odin). The account's owner proves that the
// address is theirs by sending a mail from it to the server's own address
// (Server_Info's email), with the account's code in the subject. The server
// checks its mail every so often, and the account is verified once that mail
// arrives.
//
// Until then the account is Unverified (Account_Flag). It may log in, and is
// told (Self) its code and when it will be deleted if no mail arrives (0 if
// it won't be, for example for an account that changed its address). It may
// only change its address (Email_Set, which gives it a new code), log out
// and delete itself. Nobody else sees it. Once it is verified, it receives a
// Self without the flag, followed by everything a login is told.
//
// A code consists of VERIFY_CODE_SIZE characters of INVITE_ALPHABET. It is
// found in the subject regardless of case.

VERIFY_CODE_SIZE :: 8
