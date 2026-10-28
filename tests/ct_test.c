/* ct_test.exe - talks to "NVDA" the way games do, for checking crosstalk.
 *
 *   ct_test tolk  <dir>        Tolk.dll (and its nvdaControllerClient) from dir
 *   ct_test prism <dir>        prism.dll from dir, best backend (CT_NOWINDOW=1: no window)
 *   ct_test nvda  <dll>        an nvdaControllerClient DLL directly
 *   ct_test uia                UiaRaiseNotificationEvent via uiautomationcore.dll
 *   ct_test inqifids           RpcMgmtInqIfIds on the NVDA endpoint (proxy's RPC fix)
 *
 * Each runs the same script: two queued messages, a long one interrupted by a
 * third, and a long one silenced. Every message starts with "[<route>]" so
 * tests/run_tests.py can find it in crosstalkd's history and check what was
 * spoken, cancelled, and in what order. */
#define COBJMACROS
#include <windows.h>
#include <ole2.h>
#include <rpc.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* One route = how to speak (with or without interrupt) and how to stop. */
struct route {
	const char *name;
	bool (*speak)(const wchar_t *text, bool interrupt);
	bool (*stop)(void);
};

static void run_script(const struct route *r) {
	wchar_t buf[256];
#define SAY(text, intr)                                                           \
	do {                                                                          \
		_snwprintf(buf, 256, L"[%hs] %ls", r->name, text);                       \
		printf("speak%s %ls -> %s\n", (intr) ? "!" : "", buf, r->speak(buf, intr) ? "ok" : "FAILED"); \
	} while (0)

	SAY(L"alpha", false);
	SAY(L"bravo", false);
	Sleep(3000);
	SAY(L"a long sentence which the next message is going to interrupt", false);
	Sleep(700);
	SAY(L"charlie", true);
	Sleep(2000);
	SAY(L"delta, another long sentence that will be silenced before it ends", false);
	Sleep(700);
	printf("stop -> %s\n", r->stop() ? "ok" : "FAILED");
	Sleep(500);
#undef SAY
}

/* ---- Tolk ----------------------------------------------------------------- */

static HMODULE tolk;
typedef void(__cdecl *void_fn)(void);
typedef const wchar_t *(__cdecl *name_fn)(void);
typedef bool(__cdecl *output_fn)(const wchar_t *, bool);
typedef bool(__cdecl *bool_fn)(void);
static output_fn tolk_output;
static bool_fn tolk_silence;

static bool tolk_speak(const wchar_t *t, bool i) { return tolk_output(t, i); }
static bool tolk_stop(void) { return tolk_silence(); }

static int test_tolk(const char *dir) {
	char path[MAX_PATH];
	name_fn detect;
	const wchar_t *sr;
	struct route r = {"tolk", tolk_speak, tolk_stop};

	SetDllDirectoryA(dir);
	snprintf(path, sizeof path, "%s\\Tolk.dll", dir);
	if (!(tolk = LoadLibraryA(path))) { printf("cannot load %s (%lu)\n", path, GetLastError()); return 1; }
	((void_fn)(void *)GetProcAddress(tolk, "Tolk_Load"))();
	detect = (name_fn)(void *)GetProcAddress(tolk, "Tolk_DetectScreenReader");
	tolk_output = (output_fn)(void *)GetProcAddress(tolk, "Tolk_Output");
	tolk_silence = (bool_fn)(void *)GetProcAddress(tolk, "Tolk_Silence");
	sr = detect();
	printf("screen reader: %ls\n", sr ? sr : L"(none)");
	if (!sr || wcscmp(sr, L"NVDA") != 0) return 2;
	run_script(&r);
	((void_fn)(void *)GetProcAddress(tolk, "Tolk_Unload"))();
	return 0;
}

/* ---- Prism ---------------------------------------------------------------- */

typedef struct {
	uint8_t version;
	void *registry;
	void *availability_callback;
	void *availability_userdata;
	uint32_t availability_poll_interval_ms;
	uint32_t availability_debounce_samples;
	uint32_t availability_backoff_max_ms;
	bool availability_auto_power_manage;
} PrismConfig;

static void *prism_backend;
typedef int (*pb_fn)(void *);
typedef int (*pb_text_fn)(void *, const char *, bool);
static pb_text_fn prism_output;
static pb_fn prism_stop_fn;

static bool prism_speak(const wchar_t *t, bool i) {
	char u8[1024];
	WideCharToMultiByte(CP_UTF8, 0, t, -1, u8, sizeof u8, NULL, NULL);
	return prism_output(prism_backend, u8, i) == 0;
}
static bool prism_stop(void) { return prism_stop_fn(prism_backend) == 0; }

