import Foundation

let parser = TranscriptParserTests()
runTest("parser.parsesEveryDecodableLine") { try parser.parsesEveryDecodableLine() }
runTest("parser.assistantEntryFields") { try parser.assistantEntryFields() }
runTest("parser.userEntries") { try parser.userEntries() }
runTest("parser.summarizeCapturesCwdBranchTokensAndCost") { try parser.summarizeCapturesCwdBranchTokensAndCost() }
runTest("parser.summarizeTracksCurrentModelAcrossEntries") { try parser.summarizeTracksCurrentModelAcrossEntries() }
runTest("parser.summarizePrefersCostUSDWhenPresent") { try parser.summarizePrefersCostUSDWhenPresent() }
runTest("parser.summarizeExtractsAskUserQuestionText") { try parser.summarizeExtractsAskUserQuestionText() }
runTest("parser.estimatesCurrentModelRatesAndCacheDurations") { try parser.estimatesCurrentModelRatesAndCacheDurations() }
runTest("parser.summarizeBillsOneHourCacheWritesAtDoubleInput") { try parser.summarizeBillsOneHourCacheWritesAtDoubleInput() }
runTest("parser.countsUsageOncePerMessageAcrossContentBlockEntries") { try parser.countsUsageOncePerMessageAcrossContentBlockEntries() }
runTest("parser.ignoresMalformedLines") { try parser.ignoresMalformedLines() }
runTest("parser.dayKeyIsLocalCalendarDay") { try parser.dayKeyIsLocalCalendarDay() }

runTest("adapter.recentUserMessageMeansWorking") { try ClaudeCodeAdapterTests().recentUserMessageMeansWorking() }
runTest("adapter.justArrivedToolResultMeansWorking") { try ClaudeCodeAdapterTests().justArrivedToolResultMeansWorking() }
runTest("adapter.longBashToolDoesNotNeedInput") { try ClaudeCodeAdapterTests().longBashToolDoesNotNeedInput() }
runTest("adapter.pendingToolCallWithinGraceIsWorking") { try ClaudeCodeAdapterTests().pendingToolCallWithinGraceIsWorking() }
runTest("adapter.askUserQuestionIsImmediatelyNeedsInputWithQuestionText") { try ClaudeCodeAdapterTests().askUserQuestionIsImmediatelyNeedsInputWithQuestionText() }
runTest("adapter.quietAssistantTextMeansFinished") { try ClaudeCodeAdapterTests().quietAssistantTextMeansFinished() }
runTest("adapter.quietToolResultMeansFinished") { try ClaudeCodeAdapterTests().quietToolResultMeansFinished() }
runTest("adapter.veryQuietToolResultMeansIdle") { try ClaudeCodeAdapterTests().veryQuietToolResultMeansIdle() }
runTest("adapter.veryQuietUserMessageMeansIdle") { try ClaudeCodeAdapterTests().veryQuietUserMessageMeansIdle() }
runTest("adapter.apiErrorMessageMeansErrored") { try ClaudeCodeAdapterTests().apiErrorMessageMeansErrored() }
runTest("adapter.capturesRepoBranchCostAndTokens") { try ClaudeCodeAdapterTests().capturesRepoBranchCostAndTokens() }
runTest("adapter.capturesCustomTitleAsSessionName") { try ClaudeCodeAdapterTests().capturesCustomTitleAsSessionName() }
runTest("adapter.fallsBackToFirstUserMessageForSessionName") { try ClaudeCodeAdapterTests().fallsBackToFirstUserMessageForSessionName() }
runTest("adapter.ignoresCommandEntriesForSessionName") { try ClaudeCodeAdapterTests().ignoresCommandEntriesForSessionName() }
runTest("adapter.usesSlashCommandArgumentsInsteadOfSkillInstructionsForSessionName") { try ClaudeCodeAdapterTests().usesSlashCommandArgumentsInsteadOfSkillInstructionsForSessionName() }
runTest("adapter.sortsNeedsInputFirst") { try ClaudeCodeAdapterTests().sortsNeedsInputFirst() }
runTest("adapter.skipsSessionsNotUsedToday") { try ClaudeCodeAdapterTests().skipsSessionsNotUsedToday() }
runTest("adapter.showsSessionsUsedTodayEvenAfterHoursIdle") { try ClaudeCodeAdapterTests().showsSessionsUsedTodayEvenAfterHoursIdle() }
runTest("adapter.skipsFilesWithoutConversation") { try ClaudeCodeAdapterTests().skipsFilesWithoutConversation() }
runTest("adapter.runningSubagentKeepsQuietParentWorking") { try ClaudeCodeAdapterTests().runningSubagentKeepsQuietParentWorking() }
runTest("adapter.finishedSubagentLetsQuietParentFinish") { try ClaudeCodeAdapterTests().finishedSubagentLetsQuietParentFinish() }
runTest("adapter.sessionsAreStableAcrossScansViaCache") { try ClaudeCodeAdapterTests().sessionsAreStableAcrossScansViaCache() }

