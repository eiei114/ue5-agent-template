#include "MulticaOnlineGameMode.h"

#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "GameFramework/PlayerState.h"
#include "MulticaConnectedPlayerCount.h"
#include "MulticaOnlineGameState.h"
#include "MulticaOnlinePlayerController.h"

AMulticaOnlineGameMode::AMulticaOnlineGameMode()
{
	PlayerControllerClass = AMulticaOnlinePlayerController::StaticClass();
	GameStateClass = AMulticaOnlineGameState::StaticClass();
}

void AMulticaOnlineGameMode::PostLogin(APlayerController* NewPlayer)
{
	Super::PostLogin(NewPlayer);

	// The joining controller is already in the world's controller list and owns a PlayerState by the
	// time PostLogin runs, so nothing has to be excluded here.
	RefreshConnectedPlayerCount(nullptr);
}

void AMulticaOnlineGameMode::Logout(AController* Exiting)
{
	Super::Logout(Exiting);

	// AController::Destroyed calls this before CleanupPlayerState and before
	// UWorld::RemoveController, so while Logout runs the departing controller is still in the world's
	// player-controller list and still owns a PlayerState. Any count of what the world currently
	// contains therefore still includes that player: calling the engine's GetNumPlayers() here
	// republishes the pre-leave number and the replicated count never falls. Publishing the count of
	// the players that remain, with Exiting skipped, is the post-leave value in this same call.
	RefreshConnectedPlayerCount(Exiting);
}

void AMulticaOnlineGameMode::RefreshConnectedPlayerCount(const AController* ExcludedController)
{
	if (AMulticaOnlineGameState* OnlineGameState = GetGameState<AMulticaOnlineGameState>())
	{
		OnlineGameState->SetConnectedPlayerCountFromServer(CountConnectedPlayers(ExcludedController));
	}
}

int32 AMulticaOnlineGameMode::CountConnectedPlayers(const AController* ExcludedController) const
{
	UWorld* World = GetWorld();
	if (!World)
	{
		return 0;
	}

	TArray<FMulticaConnectedPlayerView> Controllers;
	for (FConstPlayerControllerIterator Iterator = World->GetPlayerControllerIterator(); Iterator; ++Iterator)
	{
		APlayerController* const PlayerController = Iterator->Get();

		FMulticaConnectedPlayerView View;
		if (PlayerController)
		{
			View.bHasPlayerState = PlayerController->PlayerState != nullptr;
			View.bSpectatorOnly = MustSpectate(PlayerController);
			View.bIsExiting = PlayerController == ExcludedController;
		}
		Controllers.Add(View);
	}

	return MulticaConnectedPlayerCount::CountPlayers(Controllers);
}
