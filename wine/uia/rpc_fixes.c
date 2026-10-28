/* In-process stand-ins for two RPC calls Wine leaves unimplemented, which
 * NVDA controller clients use to ask the server what it supports:
 *
 *   RpcMgmtInqIfIds    a FIXME stub returning RPC_S_INVALID_BINDING, so a
 *                      client never learns the NVDA interfaces are there;
 *   RpcIfIdVectorFree  a spec stub, which raises an exception if called.
 *
 * Prism (0.18.2 onward) checks NVDA this way before using it, so under Wine
 * its NVDA backend never initialises. prism.dll imports uiautomationcore.dll,
 * so this proxy is already in every process that loads Prism; patching the two
 * stubs here, before any of the program's own code runs, fixes that program
 * alone and leaves the rest of the bottle on Wine's rpcrt4 untouched.
 *
 * The replacement only answers for crosstalk's NVDA endpoint, which is known
 * to serve NvdaController 1 to 3; any other binding gets the stub's old reply. */
#include <windows.h>
#include <rpc.h>
#include <stddef.h>
#include <wchar.h>

#include "rpc_fixes.h"

static const RPC_IF_ID nvda_interfaces[] = {
	/* NvdaController, NvdaController2, NvdaController3 (nvdaController.idl) */
	{{0xDFF50B99, 0xF7FD, 0x4ca7, {0xA8, 0x2C, 0xDA, 0xEB, 0x3E, 0x02, 0x52, 0x95}}, 1, 0},
	{{0x3D168D45, 0xCB58, 0x4270, {0x82, 0x57, 0x4E, 0x0B, 0xE5, 0x15, 0xD5, 0x57}}, 1, 0},
	{{0x019e4216, 0xa9a1, 0x7540, {0xa2, 0x17, 0xe1, 0xa2, 0xd2, 0x79, 0x30, 0x25}}, 1, 0},
};


static BOOL is_nvda_binding(RPC_BINDING_HANDLE binding) {
	RPC_WSTR str = NULL, protseq = NULL, endpoint = NULL;
	BOOL yes = FALSE;
	if (RpcBindingToStringBindingW(binding, &str) != RPC_S_OK) return FALSE;
	if (RpcStringBindingParseW(str, NULL, &protseq, NULL, &endpoint, NULL) == RPC_S_OK)
		yes = protseq && endpoint && !_wcsicmp((wchar_t *)protseq, L"ncalrpc") &&
		      !_wcsnicmp((wchar_t *)endpoint, L"NvdaCtlr", 8);
	RpcStringFreeW(&str);
	if (protseq) RpcStringFreeW(&protseq);
	if (endpoint) RpcStringFreeW(&endpoint);
	return yes && FindWindowW(L"wxWindowClassNR", L"NVDA") != NULL;
}

/* The vector, its pointer array and the ids live in one block, freed as one. */
static RPC_STATUS WINAPI inq_if_ids(RPC_BINDING_HANDLE binding, RPC_IF_ID_VECTOR **out) {
	const unsigned n = ARRAYSIZE(nvda_interfaces);
	const size_t slots_at = offsetof(RPC_IF_ID_VECTOR, IfId);
	const size_t ids_at = (slots_at + n * sizeof(RPC_IF_ID *) + 7) & ~(size_t)7;
	char *block;
	RPC_IF_ID **slots;
	RPC_IF_ID *ids;
	unsigned i;

	if (!out) return RPC_S_INVALID_ARG;
	*out = NULL;
	if (!binding || !is_nvda_binding(binding)) return RPC_S_INVALID_BINDING;
	block = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, ids_at + n * sizeof(RPC_IF_ID));
	if (!block) return RPC_S_OUT_OF_MEMORY;
	slots = (RPC_IF_ID **)(block + slots_at);
	ids = (RPC_IF_ID *)(block + ids_at);
	for (i = 0; i < n; i++) {
		ids[i] = nvda_interfaces[i];
		slots[i] = &ids[i];
	}
	((RPC_IF_ID_VECTOR *)block)->Count = n;
	*out = (RPC_IF_ID_VECTOR *)block;
	return RPC_S_OK;
}

static RPC_STATUS WINAPI if_id_vector_free(RPC_IF_ID_VECTOR **vec) {
	if (!vec) return RPC_S_INVALID_ARG;
	if (*vec) HeapFree(GetProcessHeap(), 0, *vec);
	*vec = NULL;
	return RPC_S_OK;
}

/* Overwrites the start of `target` with a jump to `to`. */
static BOOL redirect(void *target, void *to) {
#ifdef _WIN64
	unsigned char code[12] = {0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0}; /* mov rax, to; jmp rax */
	*(void **)(code + 2) = to;
#else
	unsigned char code[5] = {0xE9}; /* jmp rel32 */
	*(LONG *)(code + 1) = (LONG)((char *)to - ((char *)target + 5));
#endif
	DWORD old;
	if (!VirtualProtect(target, sizeof code, PAGE_EXECUTE_READWRITE, &old)) return FALSE;
	memcpy(target, code, sizeof code);
	VirtualProtect(target, sizeof code, old, &old);
	FlushInstructionCache(GetCurrentProcess(), target, sizeof code);
	return TRUE;
}

void rpc_fixes_apply(void) {
	HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
	HMODULE rpcrt4 = GetModuleHandleW(L"rpcrt4.dll");
	void *inq, *vfree;
	/* Only Wine's rpcrt4 has these as stubs; never touch a real Windows one. */
	if (!rpcrt4 || !ntdll || !GetProcAddress(ntdll, "wine_get_version")) return;
	inq = (void *)GetProcAddress(rpcrt4, "RpcMgmtInqIfIds");
	vfree = (void *)GetProcAddress(rpcrt4, "RpcIfIdVectorFree");
	if (!inq || !vfree) return;
	redirect(inq, (void *)inq_if_ids);
	redirect(vfree, (void *)if_id_vector_free);
}
