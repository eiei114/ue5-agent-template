#include "MulticaOnlineGameMode.h"

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
	RefreshConnectedPlayerCount();
}

void AMulticaOnlineGameMode::Logout(AController* Exiting)
{
	Super::Logout(Exiting);
	RefreshConnectedPlayerCount();
}

void AMulticaOnlineGameMode::RefreshConnectedPlayerCount()
{
	if (AMulticaOnlineGameState* OnlineGameState = GetGameState<AMulticaOnlineGameState>())
	{
		OnlineGameState->SetConnectedPlayerCountFromServer(GetNumPlayers());
	}
}
