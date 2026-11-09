#include "MulticaOnlineSessionSubsystem.h"

#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "MulticaOnlineSessionIdentity.h"
#include "OnlineSessionSettings.h"
#include "OnlineSubsystem.h"
#include "OnlineSubsystemUtils.h"
#include "TimerManager.h"
#include "MulticaOnlineDeferredDestroyCleanup.h"

namespace
{
	const FName GameSessionName(TEXT("GameSession"));
	const FName ProjectIdentifierSetting(MulticaOnlineSessionIdentity::SessionSettingName);

	IOnlineSubsystem* GetOnlineSubsystemForWorld(UWorld* World)
	{
		IOnlineSubsystemUtils* Utils = Online::GetUtils();
		return World && Utils ? IOnlineSubsystem::Get(Utils->GetOnlineIdentifier(World)) : nullptr;
	}

	void RegisterDeferredCreateCleanup(const IOnlineSessionPtr& SessionInterface)
	{
		const IOnlineSessionPtr SessionForCleanup = SessionInterface;
		const TSharedRef<FDelegateHandle> CleanupHandle = MakeShared<FDelegateHandle>();
		*CleanupHandle = SessionForCleanup->AddOnCreateSessionCompleteDelegate_Handle(
			FOnCreateSessionCompleteDelegate::CreateLambda(
				[SessionForCleanup, CleanupHandle](FName SessionName, const bool bWasSuccessful)
				{
					if (SessionName != GameSessionName)
					{
						return;
					}
					SessionForCleanup->ClearOnCreateSessionCompleteDelegate_Handle(*CleanupHandle);
					if (bWasSuccessful)
					{
						SessionForCleanup->DestroySession(SessionName);
					}
				}));
	}

	void RegisterDeferredJoinCleanup(const IOnlineSessionPtr& SessionInterface)
	{
		const IOnlineSessionPtr SessionForCleanup = SessionInterface;
		const TSharedRef<FDelegateHandle> CleanupHandle = MakeShared<FDelegateHandle>();
		*CleanupHandle = SessionForCleanup->AddOnJoinSessionCompleteDelegate_Handle(
			FOnJoinSessionCompleteDelegate::CreateLambda(
				[SessionForCleanup, CleanupHandle](FName SessionName, const EOnJoinSessionCompleteResult::Type Result)
				{
					if (SessionName != GameSessionName)
					{
						return;
					}
					SessionForCleanup->ClearOnJoinSessionCompleteDelegate_Handle(*CleanupHandle);
					if (Result == EOnJoinSessionCompleteResult::Success)
					{
						SessionForCleanup->DestroySession(SessionName);
					}
				}));
	}

	TSharedRef<FDeferredDestroySessionCleanupOperations> MakeDestroyCleanupOperations(
		const IOnlineSessionPtr& SessionInterface)
	{
		const IOnlineSessionPtr SessionForCleanup = SessionInterface;
		TSharedRef<FDeferredDestroySessionCleanupOperations> Operations =
			MakeShared<FDeferredDestroySessionCleanupOperations>();
		Operations->AddOnDestroyComplete = [SessionForCleanup](FOnDestroySessionCompleteDelegate Delegate)
		{
			return SessionForCleanup->AddOnDestroySessionCompleteDelegate_Handle(MoveTemp(Delegate));
		};
		Operations->ClearOnDestroyComplete = [SessionForCleanup](FDelegateHandle Handle)
		{
			SessionForCleanup->ClearOnDestroySessionCompleteDelegate_Handle(Handle);
		};
		Operations->DestroySession = [SessionForCleanup](const FName SessionName)
		{
			return SessionForCleanup->DestroySession(SessionName);
		};
		Operations->HasNamedSession = [SessionForCleanup](const FName SessionName)
		{
			return SessionForCleanup->GetNamedSession(SessionName) != nullptr;
		};
		Operations->ReportUnresolved = [](const FName SessionName, const bool bLastDestroyReportedSuccess)
		{
			UE_LOG(LogTemp, Error,
				TEXT("Deferred teardown cleanup could not remove session '%s' (provider reported success: %s); a later host attempt will report the unresolved session."),
				*SessionName.ToString(), bLastDestroyReportedSuccess ? TEXT("true") : TEXT("false"));
		};
		return Operations;
	}
}

