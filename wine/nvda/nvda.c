/* nvda.exe - a stand-in for NVDA inside a Wine bottle, as far as programs that
 * talk *to* NVDA can tell, forwarding their speech to crosstalkd on the host.
 *
 * It serves what those programs probe for and nothing else:
 *   - NVDA's controller RPC interfaces (NvdaController 1-3) on the same ncalrpc
 *     endpoint NVDA uses, so every nvdaControllerClient.dll ever shipped works;
 *   - a top-level window of class "wxWindowClassNR" titled "NVDA", which Tolk,
 *     SRAL and others check before trusting the controller;
 *   - the system screen-reader flag (SPI_SETSCREENREADER), as NVDA sets it.
 * UIA notifications reach the daemon through the uiautomationcore.dll proxy,
 * which runs inside each program instead of here. */
#include "../common/crosstalk_client.h"
#include "nvdaController.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static ct_conn speech;
static HWND main_window;

/* ---- logging ------------------------------------------------------------ */

static FILE *log_file;
static BOOL log_calls;

static void logf_(const char *fmt, ...) {
	va_list ap;
	SYSTEMTIME t;
	if (!log_file) return;
	GetLocalTime(&t);
	fprintf(log_file, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
	va_start(ap, fmt);
	vfprintf(log_file, fmt, ap);
	va_end(ap);
	fputc('\n', log_file);
	fflush(log_file);
}

static void open_log(void) {
	wchar_t path[MAX_PATH + 32];
	DWORD n = GetTempPathW(MAX_PATH, path);
	if (n == 0 || n >= MAX_PATH) return;
	wcscat(path, L"crosstalk-nvda.log");
	log_file = _wfopen(path, L"w");
	log_calls = GetEnvironmentVariableA("CROSSTALK_LOG_CALLS", NULL, 0) > 0;
}

/* ---- RPC entry points ----------------------------------------------------- */

void *__RPC_USER midl_user_allocate(SIZE_T size) { return malloc(size); }
void __RPC_USER midl_user_free(void *p) { free(p); }

error_status_t __stdcall nvdaController_testIfRunning(void) {
	if (log_calls) logf_("testIfRunning");
	return ERROR_SUCCESS;
}

/* NVDA queues controller text behind whatever it is already saying; callers
 * wanting an interrupt call cancelSpeech first, as Tolk and Prism both do. */
error_status_t __stdcall nvdaController_speakText(const wchar_t *text) {
	if (log_calls) logf_("speakText %ls", text);
	if (text) ct_speak(&speech, text, CT_QUEUE);
	return ERROR_SUCCESS;
}

error_status_t __stdcall nvdaController_cancelSpeech(void) {
	if (log_calls) logf_("cancelSpeech");
	ct_stop(&speech);
	return ERROR_SUCCESS;
}

/* There is no display to show it on; succeed like NVDA with braille off. */
error_status_t __stdcall nvdaController_brailleMessage(const wchar_t *message) {
	(void)message;
	return ERROR_SUCCESS;
}

error_status_t __stdcall nvdaController_getProcessId(ULONG *pid) {
	*pid = GetCurrentProcessId();
	return ERROR_SUCCESS;
}

/* Appends the entity named at p (just past '&') to out; returns chars consumed. */
static size_t decode_entity(const wchar_t *p, wchar_t *out, size_t *o) {
	static const struct { const wchar_t *name; wchar_t ch; } known[] = {
		{L"amp;", L'&'}, {L"lt;", L'<'}, {L"gt;", L'>'}, {L"quot;", L'"'}, {L"apos;", L'\''},
	};
	size_t i;
	if (p[0] == L'#') {
		wchar_t *end;
		unsigned long cp = p[1] == L'x' || p[1] == L'X' ? wcstoul(p + 2, &end, 16) : wcstoul(p + 1, &end, 10);
		if (*end == L';' && cp > 0 && cp < 0x110000) {
			if (cp >= 0x10000) {
				cp -= 0x10000;
				out[(*o)++] = (wchar_t)(0xD800 + (cp >> 10));
				out[(*o)++] = (wchar_t)(0xDC00 + (cp & 0x3FF));
			} else {
				out[(*o)++] = (wchar_t)cp;
			}
			return (size_t)(end - p) + 1;
		}
	}
	for (i = 0; i < ARRAYSIZE(known); i++) {
		size_t n = wcslen(known[i].name);
		if (wcsncmp(p, known[i].name, n) == 0) {
			out[(*o)++] = known[i].ch;
			return n;
		}
	}
	out[(*o)++] = L'&';
	return 0;
}

/* Reduces SSML to its spoken text: tags dropped, entities decoded. */
static wchar_t *ssml_text(const wchar_t *ssml) {
	size_t n = wcslen(ssml), o = 0;
	wchar_t *out = malloc((n + 1) * sizeof *out);
	const wchar_t *p = ssml;
	if (!out) return NULL;
	while (*p) {
		if (*p == L'<') {
			const wchar_t *end = wcschr(p, L'>');
			if (!end) break;
			/* A break or paragraph boundary should not glue words together. */
			if (o > 0 && out[o - 1] != L' ') out[o++] = L' ';
			p = end + 1;
		} else if (*p == L'&') {
			p += 1 + decode_entity(p + 1, out, &o);
		} else {
			out[o++] = *p++;
		}
	}
	out[o] = 0;
	return out;
}

error_status_t __stdcall nvdaController_speakSsml(const wchar_t *ssml, const SYMBOL_LEVEL symbolLevel,
                                                  const SPEECH_PRIORITY priority, const boolean asynchronous) {
	wchar_t *text;
	enum ct_mode mode = priority == SPEECH_PRIORITY_NOW ? CT_NOW : priority == SPEECH_PRIORITY_NEXT ? CT_NEXT : CT_QUEUE;
	unsigned long long id;
	(void)symbolLevel;
	if (log_calls) logf_("speakSsml prio=%d async=%d %ls", (int)priority, (int)asynchronous, ssml);
	if (!ssml || !(text = ssml_text(ssml))) return ERROR_INVALID_PARAMETER;
	id = ct_speak(&speech, text, mode);
	free(text);
	if (!asynchronous && id) {
		/* Waiting holds a connection for the whole utterance, so it gets its
		 * own rather than stalling every other caller behind it. Mark
		 * callbacks are not delivered (see nvdaController.idl). */
		ct_conn waiter;
		ct_init(&waiter, "nvda-wait");
		ct_wait(&waiter, id, -1);
		ct_close(&waiter);
	}
	return ERROR_SUCCESS;
}

error_status_t __stdcall nvdaController_isSpeaking(boolean *speaking) {
	*speaking = ct_speaking(&speech) == 1;
	return ERROR_SUCCESS;
}

/* ---- RPC server ----------------------------------------------------------- */

static void desktop_namespace(wchar_t *buf, size_t cch) {
	DWORD sid = 0;
	wchar_t desk[64] = L"Default";
	ProcessIdToSessionId(GetCurrentProcessId(), &sid);
	GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME, desk, sizeof desk, NULL);
	_snwprintf(buf, cch, L"%lu.%ls", sid, desk);
	buf[cch - 1] = 0;
}

