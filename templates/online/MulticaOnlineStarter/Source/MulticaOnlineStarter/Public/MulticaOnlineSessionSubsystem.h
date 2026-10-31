#pragma once

#include "CoreMinimal.h"
#include "Interfaces/OnlineSessionInterface.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "MulticaOnlineSessionSubsystem.generated.h"

class FOnlineSessionSearch;

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FMulticaOnlineSessionCompleted, bool, bSucceeded, FString, Message);

UCLASS()
class MULTICAONLINESTARTER_API UMulticaOnlineSessionSubsystem : public UGameInstanceSubsystem
{
	GENERATED_BODY()

public:
	UPROPERTY(BlueprintAssignable, Category = "Online|Sessions")
	FMulticaOnlineSessionCompleted OnOperationCompleted;

	UFUNCTION(BlueprintCallable, Category = "Online|Sessions")
	void HostListenServer(const FString& MapPackagePath, int32 MaxPlayers = 4, float TimeoutSeconds = 15.0f);

	UFUNCTION(BlueprintCallable, Category = "Online|Sessions")
	void FindAndJoinFirstLanSession(float TimeoutSeconds = 15.0f);

	UFUNCTION(BlueprintCallable, Category = "Online|Sessions")
	void LeaveSession();

	virtual void Deinitialize() override;

private:
	enum class EOperation : uint8
	{
		None,
		Create,
		Find,
		Join,
		Destroy
	};

	IOnlineSessionPtr SessionInterface;
	TSharedPtr<FOnlineSessionSearch> SessionSearch;
	FDelegateHandle CreateHandle;
	FDelegateHandle FindHandle;
	FDelegateHandle JoinHandle;
	FDelegateHandle DestroyHandle;
	FTimerHandle TimeoutHandle;
	EOperation ActiveOperation = EOperation::None;
	bool bOperationPending = false;
	bool bOperationTimedOut = false;
	FString PendingMapPackagePath;
	float PendingTimeoutSeconds = 15.0f;

	void BeginOperation(EOperation Operation, float TimeoutSeconds);
	void FinishOperation(bool bSucceeded, const FString& Message);
	void HandleOperationTimeout();
	void BroadcastImmediateFailure(const FString& Message);

	void HandleCreateCompleted(FName SessionName, bool bWasSuccessful);
	void HandleFindCompleted(bool bWasSuccessful);
	void HandleJoinCompleted(FName SessionName, EOnJoinSessionCompleteResult::Type Result);
	void HandleDestroyCompleted(FName SessionName, bool bWasSuccessful);
};
