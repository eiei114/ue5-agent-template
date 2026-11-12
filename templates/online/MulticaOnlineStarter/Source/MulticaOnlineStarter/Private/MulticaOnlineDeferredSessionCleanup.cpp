#include "MulticaOnlineDeferredSessionCleanup.h"

FDelegateHandle RegisterDeferredCreateSessionCleanup(
	const TSharedRef<FDeferredCreateSessionCleanupOperations>& Operations,
	const FName SessionName)
{
	check(Operations->AddOnCreateComplete);
	check(Operations->ClearOnCreateComplete);
	check(Operations->DestroySession);

	const TSharedRef<FDelegateHandle> CompletionHandle = MakeShared<FDelegateHandle>();
	*CompletionHandle = Operations->AddOnCreateComplete(
		FOnCreateSessionCompleteDelegate::CreateLambda(
			[Operations, CompletionHandle, SessionName](const FName CompletedSessionName, const bool bWasSuccessful)
			{
				if (CompletedSessionName != SessionName)
				{
					return;
				}

				// UE 5.8 broadcasts the provider's multicast delegate without copying it, and
				// MulticastDelegateBase::RemoveDelegateInstance unbinds the removed entry immediately
				// even while the invocation list is locked for broadcast. Clearing our own handle from
				// inside this lambda therefore destroys this lambda, captures included, while it still
				// runs. Copy everything needed afterwards into locals and touch no capture after the
				// clear. Same shape as MulticaOnlineDeferredDestroyCleanup.cpp.
				const TSharedRef<FDeferredCreateSessionCleanupOperations> LocalOperations = Operations;
				const FName LocalSessionName = SessionName;
				const FDelegateHandle LocalCompletionHandle = *CompletionHandle;
				CompletionHandle->Reset();
				LocalOperations->ClearOnCreateComplete(LocalCompletionHandle);
				if (bWasSuccessful)
				{
					LocalOperations->DestroySession(LocalSessionName);
				}
			}));
	return *CompletionHandle;
}

FDelegateHandle RegisterDeferredJoinSessionCleanup(
	const TSharedRef<FDeferredJoinSessionCleanupOperations>& Operations,
	const FName SessionName)
{
	check(Operations->AddOnJoinComplete);
	check(Operations->ClearOnJoinComplete);
	check(Operations->DestroySession);

	const TSharedRef<FDelegateHandle> CompletionHandle = MakeShared<FDelegateHandle>();
	*CompletionHandle = Operations->AddOnJoinComplete(
		FOnJoinSessionCompleteDelegate::CreateLambda(
			[Operations, CompletionHandle, SessionName](
				const FName CompletedSessionName, const EOnJoinSessionCompleteResult::Type Result)
			{
				if (CompletedSessionName != SessionName)
				{
					return;
				}

				// See RegisterDeferredCreateSessionCleanup: the clear destroys this lambda's captures
				// mid-broadcast, so every value used afterwards is copied into a local first.
				const TSharedRef<FDeferredJoinSessionCleanupOperations> LocalOperations = Operations;
				const FName LocalSessionName = SessionName;
				const FDelegateHandle LocalCompletionHandle = *CompletionHandle;
				CompletionHandle->Reset();
				LocalOperations->ClearOnJoinComplete(LocalCompletionHandle);
				if (Result == EOnJoinSessionCompleteResult::Success)
				{
					LocalOperations->DestroySession(LocalSessionName);
				}
			}));
	return *CompletionHandle;
}
