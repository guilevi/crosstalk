/* Client for crosstalkd, the macOS speech daemon, from inside a Wine bottle.
 *
 * Each ct_conn is one loopback TCP connection carrying the daemon's line
 * protocol; calls on one connection are serialised by its lock. A dropped or
 * not-yet-made connection is (re)established on demand, at most once every
 * CT_RETRY_MS so a missing daemon costs callers nothing. */
#ifndef CROSSTALK_CLIENT_H
#define CROSSTALK_CLIENT_H

#include <winsock2.h>
#include <windows.h>

#define CT_DEFAULT_PORT 47655
#define CT_RETRY_MS 2000

/* Mirrors SpeakMode in crosstalkd. */
enum ct_mode {
	CT_QUEUE = 0,
	CT_INTERRUPT = 1,
	CT_NOW = 2,
	CT_NEXT = 3,
	CT_REPLACE_PENDING = 4,
};

typedef struct ct_conn {
	CRITICAL_SECTION lock;
	SOCKET sock;
	DWORD last_attempt;
	char source[64];
} ct_conn;

void ct_init(ct_conn *c, const char *source);
void ct_close(ct_conn *c);

/* Returns the utterance id, or 0 if the daemon could not be reached. */
unsigned long long ct_speak(ct_conn *c, const wchar_t *text, enum ct_mode mode);
BOOL ct_stop(ct_conn *c);
/* 1 speaking, 0 silent, -1 unreachable. */
int ct_speaking(ct_conn *c);
/* Blocks until the utterance completes. Returns TRUE if it finished, FALSE if
 * cancelled or unreachable. timeout_ms < 0 waits indefinitely. */
BOOL ct_wait(ct_conn *c, unsigned long long id, int timeout_ms);
BOOL ct_ping(ct_conn *c);

#endif
