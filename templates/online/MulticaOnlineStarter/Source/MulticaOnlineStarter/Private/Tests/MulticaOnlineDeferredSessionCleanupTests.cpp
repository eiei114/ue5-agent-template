#if WITH_DEV_AUTOMATION_TESTS

#include "Misc/AutomationTest.h"
#include "MulticaOnlineDeferredSessionCleanup.h"

namespace
{
	// One provider-owned delegate binding, held by the fake provider.
	struct FTestCleanupBinding
	{
		FDelegateHandle Handle;
		FOnCreateSessionCompleteDelegate CreateDelegate;
		FOnJoinSessionCompleteDelegate JoinDelegate;
	};

	struct FTestCleanupState
	{
		TArray<TUniquePtr<FTestCleanupBinding>> Bindings;
		bool bHasNamedSession = true;
		bool bAcceptDestroyRequests = true;
		bool bSuccessRemovesSession = true;
		int32 DestroyRequests = 0;
		FName DestroyedSessionName = NAME_None;
		// Set when a clear removed the very binding that was being broadcast. The old code cleared
		// its own handle from inside its own callback, which is exactly this situation.
		bool bClearedWhileBroadcasting = false;
		// Set when the destroy request arrived after that clear, i.e. after the callback's captured
		// state had already been released. Reading a capture after that point is the use-after-free.
		bool bDestroyedAfterClearingOwnBinding = false;
		// Owners of the operation surface at the moment a destroy was requested. The test holds one
		// TSharedRef; the completing callback must hold another, because it copies its captures into
		// locals before clearing itself.
		int32 OperationOwnersAtDestroy = 0;
	};

	// Broadcasts the provider's delegate in place, like UE 5.8 OnlineDelegateMacros do: the multicast
	// delegate is not copied before Broadcast(), and MulticastDelegateBase::RemoveDelegateInstance
	// unbinds (and destroys) the removed entry immediately even while the invocation list is locked.
	// The existing destroy-cleanup test double copies the entry first, which hides this, so this
	// double keeps the executing binding alive only until a clear removes it.
	class FControllableSessionLifecycle
	{
	public:
		// TSharedRef has no usable default constructor, so the state is created explicitly.
		FControllableSessionLifecycle()
			: State(MakeShared<FTestCleanupState>())
		{
		}

		TSharedRef<FDeferredCreateSessionCleanupOperations> MakeCreateOperations()
		{
			const TSharedRef<FTestCleanupState> SharedState = State;
			TSharedRef<FDeferredCreateSessionCleanupOperations> Operations =
				MakeShared<FDeferredCreateSessionCleanupOperations>();
			Operations->AddOnCreateComplete = [SharedState](FOnCreateSessionCompleteDelegate Delegate)
			{
				TUniquePtr<FTestCleanupBinding> Binding = MakeUnique<FTestCleanupBinding>();
				Binding->Handle = FDelegateHandle(FDelegateHandle::GenerateNewHandle);
				Binding->CreateDelegate = MoveTemp(Delegate);
				const FDelegateHandle Handle = Binding->Handle;
				SharedState->Bindings.Add(MoveTemp(Binding));
				return Handle;
			};
			Operations->ClearOnCreateComplete = MakeClear();
			Operations->DestroySession = MakeDestroy();
			return Operations;
		}

		TSharedRef<FDeferredJoinSessionCleanupOperations> MakeJoinOperations()
		{
			const TSharedRef<FTestCleanupState> SharedState = State;
			TSharedRef<FDeferredJoinSessionCleanupOperations> Operations =
				MakeShared<FDeferredJoinSessionCleanupOperations>();
			Operations->AddOnJoinComplete = [SharedState](FOnJoinSessionCompleteDelegate Delegate)
			{
				TUniquePtr<FTestCleanupBinding> Binding = MakeUnique<FTestCleanupBinding>();
				Binding->Handle = FDelegateHandle(FDelegateHandle::GenerateNewHandle);
				Binding->JoinDelegate = MoveTemp(Delegate);
				const FDelegateHandle Handle = Binding->Handle;
				SharedState->Bindings.Add(MoveTemp(Binding));
				return Handle;
			};
			Operations->ClearOnJoinComplete = MakeClear();
			Operations->DestroySession = MakeDestroy();
			return Operations;
		}

		// Records the surface so a destroy request can report how many owners it has. Takes no
		// shared reference of its own, so the count stays the test's one TSharedRef plus whatever
		// the callback under test holds.
		void WatchOperations(const TSharedRef<FDeferredCreateSessionCleanupOperations>& Operations)
		{
			CreateOperationsToWatch = &Operations;
		}

		void WatchOperations(const TSharedRef<FDeferredJoinSessionCleanupOperations>& Operations)
		{
			JoinOperationsToWatch = &Operations;
		}

