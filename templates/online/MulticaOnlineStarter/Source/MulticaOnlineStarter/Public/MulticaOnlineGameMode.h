#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "MulticaOnlineGameMode.generated.h"

UCLASS()
class MULTICAONLINESTARTER_API AMulticaOnlineGameMode : public AGameModeBase
{
	GENERATED_BODY()

public:
	AMulticaOnlineGameMode();

	virtual void PostLogin(APlayerController* NewPlayer) override;
	virtual void Logout(AController* Exiting) override;

private:
	void RefreshConnectedPlayerCount();
};