void UMulticaOnlineSessionSubsystem::Deinitialize()
{
	if (UWorld* World = GetWorld())
	{
		World->GetTimerManager().ClearTimer(TimeoutHandle);
	}

	if (SessionInterface.IsValid())
	{
		if (ActiveOperation == EOperation::Find)
		{
			SessionInterface->CancelFindSessions();
		}
		if (ActiveOperation == EOperation::Create && CreateHandle.IsValid())
		{
			SessionInterface->ClearOnCreateSessionCompleteDelegate_Handle(CreateHandle);
			CreateHandle.Reset();
			RegisterDeferredCreateCleanup(SessionInterface);
		}
		if (ActiveOperation == EOperation::Join && JoinHandle.IsValid())
		{
			SessionInterface->ClearOnJoinSessionCompleteDelegate_Handle(JoinHandle);
			JoinHandle.Reset();
			RegisterDeferredJoinCleanup(SessionInterface);
		}
		if (CreateHandle.IsValid()) SessionInterface->ClearOnCreateSessionCompleteDelegate_Handle(CreateHandle);
		if (FindHandle.IsValid()) SessionInterface->ClearOnFindSessionsCompleteDelegate_Handle(FindHandle);
		if (JoinHandle.IsValid()) SessionInterface->ClearOnJoinSessionCompleteDelegate_Handle(JoinHandle);
		if (ActiveOperation == EOperation::Destroy && DestroyHandle.IsValid())
		{
			// Register the provider-owned callback before clearing the UObject-bound one so the
			// in-flight operation always has a completion observer.
			RegisterDeferredDestroySessionCleanup(
				MakeDestroyCleanupOperations(SessionInterface), GameSessionName, DestroyHandle);
			DestroyHandle.Reset();
		}
		else if (DestroyHandle.IsValid())
		{
			SessionInterface->ClearOnDestroySessionCompleteDelegate_Handle(DestroyHandle);
			DestroyHandle.Reset();
		}
		if (ActiveOperation != EOperation::Create && ActiveOperation != EOperation::Join && ActiveOperation != EOperation::Destroy &&
			SessionInterface->GetNamedSession(GameSessionName) != nullptr)
		{
			SessionInterface->DestroySession(GameSessionName);
		}
	}

	Super::Deinitialize();
}

