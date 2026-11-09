#include "MulticaOnlineDeferredDestroyCleanup.h"

FDelegateHandle RegisterDeferredDestroySessionCleanup(
	const TSharedRef<FDeferredDestroySessionCleanupOperations>& Operations,
	const FName SessionName,
	const FDelegateHandle HandleToReplace,
	const int32 RecoveryAttemptsRemaining)
{
	check(Operations->AddOnDestroyComplete);
	check(Operations->ClearOnDestroyComplete);
	check(Operations->DestroySession);
	check(Operations->HasNamedSession);
	check(Operations->ReportUnresolved);

	const TSharedRef<FDelegateHandle> CompletionHandle = MakeShared<FDelegateHandle>();
	*CompletionHandle = Operations->AddOnDestroyComplete(
		FOnDestroySessionCompleteDelegate::CreateLambda(
			[Operations, CompletionHandle, SessionName, RecoveryAttemptsRemaining](
				const FName CompletedSessionName, const bool bWasSuccessful)
			{
				if (CompletedSessionName != SessionName)
				{
					return;
				}

				// Removing this delegate from the provider's multicast list while it broadcasts unbinds
				// and destroys this lambda, captures included. Copy everything needed afterwards into
				// locals first and touch no capture after the clear.
				const TSharedRef<FDeferredDestroySessionCleanupOperations> LocalOperations = Operations;
				const FName LocalSessionName = SessionName;
				const int32 LocalRecoveryAttemptsRemaining = RecoveryAttemptsRemaining;
				const FDelegateHandle LocalCompletionHandle = *CompletionHandle;
				CompletionHandle->Reset();
				LocalOperations->ClearOnDestroyComplete(LocalCompletionHandle);
				if (!LocalOperations->HasNamedSession(LocalSessionName))
				{
					return;
				}

				// A reported success with the session still present is not retried: only a failed
				// completion earns the recovery attempt.
				if (bWasSuccessful || LocalRecoveryAttemptsRemaining <= 0)
				{
					LocalOperations->ReportUnresolved(LocalSessionName, bWasSuccessful);
					return;
				}

				// A failed completion with the named session still present gets exactly one recovery
				// attempt. The recovery delegate is registered before the request to avoid losing a
				// fast completion from a provider.
				const FDelegateHandle RecoveryHandle = RegisterDeferredDestroySessionCleanup(
					LocalOperations, LocalSessionName, FDelegateHandle(), LocalRecoveryAttemptsRemaining - 1);
				if (!LocalOperations->DestroySession(LocalSessionName))
				{
					LocalOperations->ClearOnDestroyComplete(RecoveryHandle);
					LocalOperations->ReportUnresolved(LocalSessionName, false);
				}
			}));

	if (HandleToReplace.IsValid())
	{
		Operations->ClearOnDestroyComplete(HandleToReplace);
	}
	return *CompletionHandle;
}