static int test_prism(const char *dir) {
	char path[MAX_PATH];
	HMODULE m;
	PrismConfig (*config_init)(void);
	void *(*init)(PrismConfig *);
	void *(*acquire_best)(void *);
	const char *(*backend_name)(void *);
	PrismConfig cfg;
	void *ctx;
	struct route r = {"prism", prism_speak, prism_stop};

	SetDllDirectoryA(dir);
	snprintf(path, sizeof path, "%s\\prism.dll", dir);
	if (!(m = LoadLibraryA(path))) { printf("cannot load %s (%lu)\n", path, GetLastError()); return 1; }
	config_init = (void *)GetProcAddress(m, "prism_config_init");
	init = (void *)GetProcAddress(m, "prism_init");
	acquire_best = (void *)GetProcAddress(m, "prism_registry_acquire_best");
	backend_name = (void *)GetProcAddress(m, "prism_backend_name");
	prism_output = (pb_text_fn)(void *)GetProcAddress(m, "prism_backend_output");
	prism_stop_fn = (pb_fn)(void *)GetProcAddress(m, "prism_backend_stop");
	/* Prism's UIA backend hangs its provider off the program's own top-level
	 * window, as any game has; a console program needs one made for it.
	 * CT_NOWINDOW=1 skips it, like the windowless speech hosts some mods use. */
	if (GetEnvironmentVariableA("CT_NOWINDOW", NULL, 0) == 0) {
		WNDCLASSA wc = {0};
		HWND w;
		wc.lpfnWndProc = DefWindowProcA;
		wc.lpszClassName = "ct_test";
		RegisterClassA(&wc);
		w = CreateWindowA("ct_test", "ct_test", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 200, 100, NULL, NULL, NULL, NULL);
		SetForegroundWindow(w);
	}
	cfg = config_init();
	ctx = init(&cfg);
	if (!ctx) ctx = init(NULL); /* older Prism: no config struct */
	if (ctx) {
		size_t (*count)(void *) = (void *)GetProcAddress(m, "prism_registry_count");
		uint64_t (*id_at)(void *, size_t) = (void *)GetProcAddress(m, "prism_registry_id_at");
		const char *(*reg_name)(void *, uint64_t) = (void *)GetProcAddress(m, "prism_registry_name");
		int (*prio)(void *, uint64_t) = (void *)GetProcAddress(m, "prism_registry_priority");
		size_t i, n = count(ctx);
		for (i = 0; i < n; i++) printf("  backend %s (%d)\n", reg_name(ctx, id_at(ctx, i)), prio(ctx, id_at(ctx, i)));
	}
	if (!ctx || !(prism_backend = acquire_best(ctx))) { printf("no backend\n"); return 2; }
	printf("backend: %s\n", backend_name(prism_backend));
	run_script(&r);
	return 0;
}

/* ---- nvdaControllerClient ------------------------------------------------- */

typedef unsigned long(__stdcall *nvda_text_fn)(const wchar_t *);
typedef unsigned long(__stdcall *nvda_void_fn)(void);
static nvda_text_fn nvda_speak_text;
static nvda_void_fn nvda_cancel;

static bool nvda_speak(const wchar_t *t, bool i) {
	if (i && nvda_cancel() != 0) return false;
	return nvda_speak_text(t) == 0;
}
static bool nvda_stop(void) { return nvda_cancel() == 0; }

static int test_nvda(const char *dll) {
	HMODULE m = LoadLibraryA(dll);
	nvda_void_fn running;
	unsigned long (__stdcall *speaking)(BOOLEAN *);
	unsigned long (__stdcall *pid)(unsigned long *);
	unsigned long (__stdcall *ssml)(const wchar_t *, int, int, BOOLEAN);
	struct route r = {"nvda", nvda_speak, nvda_stop};
	unsigned long rc, p = 0;
	BOOLEAN s = 0;

	if (!m) { printf("cannot load %s (%lu)\n", dll, GetLastError()); return 1; }
	running = (nvda_void_fn)(void *)GetProcAddress(m, "nvdaController_testIfRunning");
	nvda_speak_text = (nvda_text_fn)(void *)GetProcAddress(m, "nvdaController_speakText");
	nvda_cancel = (nvda_void_fn)(void *)GetProcAddress(m, "nvdaController_cancelSpeech");
	speaking = (void *)GetProcAddress(m, "nvdaController_isSpeaking");
	pid = (void *)GetProcAddress(m, "nvdaController_getProcessId");
	ssml = (void *)GetProcAddress(m, "nvdaController_speakSsml");
	rc = running();
	printf("testIfRunning -> %lu\n", rc);
	if (rc != 0) return 2;
	if (pid) {
		rc = pid(&p);
		printf("getProcessId -> %lu (pid %lu)\n", rc, p);
	}
	run_script(&r);
	if (ssml) {
		rc = ssml(L"<speak>[nvda] ssml &amp; <mark name=\"m\"/>synchronous</speak>", -1, 0, FALSE);
		printf("speakSsml sync -> %lu\n", rc);
		rc = ssml(L"<speak>[nvda] a long normal priority sentence that urgent speech interrupts</speak>", -1, 0, TRUE);
		Sleep(600);
		rc |= ssml(L"<speak>[nvda] urgent</speak>", -1, 2, TRUE);
		printf("speakSsml now -> %lu\n", rc);
	}
	if (speaking) {
		rc = speaking(&s);
		printf("isSpeaking -> %lu (%d)\n", rc, s);
	}
	Sleep(6000);
	return 0;
}

