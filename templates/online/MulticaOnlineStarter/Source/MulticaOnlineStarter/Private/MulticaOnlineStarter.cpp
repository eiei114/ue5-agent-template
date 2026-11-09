#include "CoreMinimal.h"
#include "Modules/ModuleManager.h"

// The plugin module has no startup work of its own, but UE still requires a module
// implementation. Without IMPLEMENT_MODULE the DLL loads and then fails to initialize
// ("plugin failed to load because module could not be initialized"), which also prevents the
// module's automation tests from registering.
IMPLEMENT_MODULE(FDefaultGameModuleImpl, MulticaOnlineStarter)
