import FiliconSettings

extension AppModel {
    var selectedProviderUsage: UsageCounters? {
        guard let conversation = selectedConversation else { return nil }
        let accountID = settings.accountScope ?? "local"
        return settings.usageByAccount[accountID]?.providers[conversation.providerID.rawValue]
    }
}
