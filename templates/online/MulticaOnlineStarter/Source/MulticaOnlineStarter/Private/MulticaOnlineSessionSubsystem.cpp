#include "MulticaOnlineSessionSubsystem.h"

#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "OnlineSessionSettings.h"
#include "OnlineSubsystem.h"
#include "TimerManager.h"

namespace
{
	const FName GameSessionName(TEXT("GameSession"));
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
		if (CreateHandle.IsValid()) SessionInterface->ClearOnCreateSessionCompleteDelegate_Handle(CreateHandle);
		if (FindHandle.IsValid()) SessionInterface->ClearOnFindSessionsCompleteDelegate_Handle(FindHandle);
		if (JoinHandle.IsValid()) SessionInterface->ClearOnJoinSessionCompleteDelegate_Handle(JoinHandle);
		if (DestroyHandle.IsValid()) SessionInterface->ClearOnDestroySessionCompleteDelegate_Handle(DestroyHandle);
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

	IOnlineSubsystem* OnlineSubsystem = IOnlineSubsystem::Get();
	SessionInterface = OnlineSubsystem ? OnlineSubsystem->GetSessionInterface() : nullptr;
	if (!SessionInterface.IsValid())
	{
		BroadcastImmediateFailure(TEXT("The selected online subsystem has no session interface."));
		return;
	}
	if (SessionInterface->GetNamedSession(GameSessionName) != nullptr)
	{
		BroadcastImmediateFailure(TEXT("A local session already exists; leave it before hosting again."));
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

	IOnlineSubsystem* OnlineSubsystem = IOnlineSubsystem::Get();
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

	IOnlineSubsystem* OnlineSubsystem = IOnlineSubsystem::Get();
	SessionInterface = OnlineSubsystem ? OnlineSubsystem->GetSessionInterface() : nullptr;
	if (!SessionInterface.IsValid() || SessionInterface->GetNamedSession(GameSessionName) == nullptr)
	{
		BroadcastImmediateFailure(TEXT("There is no local session to leave."));
		return;
	}

	BeginOperation(EOperation::Destroy, 15.0f);
	if (!bOperationPending)
	{
		return;
	}

	DestroyHandle = SessionInterface->AddOnDestroySessionCompleteDelegate_Handle(
		FOnDestroySessionCompleteDelegate::CreateUObject(this, &ThisClass::HandleDestroyCompleted));
	if (!SessionInterface->DestroySession(GameSessionName))
	{
		SessionInterface->ClearOnDestroySessionCompleteDelegate_Handle(DestroyHandle);
		DestroyHandle.Reset();
		FinishOperation(false, TEXT("DestroySession was rejected by the selected subsystem."));
	}
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

void UMulticaOnlineSessionSubsystem::HandleCreateCompleted(FName SessionName, const bool bWasSuccessful)
{
	if (SessionInterface.IsValid() && CreateHandle.IsValid())
	{
		SessionInterface->ClearOnCreateSessionCompleteDelegate_Handle(CreateHandle);
	}
	CreateHandle.Reset();
	if (bOperationTimedOut)
	{
		bOperationTimedOut = false;
		ActiveOperation = EOperation::None;
		if (bWasSuccessful && SessionInterface.IsValid()) SessionInterface->DestroySession(SessionName);
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
		SessionInterface->DestroySession(SessionName);
		FinishOperation(false, TEXT("The session was created, but the listen-server map travel failed."));
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
	if (!bWasSuccessful || !SessionSearch.IsValid() || SessionSearch->SearchResults.IsEmpty())
	{
		FinishOperation(false, TEXT("LAN search failed or found no advertised session."));
		return;
	}

	ActiveOperation = EOperation::Join;
	JoinHandle = SessionInterface->AddOnJoinSessionCompleteDelegate_Handle(
		FOnJoinSessionCompleteDelegate::CreateUObject(this, &ThisClass::HandleJoinCompleted));
	if (!SessionInterface->JoinSession(0, GameSessionName, SessionSearch->SearchResults[0]))
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
	if (SessionInterface.IsValid() && JoinHandle.IsValid())
	{
		SessionInterface->ClearOnJoinSessionCompleteDelegate_Handle(JoinHandle);
	}
	JoinHandle.Reset();
	if (bOperationTimedOut)
	{
		bOperationTimedOut = false;
		ActiveOperation = EOperation::None;
		if (Result == EOnJoinSessionCompleteResult::Success && SessionInterface.IsValid()) SessionInterface->DestroySession(SessionName);
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
		SessionInterface->DestroySession(SessionName);
		FinishOperation(false, TEXT("The session joined, but no connect string or local player controller was available."));
		return;
	}
	PlayerController->ClientTravel(ConnectString, TRAVEL_Absolute);
	FinishOperation(true, TEXT("LAN session joined; client travel requested."));
}

void UMulticaOnlineSessionSubsystem::HandleDestroyCompleted(FName SessionName, const bool bWasSuccessful)
{
	if (SessionInterface.IsValid() && DestroyHandle.IsValid())
	{
		SessionInterface->ClearOnDestroySessionCompleteDelegate_Handle(DestroyHandle);
	}
	DestroyHandle.Reset();
	if (bOperationTimedOut)
	{
		bOperationTimedOut = false;
		ActiveOperation = EOperation::None;
		return;
	}
	if (!bOperationPending || ActiveOperation != EOperation::Destroy)
	{
		return;
	}
	FinishOperation(bWasSuccessful, bWasSuccessful ? TEXT("Session left.") : TEXT("The online subsystem could not destroy the session."));
}
