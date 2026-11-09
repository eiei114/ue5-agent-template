#if WITH_DEV_AUTOMATION_TESTS

#include "Misc/AutomationTest.h"
#include "MulticaOnlineSessionIdentity.h"

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FMulticaOnlineSessionIdentityTest,
	"Multica.Online.SessionIdentity",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FMulticaOnlineSessionIdentityTest::RunTest(const FString& Parameters)
{
	(void)Parameters;
	const FString ProjectA(TEXT("eiei114.ue5-agent-template:EmberWatch"));
	const FString ProjectB(TEXT("eiei114.ue5-agent-template:NightMarket"));
	const FString ProjectCaseVariant(TEXT("eiei114.ue5-agent-template:emberwatch"));
	FString ResolvedIdentifier;

	TestTrue(TEXT("a generated project identifier is accepted"),
		MulticaOnlineSessionIdentity::TryResolveProjectIdentifier(ProjectA, ResolvedIdentifier));
	TestEqual(TEXT("the configured project identifier is preserved"), ResolvedIdentifier, ProjectA);
	FString RuntimeConfiguredIdentifier;
	TestTrue(TEXT("the generated plugin config is visible through the active engine config"),
		MulticaOnlineSessionIdentity::TryGetConfiguredProjectIdentifier(RuntimeConfiguredIdentifier));
	TestTrue(TEXT("the active engine config contains a valid generated identifier"),
		MulticaOnlineSessionIdentity::IsValidProjectIdentifier(RuntimeConfiguredIdentifier));
	TestFalse(TEXT("a missing project identifier fails closed"),
		MulticaOnlineSessionIdentity::TryResolveProjectIdentifier(FString(), ResolvedIdentifier));
	TestTrue(TEXT("a missing identifier leaves no fallback value"), ResolvedIdentifier.IsEmpty());
	TestFalse(TEXT("a malformed project identifier fails closed"),
		MulticaOnlineSessionIdentity::TryResolveProjectIdentifier(TEXT("TP_FirstPerson"), ResolvedIdentifier));
	TestFalse(TEXT("unsupported characters fail validation"),
		MulticaOnlineSessionIdentity::IsValidProjectIdentifier(TEXT("eiei114.ue5-agent-template:Bad/Key")));

	FOnlineSessionSearchResult MatchingSession;
	MatchingSession.Session.SessionSettings.Set(
		FName(MulticaOnlineSessionIdentity::SessionSettingName),
		ProjectA,
		EOnlineDataAdvertisementType::ViaOnlineServiceAndPing);
	TestTrue(TEXT("a session advertising the same project identifier is accepted"),
		MulticaOnlineSessionIdentity::MatchesProjectIdentifier(MatchingSession, ProjectA));
	TestFalse(TEXT("a session advertising a different project identifier is rejected"),
		MulticaOnlineSessionIdentity::MatchesProjectIdentifier(MatchingSession, ProjectB));
	TestFalse(TEXT("project identifiers are compared case-sensitively"),
		MulticaOnlineSessionIdentity::MatchesProjectIdentifier(MatchingSession, ProjectCaseVariant));

	FOnlineSessionSearchResult MissingIdentifierSession;
	TestFalse(TEXT("a session without an advertised identifier is rejected"),
		MulticaOnlineSessionIdentity::MatchesProjectIdentifier(MissingIdentifierSession, ProjectA));
	return true;
}

#endif