void UMulticaOnlineSessionSubsystem::HostListenServer(const FString& MapPackagePath, const int32 MaxPlayers, const float TimeoutSeconds)
{
	if (bOperationPending || bOperationTimedOut)
	{
		BroadcastImmediateFailure(TEXT("Another session operation is running or still cleaning up after a timeout."));
		return;
	}

	const FString SafeMapPath = MapPackagePath.TrimStartAndEnd();
	if (!SafeMapPath.StartsWith(TEXT("/Game/")) || SafeMapPath.Contains(TEXT("..")))
	{
		BroadcastImmediateFailure(TEXT("Use a valid project map path beginning with /Game/."));
		return;
	}
	FString ProjectIdentifier;
	if (!MulticaOnlineSessionIdentity::TryGetConfiguredProjectIdentifier(ProjectIdentifier))
	{
		BroadcastImmediateFailure(TEXT("The generated project has no valid MulticaOnlineStarter SessionProjectIdentifier; regenerate it with the scaffold tool."));
		return;
	}

	IOnlineSubsystem* OnlineSubsystem = GetOnlineSubsystemForWorld(GetWorld());
	SessionInterface = OnlineSubsystem ? OnlineSubsystem->GetSessionInterface() : nullptr;
	if (!SessionInterface.IsValid())
	{
		BroadcastImmediateFailure(TEXT("The selected online subsystem has no session interface."));
		return;
	}
	if (SessionInterface->GetNamedSession(GameSessionName) != nullptr)
	{
		BroadcastImmediateFailure(TEXT("A local session already exists; it may be unresolved teardown cleanup. Leave it before hosting again."));
		return;
	}

	PendingMapPackagePath = SafeMapPath;
	BeginOperation(EOperation::Create, TimeoutSeconds);
	if (!bOperationPending)
	{
		return;
	}

	FOnlineSessionSettings Settings;
	Settings.bIsLANMatch = true;
	Settings.bShouldAdvertise = true;
	Settings.bAllowJoinInProgress = true;
	Settings.bUsesPresence = false;
	Settings.NumPublicConnections = FMath::Clamp(MaxPlayers, 1, 16);
	Settings.Set(ProjectIdentifierSetting, ProjectIdentifier, EOnlineDataAdvertisementType::ViaOnlineServiceAndPing);

	CreateHandle = SessionInterface->AddOnCreateSessionCompleteDelegate_Handle(
		FOnCreateSessionCompleteDelegate::CreateUObject(this, &ThisClass::HandleCreateCompleted));
	if (!SessionInterface->CreateSession(0, GameSessionName, Settings))
	{
		SessionInterface->ClearOnCreateSessionCompleteDelegate_Handle(CreateHandle);
		CreateHandle.Reset();
		FinishOperation(false, TEXT("CreateSession was rejected by the selected subsystem."));
	}
}

void UMulticaOnlineSessionSubsystem::FindAndJoinFirstLanSession(const float TimeoutSeconds)
{
	if (bOperationPending || bOperationTimedOut)
	{
		BroadcastImmediateFailure(TEXT("Another session operation is running or still cleaning up after a timeout."));
		return;
	}
	FString ProjectIdentifier;
	if (!MulticaOnlineSessionIdentity::TryGetConfiguredProjectIdentifier(ProjectIdentifier))
	{
		BroadcastImmediateFailure(TEXT("The generated project has no valid MulticaOnlineStarter SessionProjectIdentifier; regenerate it with the scaffold tool."));
		return;
	}

	IOnlineSubsystem* OnlineSubsystem = GetOnlineSubsystemForWorld(GetWorld());
	SessionInterface = OnlineSubsystem ? OnlineSubsystem->GetSessionInterface() : nullptr;
	if (!SessionInterface.IsValid())
	{
		BroadcastImmediateFailure(TEXT("The selected online subsystem has no session interface."));
		return;
	}

	SessionSearch = MakeShared<FOnlineSessionSearch>();
	SessionSearch->bIsLanQuery = true;
	SessionSearch->MaxSearchResults = 10;
	SessionSearch->TimeoutInSeconds = FMath::Clamp(TimeoutSeconds, 3.0f, 60.0f);
	BeginOperation(EOperation::Find, TimeoutSeconds);
	if (!bOperationPending)
	{
		return;
	}

	FindHandle = SessionInterface->AddOnFindSessionsCompleteDelegate_Handle(
		FOnFindSessionsCompleteDelegate::CreateUObject(this, &ThisClass::HandleFindCompleted));
	if (!SessionInterface->FindSessions(0, SessionSearch.ToSharedRef()))
	{
		SessionInterface->ClearOnFindSessionsCompleteDelegate_Handle(FindHandle);
		FindHandle.Reset();
		FinishOperation(false, TEXT("FindSessions was rejected by the selected subsystem."));
	}
}

