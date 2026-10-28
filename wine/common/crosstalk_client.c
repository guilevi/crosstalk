#include "crosstalk_client.h"

#include <ws2tcpip.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static INIT_ONCE wsa_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK wsa_start(PINIT_ONCE once, PVOID param, PVOID *ctx) {
	WSADATA wsa;
	(void)once; (void)param; (void)ctx;
	return WSAStartup(MAKEWORD(2, 2), &wsa) == 0;
}

static unsigned short port(void) {
	char buf[16];
	DWORD n = GetEnvironmentVariableA("CROSSTALK_PORT", buf, sizeof buf);
	if (n > 0 && n < sizeof buf) {
		long p = strtol(buf, NULL, 10);
		if (p > 0 && p < 65536) return (unsigned short)p;
	}
	return CT_DEFAULT_PORT;
}

void ct_init(ct_conn *c, const char *source) {
	InitializeCriticalSection(&c->lock);
	c->sock = INVALID_SOCKET;
	c->last_attempt = 0;
	snprintf(c->source, sizeof c->source, "%s", source);
}

static void drop(ct_conn *c) {
	if (c->sock != INVALID_SOCKET) closesocket(c->sock);
	c->sock = INVALID_SOCKET;
}

void ct_close(ct_conn *c) {
	EnterCriticalSection(&c->lock);
	drop(c);
	LeaveCriticalSection(&c->lock);
	DeleteCriticalSection(&c->lock);
}

static BOOL send_all(SOCKET s, const char *p, size_t n) {
	while (n > 0) {
		int k = send(s, p, n > 0x7fffffff ? 0x7fffffff : (int)n, 0);
		if (k <= 0) return FALSE;
		p += k;
		n -= (size_t)k;
	}
	return TRUE;
}

/* Reads one reply line into buf (without the newline). Replies are short, so a
 * byte at a time keeps any following line in the socket for the next read. */
static BOOL recv_line(SOCKET s, char *buf, size_t cap) {
	size_t len = 0;
	for (;;) {
		char ch;
		int k = recv(s, &ch, 1, 0);
		if (k <= 0) return FALSE;
		if (ch == '\n') break;
		if (len + 1 < cap) buf[len++] = ch;
	}
	if (len > 0 && buf[len - 1] == '\r') len--;
	buf[len] = 0;
	return TRUE;
}

static BOOL exchange(ct_conn *c, const char *line, char *reply, size_t cap);

static BOOL ensure(ct_conn *c, BOOL force) {
	struct sockaddr_in a;
	SOCKET s;
	DWORD now = GetTickCount();
	char reply[64];
	char hello[96];
	int one = 1;

	if (c->sock != INVALID_SOCKET) return TRUE;
	if (!force && c->last_attempt && now - c->last_attempt < CT_RETRY_MS) return FALSE;
	c->last_attempt = now;
	if (!InitOnceExecuteOnce(&wsa_once, wsa_start, NULL, NULL)) return FALSE;

	s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (s == INVALID_SOCKET) return FALSE;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons(port());
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) {
		closesocket(s);
		return FALSE;
	}
	setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof one);
	c->sock = s;
	snprintf(hello, sizeof hello, "SOURCE %s", c->source);
	if (!exchange(c, hello, reply, sizeof reply)) return FALSE;
	return TRUE;
}

static BOOL exchange(ct_conn *c, const char *line, char *reply, size_t cap) {
	if (!send_all(c->sock, line, strlen(line)) || !send_all(c->sock, "\n", 1) ||
	    !recv_line(c->sock, reply, cap)) {
		drop(c);
		return FALSE;
	}
	return strncmp(reply, "OK", 2) == 0;
}

/* Sends one request and reads its reply. A connection that dies mid-request is
 * retried once right away, since the daemon may simply have restarted. */
static BOOL request(ct_conn *c, const char *line, char *reply, size_t cap) {
	BOOL had = c->sock != INVALID_SOCKET;
	if (!ensure(c, FALSE)) return FALSE;
	if (exchange(c, line, reply, cap)) return TRUE;
	if (c->sock == INVALID_SOCKET && had && ensure(c, TRUE)) return exchange(c, line, reply, cap);
	return FALSE;
}

static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *base64(const unsigned char *in, size_t n, char *out) {
	size_t i;
	char *o = out;
	for (i = 0; i + 2 < n; i += 3) {
		*o++ = b64[in[i] >> 2];
		*o++ = b64[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
		*o++ = b64[((in[i + 1] & 15) << 2) | (in[i + 2] >> 6)];
		*o++ = b64[in[i + 2] & 63];
	}
	if (i < n) {
		*o++ = b64[in[i] >> 2];
		if (i + 1 < n) {
			*o++ = b64[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
			*o++ = b64[(in[i + 1] & 15) << 2];
		} else {
			*o++ = b64[(in[i] & 3) << 4];
			*o++ = '=';
		}
		*o++ = '=';
	}
	*o = 0;
	return out;
}

unsigned long long ct_speak(ct_conn *c, const wchar_t *text, enum ct_mode mode) {
	int u8len = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
	unsigned char *u8;
	char *line, reply[64];
	unsigned long long id = 0;

	if (u8len <= 0) return 0;
	u8 = malloc((size_t)u8len);
	line = malloc(32 + ((size_t)u8len + 2) / 3 * 4);
	if (u8 && line) {
		WideCharToMultiByte(CP_UTF8, 0, text, -1, (char *)u8, u8len, NULL, NULL);
		sprintf(line, "SPEAK %d ", (int)mode);
		base64(u8, (size_t)u8len - 1, line + strlen(line));
		EnterCriticalSection(&c->lock);
		if (request(c, line, reply, sizeof reply)) id = strtoull(reply + 2, NULL, 10);
		LeaveCriticalSection(&c->lock);
	}
	free(u8);
	free(line);
	return id;
}

static BOOL simple(ct_conn *c, const char *line, char *reply, size_t cap) {
	BOOL ok;
	EnterCriticalSection(&c->lock);
	ok = request(c, line, reply, cap);
	LeaveCriticalSection(&c->lock);
	return ok;
}

BOOL ct_stop(ct_conn *c) {
	char reply[64];
	return simple(c, "STOP", reply, sizeof reply);
}

int ct_speaking(ct_conn *c) {
	char reply[64];
	if (!simple(c, "SPEAKING", reply, sizeof reply)) return -1;
	return atoi(reply + 2) != 0;
}

BOOL ct_wait(ct_conn *c, unsigned long long id, int timeout_ms) {
	char line[64], reply[64];
	if (timeout_ms < 0) sprintf(line, "WAIT %llu", id);
	else sprintf(line, "WAIT %llu %d", id, timeout_ms);
	return simple(c, line, reply, sizeof reply) && strcmp(reply, "OK done") == 0;
}

BOOL ct_ping(ct_conn *c) {
	char reply[64];
	return simple(c, "PING", reply, sizeof reply);
}
