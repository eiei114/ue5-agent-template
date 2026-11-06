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

				Operations->ClearOnDestroyComplete(*CompletionHandle);
				CompletionHandle->Reset();
				if (!Operations->HasNamedSession(SessionName))
				{
					return;
				}

				if (RecoveryAttemptsRemaining <= 0)
				{
					Operations->ReportUnresolved(SessionName, bWasSuccessful);
					return;
				}

				// A failed completion with the named session still present gets exactly one recovery
				// attempt. The recovery delegate is registered before the request to avoid losing a
				// fast completion from a provider.
				const FDelegateHandle RecoveryHandle = RegisterDeferredDestroySessionCleanup(
					Operations, SessionName, FDelegateHandle(), RecoveryAttemptsRemaining - 1);
				if (!Operations->DestroySession(SessionName))
				{
					Operations->ClearOnDestroyComplete(RecoveryHandle);
					Operations->ReportUnresolved(SessionName, false);
				}
			}));

	if (HandleToReplace.IsValid())
	{
		Operations->ClearOnDestroyComplete(HandleToReplace);
	}
	return *CompletionHandle;
}
