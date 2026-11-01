package core

// The emoji a hint is about: one of the server's (by its index), or else a
// character as a string. Both are empty for none.
Hint_Emoji :: struct {
	custom:  Maybe(int),
	unicode: string, // temp
}
