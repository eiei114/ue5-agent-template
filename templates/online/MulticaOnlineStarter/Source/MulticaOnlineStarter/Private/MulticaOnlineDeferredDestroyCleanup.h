#pragma once

#include "CoreMinimal.h"
#include "Interfaces/OnlineSessionInterface.h"

// The narrow operation surface makes delayed teardown completion controllable in automation
// tests without constructing a full provider implementation.
struct FDeferredDestroySessionCleanupOperations
{
	TFunction<FDelegateHandle(FOnDestroySessionCompleteDelegate)> AddOnDestroyComplete;
	// IOnlineSession::ClearOnDestroySessionCompleteDelegate_Handle takes a non-const
	// FDelegateHandle&, so the surface passes the handle by value and hands the provider a
	// mutable copy instead of a const reference.
	TFunction<void(FDelegateHandle)> ClearOnDestroyComplete;
	TFunction<bool(FName)> DestroySession;
	TFunction<bool(FName)> HasNamedSession;
	TFunction<void(FName, bool)> ReportUnresolved;
};

FDelegateHandle RegisterDeferredDestroySessionCleanup(
	const TSharedRef<FDeferredDestroySessionCleanupOperations>& Operations,
	FName SessionName,
	FDelegateHandle HandleToReplace = FDelegateHandle(),
	int32 RecoveryAttemptsRemaining = 1);
