#pragma once

#include "CoreMinimal.h"
#include "GameFramework/PlayerController.h"
#include "MulticaOnlinePlayerController.generated.h"

UCLASS()
class MULTICAONLINESTARTER_API AMulticaOnlinePlayerController : public APlayerController
{
	GENERATED_BODY()

public:
	UFUNCTION(BlueprintCallable, Category = "Online|Example")
	void RequestSampleScoreIncrement(int32 Amount = 1);

	UFUNCTION(Exec)
	void MulticaRequestScoreIncrement(int32 Amount);

protected:
	UFUNCTION(Server, Reliable)
	void ServerRequestSampleScoreIncrement(int32 Amount);
};