void UMulticaOnlineSessionSubsystem::LeaveSession()
{
	if (bOperationPending || bOperationTimedOut)
	{
		BroadcastImmediateFailure(TEXT("Another session operation is running or still cleaning up after a timeout."));
		return;
	}

	IOnlineSubsystem* OnlineSubsystem = GetOnlineSubsystemForWorld(GetWorld());
	SessionInterface = OnlineSubsystem ? OnlineSubsystem->GetSessionInterface() : nullptr;
	if (!SessionInterface.IsValid() || SessionInterface->GetNamedSession(GameSessionName) == nullptr)
	{
		BroadcastImmediateFailure(TEXT("There is no local session to leave."));
		return;
	}

	StartDestroyOperation(
		true,
		true,
		TEXT("Session left; disconnect and return-to-menu requested."),
		TEXT("The online subsystem could not destroy the session."));
}

void UMulticaOnlineSessionSubsystem::BeginOperation(const EOperation Operation, const float TimeoutSeconds)
{
	UWorld* World = GetWorld();
	if (!World)
	{
		BroadcastImmediateFailure(TEXT("A world is required to run a bounded session operation."));
		return;
	}

	ActiveOperation = Operation;
	bOperationPending = true;
	bOperationTimedOut = false;
	PendingTimeoutSeconds = FMath::Clamp(TimeoutSeconds, 3.0f, 60.0f);
	World->GetTimerManager().SetTimer(
		TimeoutHandle, this, &ThisClass::HandleOperationTimeout, PendingTimeoutSeconds, false);
}

void UMulticaOnlineSessionSubsystem::FinishOperation(const bool bSucceeded, const FString& Message)
{
	if (!bOperationPending)
	{
		return;
	}

	if (UWorld* World = GetWorld())
	{
		World->GetTimerManager().ClearTimer(TimeoutHandle);
	}
	ActiveOperation = EOperation::None;
	bOperationPending = false;
	bOperationTimedOut = false;
	bReturnToMenuAfterDestroy = false;
	bDestroyOperationCanSucceed = true;
	PendingDestroySuccessMessage.Reset();
	PendingDestroyFailureMessage.Reset();
	OnOperationCompleted.Broadcast(bSucceeded, Message);
}

void UMulticaOnlineSessionSubsystem::HandleOperationTimeout()
{
	if (!bOperationPending)
	{
		return;
	}

	bOperationPending = false;
	bOperationTimedOut = true;
	if (ActiveOperation == EOperation::Find && SessionInterface.IsValid())
	{
		SessionInterface->CancelFindSessions();
		if (FindHandle.IsValid()) SessionInterface->ClearOnFindSessionsCompleteDelegate_Handle(FindHandle);
		FindHandle.Reset();
		ActiveOperation = EOperation::None;
		bOperationTimedOut = false;
	}
	OnOperationCompleted.Broadcast(false, FString::Printf(TEXT("Session operation timed out after %.0f seconds."), PendingTimeoutSeconds));
}

void UMulticaOnlineSessionSubsystem::BroadcastImmediateFailure(const FString& Message)
{
	OnOperationCompleted.Broadcast(false, Message);
}

void UMulticaOnlineSessionSubsystem::StartDestroyOperation(
	const bool bReturnToMenu,
	const bool bOperationSucceededAfterDestroy,
	const FString& SuccessMessage,
	const FString& FailureMessage)
{
	UWorld* World = GetWorld();
	if (World)
	{
		World->GetTimerManager().ClearTimer(TimeoutHandle);
	}

	ActiveOperation = EOperation::Destroy;
	bOperationPending = true;
	bOperationTimedOut = false;
	bReturnToMenuAfterDestroy = bReturnToMenu;
	bDestroyOperationCanSucceed = bOperationSucceededAfterDestroy;
	PendingDestroySuccessMessage = SuccessMessage;
	PendingDestroyFailureMessage = FailureMessage;
	PendingTimeoutSeconds = 15.0f;

	if (!World || !SessionInterface.IsValid())
	{
		FinishDestroyOperation(false);
		return;
	}

	World->GetTimerManager().SetTimer(
		TimeoutHandle, this, &ThisClass::HandleOperationTimeout, PendingTimeoutSeconds, false);
	DestroyHandle = SessionInterface->AddOnDestroySessionCompleteDelegate_Handle(
		FOnDestroySessionCompleteDelegate::CreateUObject(this, &ThisClass::HandleDestroyCompleted));
	if (!SessionInterface->DestroySession(GameSessionName))
	{
		SessionInterface->ClearOnDestroySessionCompleteDelegate_Handle(DestroyHandle);
		DestroyHandle.Reset();
		FinishDestroyOperation(false);
	}
}

