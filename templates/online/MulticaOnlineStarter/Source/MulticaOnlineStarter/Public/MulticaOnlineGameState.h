#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameStateBase.h"
#include "MulticaOnlineGameState.generated.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FMulticaReplicatedIntChanged, int32, NewValue);

UCLASS()
class MULTICAONLINESTARTER_API AMulticaOnlineGameState : public AGameStateBase
{
	GENERATED_BODY()

public:
	UPROPERTY(BlueprintAssignable, Category = "Online|State")
	FMulticaReplicatedIntChanged OnSampleScoreChanged;

	UPROPERTY(BlueprintAssignable, Category = "Online|State")
	FMulticaReplicatedIntChanged OnConnectedPlayerCountChanged;

	UFUNCTION(BlueprintPure, Category = "Online|State")
	int32 GetSampleScore() const { return SampleScore; }

	UFUNCTION(BlueprintPure, Category = "Online|State")
	int32 GetConnectedPlayerCount() const { return ConnectedPlayerCount; }

	void SetSampleScoreFromServer(int32 NewValue);
	void SetConnectedPlayerCountFromServer(int32 NewValue);

	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

protected:
	UPROPERTY(ReplicatedUsing = OnRep_SampleScore, BlueprintReadOnly, Category = "Online|State")
	int32 SampleScore = 0;

	UPROPERTY(ReplicatedUsing = OnRep_ConnectedPlayerCount, BlueprintReadOnly, Category = "Online|State")
	int32 ConnectedPlayerCount = 0;

	UFUNCTION()
	void OnRep_SampleScore();

	UFUNCTION()
	void OnRep_ConnectedPlayerCount();
};
