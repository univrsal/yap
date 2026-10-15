package server

import "core:crypto"
import "core:crypto/argon2id"
import "core:sync"
import "core:thread"

import "common:memtrack"
import "common:proto"

// Passwords and the thread that hashes them.
//
// An account's password is stored as an Argon2id hash with its own salt.
// Argon2id is deliberately slow and memory-hungry (tens of milliseconds and
// tens of megabytes per hash), which makes guessing passwords expensive.
// For the same reason, hashing can't run on the server's loop, which
// relays voice.
//
// Instead, the loop hands each password to a dedicated thread as a job
// (hash_submit), carries on, and collects finished jobs on each turn
// (hash_poll). A job can check a password against the stored one, hash a
// new password, or do both in that order. The latter is used for password
// changes, where the new password is only hashed if the old one was correct.
//
// A single thread hashes one password at a time, and at most
// HASH_QUEUE_MOST jobs may be waiting. This also limits how much work
// someone guessing passwords can make the server do.
//
// The parameter set a hash was made with is stored next to it as an index
// into HASH_PARAMS, so the parameters can be raised later without making
// old passwords unreadable.

HASH_SIZE :: 32
SALT_SIZE :: argon2id.RECOMMENDED_SALT_SIZE

// The parameter sets, indexed by the number that is stored with a hash.
// They must never be changed or removed, only added to.
//   0  minimal cost, for tests which would otherwise take seconds
//   1  the OWASP recommendation: 19 MiB, 2 passes
@(private = "file", rodata)
HASH_PARAMS := [?]argon2id.Parameters {
	0 = {memory_size = 8, passes = 1, parallelism = 1},
	1 = {memory_size = 19 * 1024, passes = 2, parallelism = 1},
}
// The parameter set used for new hashes.
HASH_PARAMS_NOW :: 1
HASH_PARAMS_TEST :: 0

// The maximum number of jobs that may be waiting for the thread.
HASH_QUEUE_MOST :: 16

// Secret is a password in the form in which it is stored.
Secret :: struct {
	hash:   [HASH_SIZE]u8,
	salt:   [SALT_SIZE]u8,
	params: int,
}

// Password is a password waiting to be hashed. It is held by value so that
// the job owns it.
Password :: struct {
	bytes: [proto.MAX_ACCOUNT_PASSWORD]u8,
	len:   int,
}

// password_of copies a password into a Password. The password must not be
// longer than allowed (see proto.account_password_ok).
password_of :: proc(text: string) -> (p: Password) {
	p.len = copy(p.bytes[:], text)
	return
}

// password_hash hashes a password with the given salt. This takes a while.
// It returns false if this build doesn't know the parameter set.
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

// secret_make hashes a new password with a fresh salt, producing the value
// to store. This takes a while.
@(require_results)
secret_make :: proc(p: ^Password, params: int) -> (s: Secret, ok: bool) {
	crypto.rand_bytes(s.salt[:])
	s.params = params
	s.hash = password_hash(p, s.salt, params) or_return
	return s, true
}

// secret_matches reports whether a password matches the stored one. This
// takes a while, and just as long for a wrong password as for a right one.
secret_matches :: proc(p: ^Password, s: ^Secret) -> bool {
	hash, ok := password_hash(p, s.salt, s.params)
	return ok && crypto.compare_constant_time(hash[:], s.hash[:]) == 1
}

Hash_Job :: struct {
	id:      u64, // assigned by hash_submit
	// Check this password against this secret...
	check:   bool,
	given:   Password,
	against: Secret,
	// ... and, if it matched or there was nothing to check, hash this
	// one.
	create:  bool,
	wanted:  Password,
	params:  int,
}

Hash_Result :: struct {
	id:      u64,
	matched: bool, // the checked password was correct (true if none was checked)
	made:    Secret, // set if a password was to be hashed and `matched` is true
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

// hash_worker_stop stops the thread after its current job and discards
// the jobs that are still waiting.
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
// It returns false if too many jobs are already waiting.
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

// hash_poll takes the result of a finished job, if there is one.
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
		// Wipe the passwords now that they are no longer needed.
		crypto.zero_explicit(&job, size_of(job))

		sync.guard(&w.mutex)
		append(&w.results, result)
	}
}
