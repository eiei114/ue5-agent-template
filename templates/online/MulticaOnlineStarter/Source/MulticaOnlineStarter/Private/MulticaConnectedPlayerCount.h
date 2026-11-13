#pragma once

#include "CoreMinimal.h"

// The world's player-controller list is the only authority for "who is connected right now". This
// narrow surface states each controller's shape so the counting rule can be exercised without a
// UWorld, mirroring the FDeferredDestroySessionCleanupOperations pattern used for session cleanup.
struct FMulticaConnectedPlayerView
{
	/** True when the controller owns a PlayerState, which the engine player predicate requires. */
	bool bHasPlayerState = false;

	/** True when MustSpectate(Controller) is true, i.e. the controller is only a spectator. */
	bool bSpectatorOnly = false;

	/**
	 * True for the controller that Logout is currently handling. AController::Destroyed calls
	 * Logout while the departing controller is still in the list and still owns a PlayerState,
	 * so it must be skipped explicitly instead of being counted again (or subtracted afterwards).
	 */
	bool bIsExiting = false;
};

namespace MulticaConnectedPlayerCount
{
	/**
	 * Counts the controllers that are connected right now.
	 *
	 * The predicate is the engine's own (a live PlayerState and not spectator-only). The one
	 * addition is that a controller which is leaving is skipped rather than counted and then
	 * subtracted: a leaving spectator was never counted, so subtracting it would report one player
	 * fewer than the world holds.
	 */
	inline int32 CountPlayers(const TArray<FMulticaConnectedPlayerView>& Controllers)
	{
		int32 Players = 0;
		for (const FMulticaConnectedPlayerView& Controller : Controllers)
		{
			if (Controller.bIsExiting || !Controller.bHasPlayerState || Controller.bSpectatorOnly)
			{
				continue;
			}
			++Players;
		}
		return Players;
	}
}
