#ifndef RPC_FIXES_H
#define RPC_FIXES_H
/* Replaces Wine's stubbed RpcMgmtInqIfIds and RpcIfIdVectorFree in this
 * process; see rpc_fixes.c. Safe to call from DllMain. */
void rpc_fixes_apply(void);
#endif
