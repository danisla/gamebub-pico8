// Included in every file of the native-check build (sim/audiocmp/Makefile):
// new Lua threads (coroutines) call z8_newthread_hook, so that the profilers
// in native_main.cpp hook every coroutine, also those created before they
// were set up (fake-08's shell starts the cart's).
struct lua_State;
void z8_newthread_hook(struct lua_State *L1);
#define luai_userstatethread(L, L1) z8_newthread_hook(L1)