static BOOL listen_on(const wchar_t *endpoint) {
	RPC_STATUS st = RpcServerUseProtseqEpW((RPC_WSTR)L"ncalrpc", RPC_C_PROTSEQ_MAX_REQS_DEFAULT, (RPC_WSTR)endpoint, NULL);
	logf_("listen ncalrpc:[%ls] -> %ld", endpoint, (long)st);
	return st == RPC_S_OK || st == RPC_S_DUPLICATE_ENDPOINT;
}

static BOOL start_rpc(void) {
	RPC_IF_HANDLE ifs[] = {
		nvdaController_NvdaController_v1_0_s_ifspec,
		nvdaController_NvdaController2_v1_0_s_ifspec,
		nvdaController_NvdaController3_v1_0_s_ifspec,
	};
	wchar_t ns[96], ep[128];
	DWORD sid = 0;
	size_t i;
	BOOL any = FALSE;
	RPC_STATUS st;

	/* The client derives the endpoint from its own session and desktop. A
	 * program on a virtual desktop would differ from us, so also listen on the
	 * name for the default desktop, and on the bare name pre-2012 clients used. */
	desktop_namespace(ns, ARRAYSIZE(ns));
	_snwprintf(ep, ARRAYSIZE(ep), L"NvdaCtlr.%ls", ns);
	any |= listen_on(ep);
	ProcessIdToSessionId(GetCurrentProcessId(), &sid);
	_snwprintf(ep, ARRAYSIZE(ep), L"NvdaCtlr.%lu.Default", sid);
	any |= listen_on(ep);
	any |= listen_on(L"NvdaCtlr");
	if (!any) return FALSE;

	for (i = 0; i < ARRAYSIZE(ifs); i++) {
		st = RpcServerRegisterIf2(ifs[i], NULL, NULL, RPC_IF_ALLOW_CALLBACKS_WITH_NO_AUTH,
		                          RPC_C_LISTEN_MAX_CALLS_DEFAULT, (unsigned)-1, NULL);
		logf_("register interface %u -> %ld", (unsigned)i, (long)st);
		if (st != RPC_S_OK) return FALSE;
	}
	st = RpcServerListen(1, RPC_C_LISTEN_MAX_CALLS_DEFAULT, TRUE);
	logf_("listen -> %ld", (long)st);
	return st == RPC_S_OK || st == RPC_S_ALREADY_LISTENING;
}