		void CompleteCreate(const FName SessionName, const bool bWasSuccessful)
		{
			Broadcast(
				[](const TUniquePtr<FTestCleanupBinding>& Binding) { return Binding->CreateDelegate.IsBound(); },
				[SessionName, bWasSuccessful](FTestCleanupBinding& Binding)
				{
					Binding.CreateDelegate.ExecuteIfBound(SessionName, bWasSuccessful);
				});
		}

		void CompleteJoin(const FName SessionName, const EOnJoinSessionCompleteResult::Type Result)
		{
			Broadcast(
				[](const TUniquePtr<FTestCleanupBinding>& Binding) { return Binding->JoinDelegate.IsBound(); },
				[SessionName, Result](FTestCleanupBinding& Binding)
				{
					Binding.JoinDelegate.ExecuteIfBound(SessionName, Result);
				});
		}

		TSharedRef<FTestCleanupState> State;

	private:
		template <typename IsThisBindingType, typename ExecuteType>
		void Broadcast(IsThisBindingType&& IsThisBinding, ExecuteType&& Execute)
		{
			const int32 Index = State->Bindings.IndexOfByPredicate(IsThisBinding);
			if (Index == INDEX_NONE)
			{
				return;
			}

			// Deliberately no copy: the callback under test may free this binding while it runs.
			ExecutingBinding = State->Bindings[Index].Get();
			Execute(*ExecutingBinding);
			ExecutingBinding = nullptr;
		}

		TFunction<void(FDelegateHandle)> MakeClear()
		{
			const TSharedRef<FTestCleanupState> SharedState = State;
			return [this, SharedState](FDelegateHandle Handle)
			{
				const int32 Index = SharedState->Bindings.IndexOfByPredicate(
					[Handle](const TUniquePtr<FTestCleanupBinding>& Binding)
					{
						return Binding->Handle == Handle;
					});
				if (Index == INDEX_NONE)
				{
					return;
				}
				if (SharedState->Bindings[Index].Get() == ExecutingBinding)
				{
					// The provider destroys the executing binding, captures included, mid-broadcast.
					SharedState->bClearedWhileBroadcasting = true;
					ExecutingBinding = nullptr;
				}
				SharedState->Bindings.RemoveAt(Index);
			};
		}

		TFunction<bool(FName)> MakeDestroy()
		{
			const TSharedRef<FTestCleanupState> SharedState = State;
			return [this, SharedState](const FName SessionName)
			{
				++SharedState->DestroyRequests;
				SharedState->DestroyedSessionName = SessionName;
				SharedState->bDestroyedAfterClearingOwnBinding = SharedState->bClearedWhileBroadcasting;
				SharedState->OperationOwnersAtDestroy = CreateOperationsToWatch
					? CreateOperationsToWatch->GetSharedReferenceCount()
					: (JoinOperationsToWatch ? JoinOperationsToWatch->GetSharedReferenceCount() : 0);
				if (!SharedState->bAcceptDestroyRequests)
				{
					return false;
				}
				if (SharedState->bSuccessRemovesSession)
				{
					SharedState->bHasNamedSession = false;
				}
				return true;
			};
		}

