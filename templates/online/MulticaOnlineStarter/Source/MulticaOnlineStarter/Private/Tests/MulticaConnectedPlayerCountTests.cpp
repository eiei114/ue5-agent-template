#if WITH_DEV_AUTOMATION_TESTS

#include "Misc/AutomationTest.h"
#include "MulticaConnectedPlayerCount.h"

namespace
{
	FMulticaConnectedPlayerView MakePlayer()
	{
		FMulticaConnectedPlayerView View;
		View.bHasPlayerState = true;
		View.bSpectatorOnly = false;
		View.bIsExiting = false;
		return View;
	}

	FMulticaConnectedPlayerView MakeSpectator()
	{
		FMulticaConnectedPlayerView View = MakePlayer();
		View.bSpectatorOnly = true;
		return View;
	}

	FMulticaConnectedPlayerView MakeExitingPlayer()
	{
		FMulticaConnectedPlayerView View = MakePlayer();
		View.bIsExiting = true;
		return View;
	}

	FMulticaConnectedPlayerView MakeExitingSpectator()
	{
		FMulticaConnectedPlayerView View = MakeSpectator();
		View.bIsExiting = true;
		return View;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FMulticaConnectedPlayerCountTest,
	"Multica.Online.PlayerCount.Connected",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FMulticaConnectedPlayerCountTest::RunTest(const FString& Parameters)
{
	(void)Parameters;

	// Single-player host before anyone joins.
	TestEqual(TEXT("nobody connected counts zero"),
		MulticaConnectedPlayerCount::CountPlayers(TArray<FMulticaConnectedPlayerView>()), 0);

	// Host only.
	{
		TArray<FMulticaConnectedPlayerView> Controllers;
		Controllers.Add(MakePlayer());
		TestEqual(TEXT("one connected player counts one"),
			MulticaConnectedPlayerCount::CountPlayers(Controllers), 1);
	}

	// Host plus a client: the join path publishes 2.
	{
		TArray<FMulticaConnectedPlayerView> Controllers;
		Controllers.Add(MakePlayer());
		Controllers.Add(MakePlayer());
		TestEqual(TEXT("two connected players count two"),
			MulticaConnectedPlayerCount::CountPlayers(Controllers), 2);
	}

	// The leave case this defect is about. At Logout time the departing controller is still in the
	// world's controller list with its PlayerState intact (the engine removes it afterwards), so
	// counting what the world contains still yields the pre-leave number. Nothing has to change:
	// the list here is exactly what the engine offers during Logout.
	{
		TArray<FMulticaConnectedPlayerView> Controllers;
		Controllers.Add(MakePlayer());
		Controllers.Add(MakeExitingPlayer());
		TestEqual(TEXT("the leaving controller is not counted again"),
			MulticaConnectedPlayerCount::CountPlayers(Controllers), 1);

		// The same world contents counted without the exclusion flag reproduce the pre-fix
		// behaviour: the value does not move on leave, which is what every client saw before this
		// change.
		TArray<FMulticaConnectedPlayerView> PreFixView;
		PreFixView.Add(MakePlayer());
		PreFixView.Add(MakePlayer());
		TestEqual(TEXT("counting everything present reproduces the pre-fix non-decrement"),
			MulticaConnectedPlayerCount::CountPlayers(PreFixView), 2);
		TestTrue(TEXT("the fixed count is strictly smaller than the pre-fix count for the same leave"),
			MulticaConnectedPlayerCount::CountPlayers(Controllers) < MulticaConnectedPlayerCount::CountPlayers(PreFixView));
	}

	// Last player leaves: the count has to fall to zero rather than stay at one.
	{
		TArray<FMulticaConnectedPlayerView> Controllers;
		Controllers.Add(MakeExitingPlayer());
		TestEqual(TEXT("a sole leaving player leaves zero connected"),
			MulticaConnectedPlayerCount::CountPlayers(Controllers), 0);
	}

	// A controller that is only a spectator was never part of the count, so a leaving spectator
	// must not subtract one from the remaining players.
	{
		TArray<FMulticaConnectedPlayerView> Controllers;
		Controllers.Add(MakePlayer());
		Controllers.Add(MakePlayer());
		Controllers.Add(MakeSpectator());
		TestEqual(TEXT("spectator-only controllers are excluded"),
			MulticaConnectedPlayerCount::CountPlayers(Controllers), 2);

		TArray<FMulticaConnectedPlayerView> LeavingSpectator;
		LeavingSpectator.Add(MakePlayer());
		LeavingSpectator.Add(MakePlayer());
		LeavingSpectator.Add(MakeExitingSpectator());
		TestEqual(TEXT("a leaving spectator does not subtract a real player"),
			MulticaConnectedPlayerCount::CountPlayers(LeavingSpectator), 2);
	}

	// A controller without a PlayerState is not a player, matching the engine predicate.
	{
		TArray<FMulticaConnectedPlayerView> Controllers;
		FMulticaConnectedPlayerView NoPlayerState;
		NoPlayerState.bHasPlayerState = false;
		Controllers.Add(MakePlayer());
		Controllers.Add(NoPlayerState);
		TestEqual(TEXT("a controller without a PlayerState is not counted"),
			MulticaConnectedPlayerCount::CountPlayers(Controllers), 1);
	}

	// An empty slot (a null controller the world has not cleaned up yet) is not a player either.
	{
		TArray<FMulticaConnectedPlayerView> Controllers;
		Controllers.Add(MakePlayer());
		Controllers.Add(FMulticaConnectedPlayerView());
		TestEqual(TEXT("an empty controller slot is not counted"),
			MulticaConnectedPlayerCount::CountPlayers(Controllers), 1);
	}

	return true;
}

#endif // WITH_DEV_AUTOMATION_TESTS
