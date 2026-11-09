#pragma once

#include "CoreMinimal.h"
#include "Misc/ConfigCacheIni.h"
#include "OnlineSessionSettings.h"

namespace MulticaOnlineSessionIdentity
{
	inline constexpr TCHAR ConfigSection[] = TEXT("MulticaOnlineStarter");
	inline constexpr TCHAR ConfigKey[] = TEXT("SessionProjectIdentifier");
	inline constexpr TCHAR SessionSettingName[] = TEXT("MulticaProjectIdentifier");
	inline constexpr TCHAR IdentifierPrefix[] = TEXT("eiei114.ue5-agent-template:");

	inline bool IsValidProjectIdentifier(const FString& Identifier)
	{
		const FString Prefix(IdentifierPrefix);
		if (!Identifier.StartsWith(Prefix, ESearchCase::CaseSensitive))
		{
			return false;
		}

		const FString ProjectKey = Identifier.RightChop(Prefix.Len());
		if (ProjectKey.IsEmpty() || ProjectKey.Len() > 40)
		{
			return false;
		}

		for (const TCHAR Character : ProjectKey)
		{
			if (!FChar::IsAlnum(Character) && Character != TEXT('_') && Character != TEXT('-'))
			{
				return false;
			}
		}
		return true;
	}

	inline bool TryResolveProjectIdentifier(const FString& ConfiguredIdentifier, FString& OutIdentifier)
	{
		if (!IsValidProjectIdentifier(ConfiguredIdentifier))
		{
			OutIdentifier.Reset();
			return false;
		}
		OutIdentifier = ConfiguredIdentifier;
		return true;
	}

	inline bool TryGetConfiguredProjectIdentifier(FString& OutIdentifier)
	{
		FString ConfiguredIdentifier;
		if (!GConfig || !GConfig->GetString(ConfigSection, ConfigKey, ConfiguredIdentifier, GEngineIni))
		{
			OutIdentifier.Reset();
			return false;
		}
		return TryResolveProjectIdentifier(ConfiguredIdentifier, OutIdentifier);
	}

	inline bool MatchesProjectIdentifier(const FOnlineSessionSearchResult& SearchResult, const FString& ExpectedIdentifier)
	{
		if (!IsValidProjectIdentifier(ExpectedIdentifier))
		{
			return false;
		}

		FString AdvertisedIdentifier;
		return SearchResult.Session.SessionSettings.Get(FName(SessionSettingName), AdvertisedIdentifier) &&
			IsValidProjectIdentifier(AdvertisedIdentifier) &&
			AdvertisedIdentifier.Equals(ExpectedIdentifier, ESearchCase::CaseSensitive);
	}
}
