#pragma once

#include "CoreMinimal.h"
#include "Interfaces/OnlineSessionInterface.h"

// The narrow operation surfaces make the provider-owned create/join cleanup delegates controllable
// in automation tests without constructing a full provider implementation, mirroring
// MulticaOnlineDeferredDestroyCleanup.h.
struct FDeferredCreateSessionCleanupOperations
{
	TFunction<FDelegateHandle(FOnCreateSessionCompleteDelegate)> AddOnCreateComplete;
	// IOnlineSession::ClearOnCreateSessionCompleteDelegate_Handle takes a non-const
	// FDelegateHandle&, so the surface passes the handle by value and hands the provider a
	// mutable copy instead of a const reference.
	TFunction<void(FDelegateHandle)> ClearOnCreateComplete;
	TFunction<bool(FName)> DestroySession;
};

struct FDeferredJoinSessionCleanupOperations
{
	TFunction<FDelegateHandle(FOnJoinSessionCompleteDelegate)> AddOnJoinComplete;
	TFunction<void(FDelegateHandle)> ClearOnJoinComplete;
	TFunction<bool(FName)> DestroySession;
};

// Registers the provider-owned observer that removes the session a create/join reported after the
// subsystem that requested it is already gone. The returned handle is the provider handle; the
// observer clears itself when the matching completion arrives.
FDelegateHandle RegisterDeferredCreateSessionCleanup(
	const TSharedRef<FDeferredCreateSessionCleanupOperations>& Operations,
	FName SessionName);

FDelegateHandle RegisterDeferredJoinSessionCleanup(
	const TSharedRef<FDeferredJoinSessionCleanupOperations>& Operations,
	FName SessionName);
