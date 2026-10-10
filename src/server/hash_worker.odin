package server

import "core:crypto"
import "core:crypto/argon2id"
import "core:sync"
import "core:thread"

import "common:memtrack"
import "common:proto"

/*
Passwords, and the thread that hashes them.

An account's password is kept as its Argon2id hash with a salt of its
own. Argon2id is slow and hungry on purpose (tens of milliseconds and as
many megabytes), so that guessing at passwords is too; and for the same
reason it can't be done on the server's loop, which relays voice.

So the loop hands each password to a thread of its own as a job
(hash_submit), carries on, and looks for finished jobs each turn
(hash_poll). A job can check a password against what's stored, make the
hash of a new one, or both in that order (a password change: the new one
is only hashed if the old one was right).

There is one thread, so one password is hashed at a time, and only
HASH_QUEUE_MOST may be waiting. That's also what bounds how much work
somebody trying passwords can make the server do.

Which parameters a hash was made with is kept next to it, as an index
into HASH_PARAMS, so they can be raised later without old passwords
becoming unreadable.
*/

HASH_SIZE :: 32
SALT_SIZE :: argon2id.RECOMMENDED_SALT_SIZE

/*
The parameter sets, by the number that's stored with a hash. They're
never changed or removed, only added to.
  0  next to nothing: for tests, which would otherwise take seconds
  1  what OWASP recommends: 19 MiB, 2 passes
*/
@(private = "file", rodata)
HASH_PARAMS := [?]argon2id.Parameters {
	0 = {memory_size = 8, passes = 1, parallelism = 1},
	1 = {memory_size = 19 * 1024, passes = 2, parallelism = 1},
}
// The set new hashes are made with.
HASH_PARAMS_NOW :: 1
HASH_PARAMS_TEST :: 0

// How many jobs may be waiting for the thread.
HASH_QUEUE_MOST :: 16

// Secret is a password as it's stored.
Secret :: struct {
	hash:   [HASH_SIZE]u8,
	salt:   [SALT_SIZE]u8,
	params: int,
}

// A password on its way to being hashed: by value, so the job owns it.
Password :: struct {
	bytes: [proto.MAX_ACCOUNT_PASSWORD]u8,
	len:   int,
}

// password_of copies a password that is no longer than one may be
// (proto.account_password_ok).
password_of :: proc(text: string) -> (p: Password) {
	p.len = copy(p.bytes[:], text)
	return
}

// password_hash is the hash of a password with a salt, which takes a
// while. False for a parameter set this build doesn't know.
@(require_results)
password_hash :: proc(
	p: ^Password,
	salt: [SALT_SIZE]u8,
	params: int,
) -> (
	hash: [HASH_SIZE]u8,
	ok: bool,
) {
	if params < 0 || params >= len(HASH_PARAMS) {
		return
	}
	salt := salt
	set := HASH_PARAMS[params]
	if argon2id.derive(&set, p.bytes[:p.len], salt[:], hash[:]) != nil {
		return {}, false
	}
	return hash, true
}

// secret_make is a new password as it's to be stored, under a fresh
// salt. It takes a while.
@(require_results)
secret_make :: proc(p: ^Password, params: int) -> (s: Secret, ok: bool) {
	crypto.rand_bytes(s.salt[:])
	s.params = params
	s.hash = password_hash(p, s.salt, params) or_return
	return s, true
}

// secret_matches is whether a password is the one stored. It takes a
// while, and as long for a wrong one as for the right one.
secret_matches :: proc(p: ^Password, s: ^Secret) -> bool {
	hash, ok := password_hash(p, s.salt, s.params)
	return ok && crypto.compare_constant_time(hash[:], s.hash[:]) == 1
}

Hash_Job :: struct {
	id:      u64, // given by hash_submit
	// Check this password against this secret...
	check:   bool,
	given:   Password,
	against: Secret,
	// ... and, if it's right or there was nothing to check, make this
	// one's.
	create:  bool,
	wanted:  Password,
	params:  int,
}

Hash_Result :: struct {
	id:      u64,
	matched: bool, // the checked password was right (true if none was)
	made:    Secret, // if one was to be made, and `matched`
	ok:      bool, // false if the hashing itself failed
}

Hash_Worker :: struct {
	thread:  ^thread.Thread,
	mutex:   sync.Mutex,
	wake:    sync.Cond,
	jobs:    [dynamic]Hash_Job,
	results: [dynamic]Hash_Result,
	last_id: u64,
	stop:    bool,
}

hash_worker_start :: proc(w: ^Hash_Worker) -> bool {
	w.thread = thread.create_and_start_with_poly_data(w, hash_worker_run, init_context = context)
	return w.thread != nil
}

// hash_worker_stop ends the thread, after the job it's on, and drops
// what was waiting.
hash_worker_stop :: proc(w: ^Hash_Worker) {
	if w.thread == nil {
		return
	}
	sync.lock(&w.mutex)
	w.stop = true
	sync.cond_signal(&w.wake)
	sync.unlock(&w.mutex)
	thread.join(w.thread)
	thread.destroy(w.thread)
	crypto.zero_explicit(raw_data(w.jobs), len(w.jobs) * size_of(Hash_Job))
	delete(w.jobs)
	delete(w.results)
	w^ = {}
}

// hash_submit queues a job and returns the id its result will carry.
// False if too many are waiting already.
@(require_results)
hash_submit :: proc(w: ^Hash_Worker, job: ^Hash_Job) -> (id: u64, ok: bool) {
	sync.guard(&w.mutex)
	if len(w.jobs) >= HASH_QUEUE_MOST {
		return
	}
	w.last_id += 1
	job.id = w.last_id
	append(&w.jobs, job^)
	sync.cond_signal(&w.wake)
	return job.id, true
}

// hash_poll takes a finished job's result, if there is one.
@(require_results)
hash_poll :: proc(w: ^Hash_Worker) -> (result: Hash_Result, ok: bool) {
	sync.guard(&w.mutex)
	if len(w.results) == 0 {
		return
	}
	result = w.results[0]
	ordered_remove(&w.results, 0)
	return result, true
}

@(private = "file")
hash_worker_run :: proc(w: ^Hash_Worker) {
	memtrack.thread_init()
	for {
		job: Hash_Job
		{
			sync.guard(&w.mutex)
			for len(w.jobs) == 0 && !w.stop {
				sync.cond_wait(&w.wake, &w.mutex)
			}
			if w.stop {
				return
			}
			job = w.jobs[0]
			crypto.zero_explicit(&w.jobs[0], size_of(Hash_Job))
			ordered_remove(&w.jobs, 0)
		}

		result := Hash_Result {
			id      = job.id,
			matched = true,
			ok      = true,
		}
		if job.check {
			result.matched = secret_matches(&job.given, &job.against)
		}
		if job.create && result.matched {
			result.made, result.ok = secret_make(&job.wanted, job.params)
		}
		// The passwords have done their part.
		crypto.zero_explicit(&job, size_of(job))

		sync.guard(&w.mutex)
		append(&w.results, result)
	}
}