		FTestCleanupBinding* ExecutingBinding = nullptr;
		const TSharedRef<FDeferredCreateSessionCleanupOperations>* CreateOperationsToWatch = nullptr;
		const TSharedRef<FDeferredJoinSessionCleanupOperations>* JoinOperationsToWatch = nullptr;
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FMulticaOnlineDeferredSessionCleanupTest,
	"Multica.Online.Session.DeferredCreateJoinCleanup",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FMulticaOnlineDeferredSessionCleanupTest::RunTest(const FString& Parameters)
{
	(void)Parameters;
	const FName GameSessionName(TEXT("GameSession"));
	const FName OtherSessionName(TEXT("OtherSession"));

	// A create that completes after subsystem teardown must remove the session it created. The
	// callback clears its own handle first, so it may only use local copies afterwards.
	{
		FControllableSessionLifecycle FakeSession;
		const TSharedRef<FDeferredCreateSessionCleanupOperations> Operations = FakeSession.MakeCreateOperations();
		FakeSession.WatchOperations(Operations);

		RegisterDeferredCreateSessionCleanup(Operations, GameSessionName);
		TestEqual(TEXT("create cleanup registers exactly one provider observer"), FakeSession.State->Bindings.Num(), 1);

		FakeSession.CompleteCreate(GameSessionName, true);
		TestTrue(TEXT("the callback clears the binding it is running in"), FakeSession.State->bClearedWhileBroadcasting);
		TestTrue(TEXT("the create cleanup requests its destroy after that clear"),
			FakeSession.State->bDestroyedAfterClearingOwnBinding);
		TestEqual(TEXT("a late successful create requests one destroy"), FakeSession.State->DestroyRequests, 1);
		TestTrue(TEXT("the destroy request names the session it cleans up"),
			FakeSession.State->DestroyedSessionName == GameSessionName);
		TestFalse(TEXT("a late successful create removes its session"), FakeSession.State->bHasNamedSession);
		TestEqual(TEXT("the cleared create observer is gone"), FakeSession.State->Bindings.Num(), 0);
		// 1 = this test's TSharedRef. The callback must still own its own copy while it destroys;
		// a callback that touched its captures after the clear would report 1 and is the defect.
		TestEqual(TEXT("the completing create callback still owns its operations copy"),
			FakeSession.State->OperationOwnersAtDestroy, 2);
	}

	// A create that fails has nothing to clean up, but must still clear its own observer in place.
	{
		FControllableSessionLifecycle FakeSession;
		const TSharedRef<FDeferredCreateSessionCleanupOperations> Operations = FakeSession.MakeCreateOperations();
		FakeSession.WatchOperations(Operations);
		FakeSession.State->bAcceptDestroyRequests = false;

		RegisterDeferredCreateSessionCleanup(Operations, GameSessionName);
		FakeSession.CompleteCreate(GameSessionName, false);
		TestTrue(TEXT("a failed create also clears the binding it is running in"),
			FakeSession.State->bClearedWhileBroadcasting);
		TestEqual(TEXT("a failed create requests no destroy"), FakeSession.State->DestroyRequests, 0);
		TestTrue(TEXT("a failed create leaves the provider session alone"), FakeSession.State->bHasNamedSession);
		TestEqual(TEXT("a failed create leaves no observer behind"), FakeSession.State->Bindings.Num(), 0);
	}

	// Another session name is not ours: keep the observer for the session it was registered for.
	{
		FControllableSessionLifecycle FakeSession;
		const TSharedRef<FDeferredCreateSessionCleanupOperations> Operations = FakeSession.MakeCreateOperations();

		RegisterDeferredCreateSessionCleanup(Operations, GameSessionName);
		FakeSession.CompleteCreate(OtherSessionName, true);
		TestFalse(TEXT("a foreign session name does not clear the observer"), FakeSession.State->bClearedWhileBroadcasting);
		TestEqual(TEXT("a foreign session name requests no destroy"), FakeSession.State->DestroyRequests, 0);
		TestTrue(TEXT("a foreign session name leaves the session alone"), FakeSession.State->bHasNamedSession);
		TestEqual(TEXT("a foreign session name keeps the observer"), FakeSession.State->Bindings.Num(), 1);
	}

	// The join observer has the same shape and only cleans up a successful join.
	{
		FControllableSessionLifecycle FakeSession;
		const TSharedRef<FDeferredJoinSessionCleanupOperations> Operations = FakeSession.MakeJoinOperations();
		FakeSession.WatchOperations(Operations);

		RegisterDeferredJoinSessionCleanup(Operations, GameSessionName);
		TestEqual(TEXT("join cleanup registers exactly one provider observer"), FakeSession.State->Bindings.Num(), 1);

		FakeSession.CompleteJoin(GameSessionName, EOnJoinSessionCompleteResult::Success);
		TestTrue(TEXT("the join callback clears the binding it is running in"), FakeSession.State->bClearedWhileBroadcasting);
		TestTrue(TEXT("the join cleanup requests its destroy after that clear"),
			FakeSession.State->bDestroyedAfterClearingOwnBinding);
		TestEqual(TEXT("a late successful join requests one destroy"), FakeSession.State->DestroyRequests, 1);
		TestTrue(TEXT("the join destroy request names the session it cleans up"),
			FakeSession.State->DestroyedSessionName == GameSessionName);
		TestFalse(TEXT("a late successful join removes its session"), FakeSession.State->bHasNamedSession);
		TestEqual(TEXT("the cleared join observer is gone"), FakeSession.State->Bindings.Num(), 0);
		TestEqual(TEXT("the completing join callback still owns its operations copy"),
			FakeSession.State->OperationOwnersAtDestroy, 2);
	}

	{
		FControllableSessionLifecycle FakeSession;
		const TSharedRef<FDeferredJoinSessionCleanupOperations> Operations = FakeSession.MakeJoinOperations();

		RegisterDeferredJoinSessionCleanup(Operations, GameSessionName);
		FakeSession.CompleteJoin(GameSessionName, EOnJoinSessionCompleteResult::SessionIsFull);
		TestEqual(TEXT("a failed join requests no destroy"), FakeSession.State->DestroyRequests, 0);
		TestTrue(TEXT("a failed join leaves the provider session alone"), FakeSession.State->bHasNamedSession);
		TestEqual(TEXT("a failed join leaves no observer behind"), FakeSession.State->Bindings.Num(), 0);
	}

	return true;
}

#endif // WITH_DEV_AUTOMATION_TESTS
