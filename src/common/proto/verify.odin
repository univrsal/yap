package proto

/*
Verifying an account's email address, on a server whose registration
asks for it (src/server/verify.odin). The address is shown to be the
account's by its owner sending a mail from it to the server's own
address (Server_Info's email), with the account's code in the subject.
The server reads its mail every so often; when that mail comes, the
account is verified.

Until then the account is Unverified (Account_Flag): it may log in, and
is told (Self) its code and when it's deleted if no mail comes (0 if it
isn't, as for an account that changed its address), but it may do
nothing but change its address (Email_Set, which gives it a new code),
log out and delete itself; nobody else sees it here. Once verified it's
told by a Self without the flag, followed by everything a login is told.

A code is VERIFY_CODE_SIZE characters of INVITE_ALPHABET, found in a
subject in any case.
*/

VERIFY_CODE_SIZE :: 8
