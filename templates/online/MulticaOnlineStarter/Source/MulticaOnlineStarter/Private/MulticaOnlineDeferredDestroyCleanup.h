#pragma once

#include "CoreMinimal.h"
#include "Interfaces/OnlineSessionInterface.h"

// The narrow operation surface makes delayed teardown completion controllable in automation
// tests without constructing a full provider implementation.
struct FDeferredDestroySessionCleanupOperations
{
	TFunction<FDelegateHandle(FOnDestroySessionCompleteDelegate)> AddOnDestroyComplete;
	TFunction<void(const FDelegateHandle&)> ClearOnDestroyComplete;
	TFunction<bool(FName)> DestroySession;
	TFunction<bool(FName)> HasNamedSession;
	TFunction<void(FName, bool)> ReportUnresolved;
};

FDelegateHandle RegisterDeferredDestroySessionCleanup(
	const TSharedRef<FDeferredDestroySessionCleanupOperations>& Operations,
	FName SessionName,
	FDelegateHandle HandleToReplace = FDelegateHandle(),
	int32 RecoveryAttemptsRemaining = 1);