runTest("pi.recentUserMessageMeansWorking") { try PiAdapterTests().recentUserMessageMeansWorking() }
runTest("pi.toolResultArrivedMeansWorking") { try PiAdapterTests().toolResultArrivedMeansWorking() }
runTest("pi.longBashToolDoesNotNeedInput") { try PiAdapterTests().longBashToolDoesNotNeedInput() }
runTest("pi.pendingToolCallWithinGraceIsWorking") { try PiAdapterTests().pendingToolCallWithinGraceIsWorking() }
runTest("pi.quietAssistantTextMeansFinished") { try PiAdapterTests().quietAssistantTextMeansFinished() }
runTest("pi.quietToolResultMeansFinished") { try PiAdapterTests().quietToolResultMeansFinished() }
runTest("pi.veryQuietToolResultMeansIdle") { try PiAdapterTests().veryQuietToolResultMeansIdle() }
runTest("pi.veryQuietUserMessageMeansIdle") { try PiAdapterTests().veryQuietUserMessageMeansIdle() }
runTest("pi.usesRealCostFromUsageAndCountsReasoningAsOutput") { try PiAdapterTests().usesRealCostFromUsageAndCountsReasoningAsOutput() }
runTest("pi.capturesModelFromAssistantAndModelChangeEntries") { try PiAdapterTests().capturesModelFromAssistantAndModelChangeEntries() }
runTest("pi.derivesSessionNameFromFirstUserMessage") { try PiAdapterTests().derivesSessionNameFromFirstUserMessage() }
runTest("pi.skipsSessionsNotUsedToday") { try PiAdapterTests().skipsSessionsNotUsedToday() }
runTest("pi.showsSessionsUsedTodayEvenAfterHoursIdle") { try PiAdapterTests().showsSessionsUsedTodayEvenAfterHoursIdle() }
runTest("pi.skipsChildSessionsPointingAtAParent") { try PiAdapterTests().skipsChildSessionsPointingAtAParent() }
runTest("pi.skipsExtensionChildSessionFile") { try PiAdapterTests().skipsExtensionChildSessionFile() }
runTest("pi.skipsHeaderOnlyFiles") { try PiAdapterTests().skipsHeaderOnlyFiles() }
runTest("pi.sessionsAreStableAcrossScansViaCache") { try PiAdapterTests().sessionsAreStableAcrossScansViaCache() }

runTest("codex.pendingToolCallWithinGraceIsWorking") { try CodexAdapterTests().pendingToolCallWithinGraceIsWorking() }
runTest("codex.longShellToolDoesNotNeedInput") { try CodexAdapterTests().longShellToolDoesNotNeedInput() }
runTest("codex.toolOutputThenAssistantMeansWorking") { try CodexAdapterTests().toolOutputThenAssistantMeansWorking() }
runTest("codex.quietAssistantTextMeansFinished") { try CodexAdapterTests().quietAssistantTextMeansFinished() }
runTest("codex.capturesCwdModelTokensAndCost") { try CodexAdapterTests().capturesCwdModelTokensAndCost() }
runTest("codex.idIsThreadIdFromSessionMeta") { try CodexAdapterTests().idIsThreadIdFromSessionMeta() }
runTest("codex.usesThreadNameFromIndexAsSessionName") { try CodexAdapterTests().usesThreadNameFromIndexAsSessionName() }
runTest("codex.fallsBackToFirstUserMessageForSessionName") { try CodexAdapterTests().fallsBackToFirstUserMessageForSessionName() }
runTest("codex.skipsSessionsNotUsedToday") { try CodexAdapterTests().skipsSessionsNotUsedToday() }
runTest("codex.asyncQuestionNeedsInputWhileAgentKeepsWorking") { try CodexAdapterTests().asyncQuestionNeedsInputWhileAgentKeepsWorking() }
runTest("codex.userReplyClearsAsyncQuestion") { try CodexAdapterTests().userReplyClearsAsyncQuestion() }
runTest("codex.taskCompleteMeansFinishedWithoutQuietWait") { try CodexAdapterTests().taskCompleteMeansFinishedWithoutQuietWait() }
runTest("codex.turnAbortedMeansIdle") { try CodexAdapterTests().turnAbortedMeansIdle() }
runTest("codex.capturesBranchFromSessionMeta") { try CodexAdapterTests().capturesBranchFromSessionMeta() }
runTest("codex.foldsChildThreadsIntoParent") { try CodexAdapterTests().foldsChildThreadsIntoParent() }
runTest("codex.mergesContinuationPagesOfOneThread") { try CodexAdapterTests().mergesContinuationPagesOfOneThread() }