void UMulticaOnlineSessionSubsystem::FinishDestroyOperation(const bool bWasSuccessful)
{
	if (ActiveOperation != EOperation::Destroy)
	{
		return;
	}

	if (bOperationTimedOut)
	{
		bOperationTimedOut = false;
		bOperationPending = true;
	}
	if (!bOperationPending)
	{
		return;
	}

	bool bOperationSucceeded = bWasSuccessful && bDestroyOperationCanSucceed;
	FString Message = bWasSuccessful ? PendingDestroySuccessMessage : PendingDestroyFailureMessage;
	if (bWasSuccessful && bReturnToMenuAfterDestroy)
	{
		UWorld* World = GetWorld();
		if (GEngine && World)
		{
			GEngine->HandleDisconnect(World, World->GetNetDriver());
		}
		else
		{
			bOperationSucceeded = false;
			Message = PendingDestroyFailureMessage;
		}
	}

	FinishOperation(bOperationSucceeded, Message);
}

void UMulticaOnlineSessionSubsystem::HandleCreateCompleted(FName SessionName, const bool bWasSuccessful)
{
	if (SessionName != GameSessionName)
	{
		return;
	}
	if (SessionInterface.IsValid() && CreateHandle.IsValid())
	{
		SessionInterface->ClearOnCreateSessionCompleteDelegate_Handle(CreateHandle);
	}
	CreateHandle.Reset();
	if (bOperationTimedOut)
	{
		if (bWasSuccessful)
		{
			StartDestroyOperation(
				false,
				false,
				TEXT("The timed-out create completed late; its session has been removed."),
				TEXT("The timed-out create completed late and its session could not be removed."));
		}
		else
		{
			bOperationTimedOut = false;
			ActiveOperation = EOperation::None;
		}
		return;
	}
	if (!bOperationPending || ActiveOperation != EOperation::Create)
	{
		return;
	}
	if (!bWasSuccessful)
	{
		FinishOperation(false, TEXT("The online subsystem could not create the LAN session."));
		return;
	}

	UWorld* World = GetWorld();
	FString ListenURL = PendingMapPackagePath;
	if (!ListenURL.Contains(TEXT("?listen"))) ListenURL += TEXT("?listen");
	if (!World || !World->ServerTravel(ListenURL, true))
	{
		StartDestroyOperation(
			false,
			false,
			TEXT("Listen-server travel failed; the created session was removed."),
			TEXT("Listen-server travel failed and the created session could not be removed."));
		return;
	}
	FinishOperation(true, TEXT("LAN session created; listen-server travel requested."));
}

