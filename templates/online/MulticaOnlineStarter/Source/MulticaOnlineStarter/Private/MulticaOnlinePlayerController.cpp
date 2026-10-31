#include "MulticaOnlinePlayerController.h"

#include "MulticaOnlineGameState.h"

void AMulticaOnlinePlayerController::RequestSampleScoreIncrement(const int32 Amount)
{
	const int32 SafeAmount = FMath::Clamp(Amount, 1, 5);
	if (HasAuthority())
	{
		ServerRequestSampleScoreIncrement_Implementation(SafeAmount);
	}
	else if (IsLocalController())
	{
		ServerRequestSampleScoreIncrement(SafeAmount);
	}
}

void AMulticaOnlinePlayerController::MulticaRequestScoreIncrement(const int32 Amount)
{
	RequestSampleScoreIncrement(Amount);
}

void AMulticaOnlinePlayerController::ServerRequestSampleScoreIncrement_Implementation(const int32 Amount)
{
	if (Amount < 1 || Amount > 5)
	{
		return;
	}

	if (AMulticaOnlineGameState* OnlineGameState = GetWorld() ? GetWorld()->GetGameState<AMulticaOnlineGameState>() : nullptr)
	{
		OnlineGameState->SetSampleScoreFromServer(OnlineGameState->GetSampleScore() + Amount);
	}
}