runTest("opencode.userMessageMeansWorking") { try OpenCodeAdapterTests().userMessageMeansWorking() }
runTest("opencode.longPendingToolDoesNotNeedInput") { try OpenCodeAdapterTests().longPendingToolDoesNotNeedInput() }
runTest("opencode.assistantTextPartsMeanFinishedWhenQuiet") { try OpenCodeAdapterTests().assistantTextPartsMeanFinishedWhenQuiet() }
runTest("opencode.completedToolFollowedByTextMeansFinished") { try OpenCodeAdapterTests().completedToolFollowedByTextMeansFinished() }
runTest("opencode.runningToolStaysWorking") { try OpenCodeAdapterTests().runningToolStaysWorking() }
runTest("opencode.capturesTitleModelTokensCostAndCostToday") { try OpenCodeAdapterTests().capturesTitleModelTokensCostAndCostToday() }
runTest("opencode.countsTokensWithMissingOptionalFields") { try OpenCodeAdapterTests().countsTokensWithMissingOptionalFields() }
runTest("opencode.skipsSubagentAndArchivedSessions") { try OpenCodeAdapterTests().skipsSubagentAndArchivedSessions() }
runTest("opencode.skipsSessionsNotUsedToday") { try OpenCodeAdapterTests().skipsSessionsNotUsedToday() }
runTest("opencode.unionsLegacyRowsMissingFromV2") { try OpenCodeAdapterTests().unionsLegacyRowsMissingFromV2() }
runTest("opencode.handlesMissingDatabase") { try OpenCodeAdapterTests().handlesMissingDatabase() }

runTest("alerts.needsInputAlertsOnFirstSight") { try SessionNotificationsTests().needsInputAlertsOnFirstSight() }
runTest("alerts.finishedAndErroredSeedSilentlyOnFirstSight") { try SessionNotificationsTests().finishedAndErroredSeedSilentlyOnFirstSight() }
runTest("alerts.transitionIntoFinishedOrErroredAlerts") { try SessionNotificationsTests().transitionIntoFinishedOrErroredAlerts() }
runTest("alerts.sameStateDoesNotRepeat") { try SessionNotificationsTests().sameStateDoesNotRepeat() }
runTest("alerts.reentryAfterWorkingAlertsAgain") { try SessionNotificationsTests().reentryAfterWorkingAlertsAgain() }
runTest("alerts.quietStatesNeverAlert") { try SessionNotificationsTests().quietStatesNeverAlert() }
runTest("alerts.pendingToolBodyFallsBackToTool") { try SessionNotificationsTests().pendingToolBodyFallsBackToTool() }
runTest("alerts.identifierIsStablePerSessionAndState") { try SessionNotificationsTests().identifierIsStablePerSessionAndState() }

runTest("adapter.unansweredQuestionSurvivesMidnightWithTodayCostOnly") { try ClaudeCodeAdapterTests().unansweredQuestionSurvivesMidnightWithTodayCostOnly() }