void UMulticaOnlineSessionSubsystem::HandleFindCompleted(const bool bWasSuccessful)
{
	if (SessionInterface.IsValid() && FindHandle.IsValid())
	{
		SessionInterface->ClearOnFindSessionsCompleteDelegate_Handle(FindHandle);
	}
	FindHandle.Reset();
	if (bOperationTimedOut)
	{
		bOperationTimedOut = false;
		return;
	}
	if (!bOperationPending || ActiveOperation != EOperation::Find)
	{
		return;
	}
	if (!bWasSuccessful || !SessionSearch.IsValid())
	{
		FinishOperation(false, TEXT("LAN search failed or found no advertised session."));
		return;
	}
	FString ProjectIdentifier;
	if (!MulticaOnlineSessionIdentity::TryGetConfiguredProjectIdentifier(ProjectIdentifier))
	{
		FinishOperation(false, TEXT("The generated project has no valid MulticaOnlineStarter SessionProjectIdentifier; regenerate it with the scaffold tool."));
		return;
	}

	const FOnlineSessionSearchResult* MatchingSession = SessionSearch->SearchResults.FindByPredicate(
		[ProjectIdentifier](const FOnlineSessionSearchResult& SearchResult)
		{
			return MulticaOnlineSessionIdentity::MatchesProjectIdentifier(SearchResult, ProjectIdentifier);
		});
	if (!MatchingSession)
	{
		FinishOperation(false, TEXT("LAN search found no session for this project."));
		return;
	}

	ActiveOperation = EOperation::Join;
	JoinHandle = SessionInterface->AddOnJoinSessionCompleteDelegate_Handle(
		FOnJoinSessionCompleteDelegate::CreateUObject(this, &ThisClass::HandleJoinCompleted));
	if (!SessionInterface->JoinSession(0, GameSessionName, *MatchingSession))
	{
		SessionInterface->ClearOnJoinSessionCompleteDelegate_Handle(JoinHandle);
		JoinHandle.Reset();
		FinishOperation(false, TEXT("JoinSession was rejected by the selected subsystem."));
		return;
	}
	if (UWorld* World = GetWorld())
	{
		World->GetTimerManager().SetTimer(
			TimeoutHandle, this, &ThisClass::HandleOperationTimeout, PendingTimeoutSeconds, false);
	}
}

void UMulticaOnlineSessionSubsystem::HandleJoinCompleted(FName SessionName, const EOnJoinSessionCompleteResult::Type Result)
{
	if (SessionName != GameSessionName)
	{
		return;
	}
	if (SessionInterface.IsValid() && JoinHandle.IsValid())
	{
		SessionInterface->ClearOnJoinSessionCompleteDelegate_Handle(JoinHandle);
	}
	JoinHandle.Reset();
	if (bOperationTimedOut)
	{
		if (Result == EOnJoinSessionCompleteResult::Success)
		{
			StartDestroyOperation(
				false,
				false,
				TEXT("The timed-out join completed late; its session has been removed."),
				TEXT("The timed-out join completed late and its session could not be removed."));
		}
		else
		{
			bOperationTimedOut = false;
			ActiveOperation = EOperation::None;
		}
		return;
	}
	if (!bOperationPending || ActiveOperation != EOperation::Join)
	{
		return;
	}
	if (Result != EOnJoinSessionCompleteResult::Success)
	{
		FinishOperation(false, TEXT("The LAN session could not be joined."));
		return;
	}

	FString ConnectString;
	APlayerController* PlayerController = GetWorld() ? GetWorld()->GetFirstPlayerController() : nullptr;
	if (!SessionInterface->GetResolvedConnectString(SessionName, ConnectString) || !PlayerController)
	{
		StartDestroyOperation(
			false,
			false,
			TEXT("The join had no connect string or player controller; the session was removed."),
			TEXT("The join had no connect string or player controller, and session cleanup failed."));
		return;
	}
	PlayerController->ClientTravel(ConnectString, TRAVEL_Absolute);
	FinishOperation(true, TEXT("LAN session joined; client travel requested."));
}

void UMulticaOnlineSessionSubsystem::HandleDestroyCompleted(FName SessionName, const bool bWasSuccessful)
{
	if (SessionName != GameSessionName)
	{
		return;
	}
	if (SessionInterface.IsValid() && DestroyHandle.IsValid())
	{
		SessionInterface->ClearOnDestroySessionCompleteDelegate_Handle(DestroyHandle);
	}
	DestroyHandle.Reset();
	FinishDestroyOperation(bWasSuccessful);
}