/* ---- UIA ------------------------------------------------------------------ */

typedef HRESULT(WINAPI *notify_fn)(void *, int, int, BSTR, BSTR);
static notify_fn uia_notify;

static bool uia_raise(const wchar_t *t, int processing) {
	BSTR s = SysAllocString(t), a = SysAllocString(L"ct_test");
	HRESULT hr = uia_notify(NULL, 0 /* ItemAdded */, processing, s, a);
	SysFreeString(s);
	SysFreeString(a);
	return SUCCEEDED(hr);
}
/* NotificationProcessing_ImportantMostRecent / _All, as Prism uses them. */
static bool uia_speak(const wchar_t *t, bool i) { return uia_raise(t, i ? 1 : 2); }
static bool uia_stop(void) { return uia_raise(L"", 1); }

static int test_uia(void) {
	HMODULE m = LoadLibraryA("uiautomationcore.dll");
	BOOL (WINAPI *listening)(void);
	struct route r = {"uia", uia_speak, uia_stop};
	if (!m) { printf("cannot load uiautomationcore.dll\n"); return 1; }
	uia_notify = (notify_fn)(void *)GetProcAddress(m, "UiaRaiseNotificationEvent");
	listening = (void *)GetProcAddress(m, "UiaClientsAreListening");
	{
		BOOL sr = FALSE;
		SystemParametersInfoA(SPI_GETSCREENREADER, 0, &sr, 0);
		printf("SPI_GETSCREENREADER -> %d\n", sr);
	}
	printf("UiaClientsAreListening -> %d\n", listening());
	run_script(&r);
	return 0;
}

/* What a Prism-style client sees when asking the NVDA endpoint for its
 * interfaces; needs the proxy loaded, as prism.dll would load it. */
static int test_inqifids(void) {
	wchar_t ep[96], desk[64] = L"Default";
	DWORD sid = 0;
	RPC_WSTR sb = NULL;
	RPC_BINDING_HANDLE h = NULL;
	RPC_IF_ID_VECTOR *v = NULL;
	RPC_STATUS st;
	unsigned i;
	{
		HMODULE u = LoadLibraryA("uiautomationcore.dll");
		char path[MAX_PATH] = "";
		GetModuleFileNameA(u, path, MAX_PATH);
		printf("uiautomationcore: %p %s, crosstalk_wineuia %p\n", (void *)u, path, (void *)GetModuleHandleA("crosstalk_wineuia.dll"));
	}
	ProcessIdToSessionId(GetCurrentProcessId(), &sid);
	GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME, desk, sizeof desk, NULL);
	_snwprintf(ep, 96, L"NvdaCtlr.%lu.%ls", sid, desk);
	RpcStringBindingComposeW(NULL, (RPC_WSTR)L"ncalrpc", NULL, (RPC_WSTR)ep, NULL, &sb);
	RpcBindingFromStringBindingW(sb, &h);
	st = RpcMgmtInqIfIds(h, &v);
	printf("endpoint %ls: RpcMgmtInqIfIds -> %ld\n", ep, (long)st);
	if (st == RPC_S_OK) {
		for (i = 0; i < v->Count; i++) printf("  %08lx v%u.%u\n", v->IfId[i]->Uuid.Data1, v->IfId[i]->VersMajor, v->IfId[i]->VersMinor);
		printf("RpcIfIdVectorFree -> %ld\n", (long)RpcIfIdVectorFree(&v));
	}
	return st != RPC_S_OK;
}

int main(int argc, char **argv) {
	setvbuf(stdout, NULL, _IONBF, 0);
	if (argc >= 3 && !strcmp(argv[1], "tolk")) return test_tolk(argv[2]);
	if (argc >= 3 && !strcmp(argv[1], "prism")) return test_prism(argv[2]);
	if (argc >= 3 && !strcmp(argv[1], "nvda")) return test_nvda(argv[2]);
	if (argc >= 2 && !strcmp(argv[1], "uia")) return test_uia();
	if (argc >= 2 && !strcmp(argv[1], "inqifids")) return test_inqifids();
	printf("usage: ct_test tolk <dir> | prism <dir> | nvda <dll> | uia\n");
	return 64;
}
