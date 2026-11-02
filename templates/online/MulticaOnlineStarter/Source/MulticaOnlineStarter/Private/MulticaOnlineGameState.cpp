#include "MulticaOnlineGameState.h"

#include "Net/UnrealNetwork.h"

void AMulticaOnlineGameState::SetSampleScoreFromServer(const int32 NewValue)
{
	if (!HasAuthority() || SampleScore == NewValue)
	{
		return;
	}

	SampleScore = NewValue;
	ForceNetUpdate();
	OnRep_SampleScore();
}

void AMulticaOnlineGameState::SetConnectedPlayerCountFromServer(const int32 NewValue)
{
	if (!HasAuthority() || ConnectedPlayerCount == NewValue)
	{
		return;
	}

	ConnectedPlayerCount = FMath::Max(0, NewValue);
	ForceNetUpdate();
	OnRep_ConnectedPlayerCount();
}

void AMulticaOnlineGameState::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);
	DOREPLIFETIME(AMulticaOnlineGameState, SampleScore);
	DOREPLIFETIME(AMulticaOnlineGameState, ConnectedPlayerCount);
}

void AMulticaOnlineGameState::OnRep_SampleScore()
{
	OnSampleScoreChanged.Broadcast(SampleScore);
	UE_LOG(LogTemp, Display, TEXT("DOT-2959 sample score replicated: %d (authority=%s)"),
		SampleScore, HasAuthority() ? TEXT("true") : TEXT("false"));
}

void AMulticaOnlineGameState::OnRep_ConnectedPlayerCount()
{
	OnConnectedPlayerCountChanged.Broadcast(ConnectedPlayerCount);
	UE_LOG(LogTemp, Display, TEXT("DOT-2959 connected players replicated: %d (authority=%s)"),
		ConnectedPlayerCount, HasAuthority() ? TEXT("true") : TEXT("false"));
}
