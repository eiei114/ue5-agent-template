#pragma once

#include "CoreMinimal.h"
#include "UObject/Object.h"

#include "MulticaOnlineTestLifetimeMarker.generated.h"

// A concrete UObject used only by the automation tests: a weak-lambda delegate needs a real
// (non-abstract) UObject to bind to, and UObject itself is abstract.
UCLASS()
class UMulticaOnlineTestLifetimeMarker : public UObject
{
	GENERATED_BODY()
};
