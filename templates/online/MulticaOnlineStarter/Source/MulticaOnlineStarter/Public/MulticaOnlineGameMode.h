#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "MulticaOnlineGameMode.generated.h"

class AController;

UCLASS()
class MULTICAONLINESTARTER_API AMulticaOnlineGameMode : public AGameModeBase
{
	GENERATED_BODY()

public:
	AMulticaOnlineGameMode();

	virtual void PostLogin(APlayerController* NewPlayer) override;
	virtual void Logout(AController* Exiting) override;

private:
	void RefreshConnectedPlayerCount(const AController* ExcludedController);

	/** Number of non-spectator players in this world, optionally skipping one controller that is leaving. */
	int32 CountConnectedPlayers(const AController* ExcludedController) const;
};