runTest("ClaudeCodeAdapterTests.exitPlanModeDoesNotClaimPermissionWait") { try ClaudeCodeAdapterTests().exitPlanModeDoesNotClaimPermissionWait() }
runTest("ClaudeCodeAdapterTests.emptyQuestionIsNotInputEvidence") { try ClaudeCodeAdapterTests().emptyQuestionIsNotInputEvidence() }
runTest("ClaudeCodeAdapterTests.questionResultClearsWait") { try ClaudeCodeAdapterTests().questionResultClearsWait() }
runTest("ClaudeCodeAdapterTests.questionStaysOpenAfterSiblingToolResult") { try ClaudeCodeAdapterTests().questionStaysOpenAfterSiblingToolResult() }
runTest("ClaudeCodeAdapterTests.questionStaysOpenBehindLaterSiblingToolCall") { try ClaudeCodeAdapterTests().questionStaysOpenBehindLaterSiblingToolCall() }
runTest("ClaudeCodeAdapterTests.abandonedGenericToolBecomesIdle") { try ClaudeCodeAdapterTests().abandonedGenericToolBecomesIdle() }
runTest("CodexAdapterTests.explicitQuestionSurvivesMidnight") { try CodexAdapterTests().explicitQuestionSurvivesMidnight() }
runTest("CodexAdapterTests.explicitQuestionOutputClearsWait") { try CodexAdapterTests().explicitQuestionOutputClearsWait() }
runTest("CodexAdapterTests.emptyInputRequestIsNotQuestionEvidence") { try CodexAdapterTests().emptyInputRequestIsNotQuestionEvidence() }
runTest("OpenCodeAdapterTests.overnightRunningToolRemainsVisibleWithTodayCostOnly") { try OpenCodeAdapterTests().overnightRunningToolRemainsVisibleWithTodayCostOnly() }
runTest("OpenCodeAdapterTests.invalidSchemaReportsFailure") { try OpenCodeAdapterTests().invalidSchemaReportsFailure() }
runTest("OpenCodeAdapterTests.malformedSessionPreservesReadableSession") { try OpenCodeAdapterTests().malformedSessionPreservesReadableSession() }
runTest("OpenCodeAdapterTests.readableEmptyDatabaseIsHealthy") { try OpenCodeAdapterTests().readableEmptyDatabaseIsHealthy() }
runTest("ScanHealthTests.distinguishesMissingReadableEmptyAndFailedRoot") { try ScanHealthTests().distinguishesMissingReadableEmptyAndFailedRoot() }
runTest("ScanHealthTests.malformedCompleteRecordPreservesSessionAndIssueAcrossCache") { try ScanHealthTests().malformedCompleteRecordPreservesSessionAndIssueAcrossCache() }
runTest("ScanHealthTests.incompleteStreamingTailDoesNotMakeSourceFail") { try ScanHealthTests().incompleteStreamingTailDoesNotMakeSourceFail() }
runTest("ScanHealthTests.completedMalformedTailReportsIssueWithoutNewline") { try ScanHealthTests().completedMalformedTailReportsIssueWithoutNewline() }
runTest("ScanHealthTests.brokenTranscriptPreservesOtherReadableSessions") { try ScanHealthTests().brokenTranscriptPreservesOtherReadableSessions() }
runTest("ScanHealthTests.allTranscriptAdaptersReportMalformedRecords") { try ScanHealthTests().allTranscriptAdaptersReportMalformedRecords() }

runTest("OpenCodeAdapterTests.emptyDatabaseWithMissingActivitySchemaFails") { try OpenCodeAdapterTests().emptyDatabaseWithMissingActivitySchemaFails() }

runTest("OpenCodeAdapterTests.invalidUsageReportsIssueInsteadOfCrashing") { try OpenCodeAdapterTests().invalidUsageReportsIssueInsteadOfCrashing() }

runTest("HistoricalScannerTests.largeInactiveHistoryIsExcludedWhileCurrentSessionRemains") { try HistoricalScannerTests().largeInactiveHistoryIsExcludedWhileCurrentSessionRemains() }
runTest("HistoricalScannerTests.largeHistoricalQuestionGetsFullFieldsAndCost") { try HistoricalScannerTests().largeHistoricalQuestionGetsFullFieldsAndCost() }
runTest("HistoricalScannerTests.recentPreMidnightWorkGetsFullCost") { try HistoricalScannerTests().recentPreMidnightWorkGetsFullCost() }
runTest("HistoricalScannerTests.activityUpdateInvalidatesHistoricalExclusion") { try HistoricalScannerTests().activityUpdateInvalidatesHistoricalExclusion() }
runTest("HistoricalScannerTests.giantMetadataTailCannotHideAnEarlierQuestion") { try HistoricalScannerTests().giantMetadataTailCannotHideAnEarlierQuestion() }
runTest("HistoricalScannerTests.incompleteFinalRecordForcesFullRead") { try HistoricalScannerTests().incompleteFinalRecordForcesFullRead() }
runTest("HistoricalScannerTests.malformedHistoricalTailReportsFullRecordLocation") { try HistoricalScannerTests().malformedHistoricalTailReportsFullRecordLocation() }

runTest("OpenCodeAdapterTests.invalidUpdateTimePreservesReadableSession") { try OpenCodeAdapterTests().invalidUpdateTimePreservesReadableSession() }

runTest("OpenCodeAdapterTests.ancientRunningMarkersDoNotReturnAsCurrentSessions") { try OpenCodeAdapterTests().ancientRunningMarkersDoNotReturnAsCurrentSessions() }

finish()