/* ---- daemon launch ------------------------------------------------------- */

/* If Crosstalk is not up, run the launcher script the installer recorded (a
 * unix path), which opens the app in the background. Wine will not
 * CreateProcess a Mach-O binary and start.exe /unix passes no arguments on,
 * hence a script. */
static void ensure_daemon(void) {
	wchar_t path[1024], cmd[1200];
	DWORD size = sizeof path, type;
	STARTUPINFOW si = {0};
	PROCESS_INFORMATION pi;
	int i;

	si.cb = sizeof si;
	if (ct_ping(&speech)) return;
	if (RegGetValueW(HKEY_LOCAL_MACHINE, L"Software\\Crosstalk", L"Launcher", RRF_RT_REG_SZ, &type, path, &size) != ERROR_SUCCESS) {
		logf_("Crosstalk unreachable and no Launcher registered");
		return;
	}
	_snwprintf(cmd, ARRAYSIZE(cmd), L"C:\\windows\\system32\\start.exe /b /unix \"%ls\"", path);
	cmd[ARRAYSIZE(cmd) - 1] = 0;
	logf_("launching daemon: %ls", cmd);
	if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) return;
	CloseHandle(pi.hThread);
	CloseHandle(pi.hProcess);
	for (i = 0; i < 50; i++) {
		Sleep(100);
		speech.last_attempt = 0;
		if (ct_ping(&speech)) return;
	}
	logf_("daemon did not come up");
}

/* ---- window and lifetime --------------------------------------------------- */

static void set_screen_reader(BOOL on) {
	SystemParametersInfoW(SPI_SETSCREENREADER, on, NULL, SPIF_SENDCHANGE);
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
	switch (msg) {
	case WM_QUERYENDSESSION:
		return TRUE;
	case WM_ENDSESSION:
		if (wp) set_screen_reader(FALSE);
		return 0;
	case WM_CLOSE:
		DestroyWindow(hwnd);
		return 0;
	case WM_DESTROY:
		PostQuitMessage(0);
		return 0;
	}
	return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR cmdline, int show) {
	WNDCLASSW wc = {0};
	MSG msg;
	HANDLE mutex;
	(void)prev; (void)show;

	if (wcsstr(cmdline, L"--quit")) {
		HWND other = FindWindowW(L"wxWindowClassNR", L"NVDA");
		if (other) PostMessageW(other, WM_CLOSE, 0, 0);
		return 0;
	}

	/* One instance per bottle; a second launch (a Run key and a manual start,
	 * say) just exits. */
	mutex = CreateMutexW(NULL, TRUE, L"Local\\CrosstalkNVDA");
	if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

	open_log();
	logf_("crosstalk nvda.exe starting, pid %lu", GetCurrentProcessId());
	if (FindWindowW(L"wxWindowClassNR", L"NVDA"))
		logf_("another NVDA window already exists (real NVDA running?); its endpoint will conflict");

	ct_init(&speech, "nvda");
	ensure_daemon();

	if (!start_rpc()) {
		logf_("RPC server failed to start");
		return 1;
	}

	wc.lpfnWndProc = wndproc;
	wc.hInstance = inst;
	wc.lpszClassName = L"wxWindowClassNR";
	RegisterClassW(&wc);
	/* A real, never-shown top-level window: FindWindow skips message-only ones. */
	main_window = CreateWindowExW(WS_EX_TOOLWINDOW, L"wxWindowClassNR", L"NVDA", WS_POPUP, 0, 0, 0, 0,
	                              NULL, NULL, inst, NULL);
	if (!main_window) {
		logf_("CreateWindow failed: %lu", GetLastError());
		return 1;
	}
	set_screen_reader(TRUE);
	logf_("ready");

	while (GetMessageW(&msg, NULL, 0, 0) > 0) {
		TranslateMessage(&msg);
		DispatchMessageW(&msg);
	}

	logf_("shutting down");
	set_screen_reader(FALSE);
	RpcMgmtStopServerListening(NULL);
	ReleaseMutex(mutex);
	return 0;
}
