#if WITH_DEV_AUTOMATION_TESTS

#include "Misc/AutomationTest.h"
#include "MulticaOnlineDeferredDestroyCleanup.h"
#include "UObject/UObjectGlobals.h"

namespace
{
	struct FTestDestroyDelegateEntry
	{
		FDelegateHandle Handle;
		FOnDestroySessionCompleteDelegate Delegate;
	};

	struct FTestSessionState
	{
		TArray<FTestDestroyDelegateEntry> Delegates;
		bool bHasNamedSession = true;
		bool bAcceptDestroyRequests = true;
		bool bUnresolvedReported = false;
		int32 DestroyRequests = 0;
	};

	class FControllableSessionInterface
	{
	public:
		FControllableSessionInterface()
			: State(MakeShared<FTestSessionState>())
		{
		}

		TSharedRef<FDeferredDestroySessionCleanupOperations> MakeOperations() const
		{
			const TSharedRef<FTestSessionState> SharedState = State;
			TSharedRef<FDeferredDestroySessionCleanupOperations> Operations =
				MakeShared<FDeferredDestroySessionCleanupOperations>();
			Operations->AddOnDestroyComplete = [SharedState](FOnDestroySessionCompleteDelegate Delegate)
			{
				FTestDestroyDelegateEntry Entry;
				Entry.Handle = FDelegateHandle(FDelegateHandle::GenerateNewHandle);
				Entry.Delegate = MoveTemp(Delegate);
				const FDelegateHandle Handle = Entry.Handle;
				SharedState->Delegates.Add(MoveTemp(Entry));
				return Handle;
			};
			Operations->ClearOnDestroyComplete = [SharedState](const FDelegateHandle& Handle)
			{
				SharedState->Delegates.RemoveAll(
					[&Handle](const FTestDestroyDelegateEntry& Entry) { return Entry.Handle == Handle; });
			};
			Operations->DestroySession = [SharedState](const FName)
			{
				++SharedState->DestroyRequests;
				return SharedState->bAcceptDestroyRequests;
			};
			Operations->HasNamedSession = [SharedState](const FName)
			{
				return SharedState->bHasNamedSession;
			};
			Operations->ReportUnresolved = [SharedState](const FName, const bool)
			{
				SharedState->bUnresolvedReported = true;
			};
			return Operations;
		}

		void CompleteNext(const FName SessionName, const bool bSucceeded)
		{
			if (State->Delegates.IsEmpty())
			{
				return;
			}
			const FTestDestroyDelegateEntry Pending = State->Delegates[0];
			if (bSucceeded)
			{
				State->bHasNamedSession = false;
			}
			Pending.Delegate.ExecuteIfBound(SessionName, bSucceeded);
		}

		TSharedRef<FTestSessionState> State;
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FMulticaOnlineDeferredDestroyCleanupTest,
	"Multica.Online.Session.DeferredDestroyCleanup",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FMulticaOnlineDeferredDestroyCleanupTest::RunTest(const FString& Parameters)
{
	const FName GameSessionName(TEXT("GameSession"));

	// A delayed success after subsystem teardown must only remove the old UObject-bound
	// completion observer; it must not issue a second DestroySession call.
	{
		FControllableSessionInterface FakeSession;
		const TSharedRef<FDeferredDestroySessionCleanupOperations> Operations = FakeSession.MakeOperations();
		int32 DeadSubsystemCallbackCount = 0;
		UObject* SubsystemLifetimeMarker = NewObject<UObject>(GetTransientPackage());
		const FDelegateHandle UObjectBoundHandle = Operations->AddOnDestroyComplete(
			FOnDestroySessionCompleteDelegate::CreateWeakLambda(
				SubsystemLifetimeMarker,
				[&DeadSubsystemCallbackCount](const FName, const bool) { ++DeadSubsystemCallbackCount; }));
		SubsystemLifetimeMarker->MarkAsGarbage();

		RegisterDeferredDestroySessionCleanup(Operations, GameSessionName, UObjectBoundHandle);
		TestEqual(TEXT("teardown replaces the UObject-bound completion delegate"), FakeSession.State->Delegates.Num(), 1);
		FakeSession.CompleteNext(GameSessionName, true);
		TestFalse(TEXT("late success removes the named session"), FakeSession.State->bHasNamedSession);
		TestEqual(TEXT("success does not issue duplicate cleanup"), FakeSession.State->DestroyRequests, 0);
		TestEqual(TEXT("no UObject callback is invoked after teardown"), DeadSubsystemCallbackCount, 0);
		TestEqual(TEXT("success clears the provider-owned delegate"), FakeSession.State->Delegates.Num(), 0);
	}

	// A failed completion with the session still present gets one, and only one, recovery destroy.
	{
		FControllableSessionInterface FakeSession;
		const TSharedRef<FDeferredDestroySessionCleanupOperations> Operations = FakeSession.MakeOperations();
		RegisterDeferredDestroySessionCleanup(Operations, GameSessionName);
		FakeSession.CompleteNext(GameSessionName, false);
		TestTrue(TEXT("failed original destroy keeps the session for reconciliation"), FakeSession.State->bHasNamedSession);
		TestEqual(TEXT("failure requests one recovery destroy"), FakeSession.State->DestroyRequests, 1);
		TestEqual(TEXT("recovery waits for its own completion"), FakeSession.State->Delegates.Num(), 1);

		FakeSession.CompleteNext(GameSessionName, true);
		TestFalse(TEXT("successful recovery removes the stale session"), FakeSession.State->bHasNamedSession);
		TestFalse(TEXT("successful recovery does not report unresolved cleanup"), FakeSession.State->bUnresolvedReported);
		TestEqual(TEXT("recovery completion leaves no delegate"), FakeSession.State->Delegates.Num(), 0);
	}

	// A rejected recovery request is reported explicitly instead of silently leaving a stale session.
	{
		FControllableSessionInterface FakeSession;
		FakeSession.State->bAcceptDestroyRequests = false;
		const TSharedRef<FDeferredDestroySessionCleanupOperations> Operations = FakeSession.MakeOperations();
		RegisterDeferredDestroySessionCleanup(Operations, GameSessionName);
		FakeSession.CompleteNext(GameSessionName, false);
		TestTrue(TEXT("rejected recovery reports unresolved cleanup"), FakeSession.State->bUnresolvedReported);
		TestTrue(TEXT("rejected recovery leaves provider state observable"), FakeSession.State->bHasNamedSession);
		TestEqual(TEXT("rejected recovery does not leave an orphan delegate"), FakeSession.State->Delegates.Num(), 0);
	}

	// If the recovery operation itself fails, the provider's stale named session is also explicit.
	{
		FControllableSessionInterface FakeSession;
		const TSharedRef<FDeferredDestroySessionCleanupOperations> Operations = FakeSession.MakeOperations();
		RegisterDeferredDestroySessionCleanup(Operations, GameSessionName);
		FakeSession.CompleteNext(GameSessionName, false);
		FakeSession.CompleteNext(GameSessionName, false);
		TestTrue(TEXT("failed recovery reports unresolved cleanup"), FakeSession.State->bUnresolvedReported);
		TestTrue(TEXT("failed recovery leaves provider state observable"), FakeSession.State->bHasNamedSession);
		TestEqual(TEXT("failure path never loops destroy requests"), FakeSession.State->DestroyRequests, 1);
		TestEqual(TEXT("failed recovery clears its completion delegate"), FakeSession.State->Delegates.Num(), 0);
	}

	return true;
}

#endif // WITH_DEV_AUTOMATION_TESTS
