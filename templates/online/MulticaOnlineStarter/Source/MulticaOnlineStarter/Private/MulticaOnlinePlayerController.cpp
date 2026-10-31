#include "MulticaOnlinePlayerController.h"

#include "MulticaOnlineGameState.h"

void AMulticaOnlinePlayerController::RequestSampleScoreIncrement(const int32 Amount)
{
	if (Amount < 1)
	{
		return;
	}

	const int32 SafeAmount = FMath::Min(Amount, 5);
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
		const int32 CurrentScore = OnlineGameState->GetSampleScore();
		const int32 NextScore = CurrentScore > MAX_int32 - Amount ? MAX_int32 : CurrentScore + Amount;
		OnlineGameState->SetSampleScoreFromServer(NextScore);
	}
}
