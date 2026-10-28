/* uiautomationcore.dll proxy - hears the UIA events programs raise for screen
 * readers to speak, and forwards their text to crosstalkd.
 *
 * Wine's UiaRaiseNotificationEvent is a stub that accepts the event and drops
 * it, and Wine has no UIA event path between processes, so nothing outside the
 * raising program can ever observe these. Installed as a native override in
 * the bottle, this DLL sits in every program's own process instead, where the
 * events are raised. All other exports forward to Wine's real implementation,
 * installed beside it as crosstalk_wineuia.dll (see uiautomationcore.def).
 *
 * Being loaded by every program that uses Prism, it also mends the RPC stubs
 * that keep Prism from talking to NVDA under Wine (rpc_fixes.c). */
#define COBJMACROS
#include "../common/crosstalk_client.h"
#include "rpc_fixes.h"

#include <ole2.h>
#include <uiautomationcore.h>
#include <stdio.h>
#include <wchar.h>

#define UIA_SystemAlertEventId 20023
#define UIA_LiveRegionChangedEventId 20024
#define UIA_NamePropertyId 30005

typedef HRESULT(WINAPI *notification_fn)(IRawElementProviderSimple *, enum NotificationKind,
                                         enum NotificationProcessing, BSTR, BSTR);
typedef HRESULT(WINAPI *automation_fn)(IRawElementProviderSimple *, EVENTID);
typedef BOOL(WINAPI *listening_fn)(void);

static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
static notification_fn real_notification;
static automation_fn real_automation;
static listening_fn real_listening;
static ct_conn speech;

static BOOL CALLBACK init(PINIT_ONCE o, PVOID param, PVOID *ctx) {
	HMODULE real = LoadLibraryW(L"crosstalk_wineuia.dll");
	wchar_t exe[MAX_PATH];
	char source[64] = "uia";
	const wchar_t *base;
	(void)o; (void)param; (void)ctx;

	if (real) {
		real_notification = (notification_fn)(void *)GetProcAddress(real, "UiaRaiseNotificationEvent");
		real_automation = (automation_fn)(void *)GetProcAddress(real, "UiaRaiseAutomationEvent");
		real_listening = (listening_fn)(void *)GetProcAddress(real, "UiaClientsAreListening");
	}
	/* Label speech with the program it came from, for the daemon's history. */
	if (GetModuleFileNameW(NULL, exe, MAX_PATH)) {
		base = wcsrchr(exe, L'\\');
		base = base ? base + 1 : exe;
		snprintf(source, sizeof source, "uia:%.56ls", base);
	}
	ct_init(&speech, source);
	return TRUE;
}

static void ensure_init(void) { InitOnceExecuteOnce(&once, init, NULL, NULL); }

/* Runs before the code of any DLL that imports this one, Prism included. */
BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
	(void)reserved;
	if (reason == DLL_PROCESS_ATTACH) {
		DisableThreadLibraryCalls(inst);
		rpc_fixes_apply();
	}
	return TRUE;
}

/* Like NVDA: speak the display string, cancelling current speech first when
 * the program asked for only the most recent notification to matter. An empty
 * string with such processing is how clients (Prism among them) say "stop". */
HRESULT WINAPI UiaRaiseNotificationEvent(IRawElementProviderSimple *provider, enum NotificationKind kind,
                                         enum NotificationProcessing processing, BSTR display, BSTR activity) {
	enum ct_mode mode;
	ensure_init();
	switch (processing) {
	case NotificationProcessing_ImportantMostRecent:
	case NotificationProcessing_MostRecent:
		mode = CT_INTERRUPT;
		break;
	case NotificationProcessing_CurrentThenMostRecent:
		mode = CT_REPLACE_PENDING;
		break;
	default:
		mode = CT_QUEUE;
		break;
	}
	if (display && (display[0] || mode == CT_INTERRUPT)) ct_speak(&speech, display, mode);
	if (real_notification) return real_notification(provider, kind, processing, display, activity);
	return S_OK;
}

/* Live regions and system alerts carry their text in the element's name. */
HRESULT WINAPI UiaRaiseAutomationEvent(IRawElementProviderSimple *provider, EVENTID id) {
	ensure_init();
	if (provider && (id == UIA_LiveRegionChangedEventId || id == UIA_SystemAlertEventId)) {
		VARIANT v;
		VariantInit(&v);
		if (SUCCEEDED(IRawElementProviderSimple_GetPropertyValue(provider, UIA_NamePropertyId, &v)) &&
		    V_VT(&v) == VT_BSTR && V_BSTR(&v) && V_BSTR(&v)[0])
			ct_speak(&speech, V_BSTR(&v), CT_QUEUE);
		VariantClear(&v);
	}
	if (real_automation) return real_automation(provider, id);
	return S_OK;
}

/* Programs often raise nothing unless a UIA client is listening. With the
 * crosstalk NVDA running, one effectively is. */
BOOL WINAPI UiaClientsAreListening(void) {
	ensure_init();
	if (FindWindowW(L"wxWindowClassNR", L"NVDA")) return TRUE;
	return real_listening ? real_listening() : FALSE;
}
