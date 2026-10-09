import Foundation

typealias TestClosure = () throws -> Void

@main
struct TestRunner {
    static func main() throws {
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--environment-worker" {
            let args = CommandLine.arguments
            try RecoveryCopyTests.runWorker(configPath: args[2], home: args[3], state: args[4])
            return
        }
        Log.logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmb-tests-\(ProcessInfo.processInfo.processIdentifier).log")
        let storeState = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb4d-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeState, withIntermediateDirectories: true)
        EncryptedStore.stateDirectory = storeState.path
        defer {
            do { try FileManager.default.removeItem(at: storeState) }
            catch {
                print("Encrypted-store test cleanup failed: \(error)")
                exit(1)
            }
        }
        var passed = 0
        var failed = 0
        var failedNames: [String] = []

        let exclude = ExcludeFilterTests()
        let retention = RetentionTests()
        let config = ConfigParserTests()
        let backup = BackupEngineTests()
        let hardLinker = HardLinkerTests()
        let protection = RightsManagementTests()
        let scanner = FileScannerTests()
        let hidden = HiddenDiscoveryTests()
        let tree = TreeSelectionTests()
        let cleanup = SnapshotCleanupTests()
        let safety = SafetyTests()
        let restore = RestoreTests()
        let protectionSummary = ProtectionSummaryTests()
        let guards = RestoreGuardTests()
        let review = ReviewFixTests()
        let review2 = ReviewRound2Tests()
        let realRun = RealRunTests()
        let coverageNoise = CoverageNoiseTests()
        let picker = PickerTests()
        let updater = UpdaterTests()
        let power = PowerGateTests()
        let stages = NewMacStageTests()
        let onboarding = OnboardingTests()
        let encryption = EncryptionTests()
        let homeRewrite = HomeRewriteTests()
        let optimization = BackupOptimizationTests()
        let ejection = EjectionTests()
        let recovery = RecoveryCopyTests()

        let suites: [(String, TestClosure)] = [
            ("Recovery.backupDoesNotCopyApp", recovery.test_backupFinishesWithoutRefreshingPhysicalDisk),
            ("Recovery.concurrentCopySkipped", recovery.test_competingCopyDoesNotWaitOrTouchStaging),
            ("Recovery.timeoutKeepsOldApp", recovery.test_timeoutPreservesExistingRecoveryApp),
            ("Recovery.failedReplacementRollsBack", recovery.test_failedReplacementRestoresPreviousApp),
            ("Ejection.plainSuccess", ejection.test_plainDiskProgressAndSuccess),
            ("Ejection.encryptedOrder", ejection.test_encryptedStoreClosesFirst),
            ("Ejection.busyStore", ejection.test_busyStoreNeverEjects),
            ("Ejection.indexerFallback", ejection.test_indexersOnlyAllowFallback),
            ("Ejection.failureIsNotSuccess", ejection.test_failureAndMountedSuccessStayUnsafe),
            ("Ejection.feedbackLifecycle", ejection.test_feedbackLifecycle),
            ("Ejection.closeReason", ejection.test_closeReportingPreservesCommandFailure),
            ("Ejection.fallbackReason", ejection.test_closeReportingKeepsFallbackErrorAndExitCode),
            ("Safety.noFileIsDropped", safety.test_noFileIsDropped),
            ("Optimization.backgroundPolicy", optimization.test_backgroundPolicyNeverRaisesExistingPriority),
            ("Optimization.diskPolicyRestored", optimization.test_diskPolicyUsesSDKAndRestores),
            ("Optimization.concurrentDirectories", optimization.test_directoryPreparationIsConcurrentAndRunScoped),
            ("Optimization.failedDirectories", optimization.test_directoryFailuresAreNotCached),
            ("Optimization.removedDirectories", optimization.test_copyRecreatesRemovedCachedDirectory),
            ("Optimization.previousMetadata", optimization.test_previousMetadataRejectsSymlinksAndKeepsTolerance),
            ("Safety.copyErrorMakesIncomplete", safety.test_copyErrorMakesSnapshotIncomplete),
            ("Safety.excludedSourceNotMissing", safety.test_excludedSourceDoesNotMakeSnapshotIncomplete),
            ("Safety.shrinkWarning", safety.test_shrinkWarningOnEmptiedHome),
            ("Safety.retentionProtectsComplete", safety.test_retentionProtectsLastCompleteSnapshots),
            ("Safety.retentionPausesAfterShrink", safety.test_retentionPausesAfterShrink),
            ("Safety.unpushedCommitsSurvive", safety.test_unpushedCommitsSurviveRestore),
            ("Safety.sqliteCopied", safety.test_sqliteIsCopiedConsistently),
            ("Safety.coverageFindsUncovered", safety.test_coverageFindsActiveUncoveredFolder),
            ("Safety.configRoundTrip", safety.test_configRoundTripNewSections),
            ("Restore.topicWildcardsAndJunk", restore.test_topicFilesExpandWildcardsAndSkipJunk),
            ("Restore.configTopics", restore.test_configTopicsOverrideAndExtend),
            ("Restore.planApplyPerFileUndo", restore.test_planApplyAndPerFileUndo),
            ("Restore.versions", restore.test_versionsAreDistinctNewestFirst),
            ("Restore.newMacRepository", restore.test_newMacRebuildsRepository),
            ("Protection.levels", protectionSummary.test_levels),
            ("Restore.symlinksAndDotDot", guards.test_symlinksAndDotDotAreLeftAlone),
            ("Review.H1.undoKeepsChanged", review.test_undoKeepsFilesChangedAfterRestore),
            ("Review.H2.unreadableRepo", review.test_unreadableRepositoryMakesSnapshotIncomplete),
            ("Review.H3.missingSource", review.test_missingSourceAfterCompleteSnapshotIsIncomplete),
            ("Review.H4.deletedRemoteBranch", review.test_bundleAppliesWhenRemoteBranchWasDeleted),
            ("Review.M4.typeConflict", review.test_typeConflictIsLeftAlone),
            ("Review.M5.safeRelative", review.test_safeRelativeRefusesTricks),
            ("Review.M8.slotPrefersComplete", review.test_retentionSlotPrefersComplete),
            ("Review.shrinkBaseline", review.test_shrinkAgainstUnverifiedBaseline),
            ("Review.R1.stopMidBackup", review2.test_stopMidBackupDoesNotCrash),
            ("Review.R2.longOutput", review2.test_longOutputIsComplete),
            ("Review.R3.bundleHardLinked", review2.test_unchangedBundleIsHardLinked),
            ("RealRun.objectlessGit", realRun.test_objectlessGitIsAWarning),
            ("RealRun.walDatabase", realRun.test_walDatabaseIsCopied),
            ("Coverage.noNoise", coverageNoise.test_noSecretsParkedCopiesOrToolDatabases),
            ("Picker.configuredFoldersSurvive", picker.test_configuredFoldersSurviveThePicker),
            ("Picker.selectAllSkipsCredentials", picker.test_selectAllSkipsCredentials),
            ("Updater.signatureOnlyReleaseKey", updater.test_signatureAcceptsOnlyTheReleaseKey),
            ("Updater.versionsNeverGoBack", updater.test_versionsNeverGoBack),
            ("Updater.validateRejectsWrongBuilds", updater.test_validateRejectsWrongBuilds),
            ("Updater.swapWhole", updater.test_swapReplacesTheAppWholeAndLeavesNothingBehind),
            ("Updater.failedSwapKeepsOld", updater.test_failedSwapKeepsTheOldApp),
            ("Updater.swapFromLegacyName", updater.test_swapFromLegacyNameLeavesOnlyTheNewApp),
            ("Rename.foldersMove", updater.test_foldersMoveAndOldPlacesStillWork),
            ("Power.acAllowed", power.test_acAllowsScheduled),
            ("Power.batteryBlocks", power.test_batteryBlocksScheduled),
            ("Power.unknownBlocks", power.test_unknownBlocksScheduled),
            ("Power.plistPassesFlag", power.test_plistsPassScheduledFlag),
            ("Schedule.wallClockIntervals", power.test_intervalUsesWallClockCalendar),
            ("Schedule.customIntervalsPreserved", power.test_nonCalendarIntervalsArePreserved),
            ("Schedule.calendarMigration", power.test_calendarMigrationPreservesJob),
            ("Schedule.migrationLocksBackup", power.test_calendarMigrationSerializesWithBackup),
            ("Schedule.rollbackKeepsLock", power.test_calendarMigrationRollbackHoldsLock),
            ("Progress.unknownTotal", backup.test_progressUnknownUntilScanFinishes),
            ("Progress.hardlinksAndFinalization", backup.test_progressKnownCountsHardlinksAndFinalization),
            ("Progress.legacyEta", backup.test_oldStatusDoesNotDisplayInventedEta),
            ("Progress.restoreAndStop", backup.test_restoreAndStoppingProgressRemainAccurate),
            ("Power.liveReaderSane", power.test_liveReaderReturnsAValue),
            ("NewMac.loginItemsNeverInFilePhase", stages.test_loginItemsAreNeverInAFilePhase),
            ("NewMac.brokenShellUndoes", stages.test_brokenShellUndoesItsPhase),
            ("NewMac.realShellCheck", stages.test_realShellCheckCatchesExitAndPassesHealthy),
            ("NewMac.phaseUndoAlone", stages.test_eachPhaseUndoesOnItsOwn),
            ("NewMac.serviceHealth", stages.test_serviceHealthFromLaunchctl),
            ("NewMac.serviceMovedAside", stages.test_removedServiceIsMovedAsideNotDeleted),
            ("NewMac.ignoredApps", stages.test_ignoredAppsAreNeverListedAndSurviveSave),
            ("Onboarding.brewfileAndLists", onboarding.test_brewfileAndPackageListsAreParsed),
            ("Onboarding.baseToolsFirst", onboarding.test_newMacStartsWithBaseToolsThenPrograms),
            ("Onboarding.scanProtectsSecrets", onboarding.test_scanGroupsAndProtectsSecrets),
            ("Onboarding.projectRootsSkipCloud", onboarding.test_projectRootsSkipCloudFoldersAndLinks),
            ("Onboarding.configFromChoices", onboarding.test_configFromChoicesKeepsOnlyWhatWasChosen),
            ("Rename.scheduleKeepsWrapper", onboarding.test_legacyScheduleKeepsWrapperAndFlags),
            ("Onboarding.credentialFolder", onboarding.test_folderWithACredentialIsACredential),
            ("Recovery.appKeptCurrent", onboarding.test_recoveryAppIsKeptCurrent),
            ("Encryption.passwordRules", encryption.test_passwordRules),
            ("Encryption.keychainStatus", encryption.test_keychainStatusFailsClosed),
            ("Encryption.isolatedState", encryption.test_stateDirectoryIsolatesLocksAndMarkers),
            ("Encryption.storeBasics", encryption.test_storeEncryptsKeepsHardLinksAndRefusesWrongPassword),
            ("Encryption.realBackup", encryption.test_realBackupIntoTheEncryptedStore),
            ("Encryption.keychainAndEnsureOpen", encryption.test_keychainRoundTripAndEnsureOpen),
            ("Encryption.configSection", encryption.test_configKeepsTheEncryptionSection),
            ("Encryption.existingStoreAdopted", encryption.test_existingStoreIsAdoptedNotRecreated),
            ("Encryption.compaction", encryption.test_compactionGivesSpaceBack),
            ("Encryption.pulledOutChecked", encryption.test_pulledOutStoreIsCheckedOnReopen),
            ("Encryption.freedFlag", encryption.test_freedSpaceIsFlaggedOnlyForStores),
            ("Stop.sigtermStopsBackup", encryption.test_sigtermStopsARunningBackupQuickly),
            ("NewUser.wholeComponents", homeRewrite.test_onlyWholePathComponentsAreReplaced),
            ("NewUser.textAndPlist", homeRewrite.test_textAndBinaryPlistAreRewrittenOthersLeftAlone),
            ("NewUser.restoreRewrites", homeRewrite.test_newUserGetsRewrittenConfigOnRestore),
            ("NewUser.guessOldHome", homeRewrite.test_oldHomeGuessedForOlderSnapshots),
            ("Cleanup.ageBoundaries", cleanup.test_ageBoundariesAndPreview),
            ("Cleanup.onlySnapshots", cleanup.test_latestAndNonSnapshotsSurvive),
            ("Cleanup.hardLinks", cleanup.test_hardLinksAndOriginalSurvive),
            ("Cleanup.lockAndCancel", cleanup.test_lockAndCancellation),
            ("Cleanup.legacyAndDestination", cleanup.test_legacyLockAndInvalidDestination),
            ("Cleanup.failures", cleanup.test_changedPreviewAndDeletionFailure),
            ("Cleanup.emptyAndSingle", cleanup.test_emptyAndSingleBackup),
            ("Cleanup.cliOptions", cleanup.test_cliOptions),
            ("ExcludeFilter.mandatoryCaches", exclude.test_mandatoryCachesWithOldConfig),
            ("ExcludeFilter.nestedPaths", exclude.test_nestedMultiComponentPatterns),
            ("FileScanner.explicitExclusions", scanner.test_explicitSourcesCannotBypassExclusions),
            ("ExcludeFilter.wildcardStar", exclude.test_wildcardStar),
            ("ExcludeFilter.wildcardQuestion", exclude.test_wildcardQuestion),
            ("ExcludeFilter.componentMatch", exclude.test_componentMatch),
            ("ExcludeFilter.pathPrefixMatch", exclude.test_pathPrefixMatch),
            ("ExcludeFilter.notExcluded", exclude.test_notExcluded),
            ("ExcludeFilter.directorySkip", exclude.test_directorySkip),
            ("ExcludeFilter.dotPatterns", exclude.test_dotPatterns),
            ("ExcludeFilter.globEquivalent", exclude.test_globMatchesOriginalSemantics),
            ("ExcludeFilter.compiledEquivalent", exclude.test_compiledFiltersPreserveMatchingAndPruning),
            ("ExcludeFilter.checkoutsMandatory", exclude.test_checkoutsAreMandatoryExcludedEvenWithOldConfig),
            ("ExcludeFilter.pluginCacheDirMandatory", exclude.test_pluginCacheDirIsMandatoryExcludedDistinctFromDotCache),
            ("ExcludeFilter.sitePackagesOfficeAssets", exclude.test_sitePackagesOfficeAssetsAreMandatoryExcluded),
            ("HiddenDiscovery.deniedCacheNames", hidden.test_deniedCacheNames),
            ("HiddenDiscovery.realConfigSurvives", hidden.test_realConfigSurvives),
            ("HiddenDiscovery.deniedPaths", hidden.test_deniedPaths),
            ("HiddenDiscovery.secretsStayOptIn", hidden.test_secretsStayOptIn),
            ("HiddenDiscovery.pruneRedundant", hidden.test_pruneRedundant),
            ("HiddenDiscovery.sizeIgnoresExcludedContent", hidden.test_sizeIgnoresExcludedContent),
            ("HiddenDiscovery.claudeScriptsNotForbidden", hidden.test_claudeScriptsIsBackedUpNotForbidden),
            ("HiddenDiscovery.launchAgentsDiscovered", hidden.test_launchAgentsAreDiscovered),
            ("HiddenDiscovery.checkoutsIsDenied", hidden.test_checkoutsIsADeniedName),
            ("HiddenDiscovery.cloudStorageForbiddenByDefault", hidden.test_cloudStorageForbiddenByDefault),
            ("HiddenDiscovery.cloudStorageAllowedOnlyWithOptIn", hidden.test_cloudStorageAllowedOnlyWithExplicitOptIn),
            ("Retention.parseValid", retention.test_parseBackupName_valid),
            ("Retention.parseInvalid", retention.test_parseBackupName_invalid),
            ("Retention.keepLatest", retention.test_alwaysKeepLatest),
            ("Retention.hourly", retention.test_hourlyRetention),
            ("Retention.dryRun", retention.test_dryRunNoDeletion),
            ("Retention.monthlyForever", retention.test_monthlyForever),
            ("Config.parseFull", config.test_parseFullConfig),
            ("Config.defaults", config.test_defaultRetention),
            ("Config.comments", config.test_commentsIgnored),
            ("Config.roundTrip", config.test_roundTrip),
            ("Config.legacyMigration", config.test_legacyConfigMigration),
            ("Config.protectionPreference", config.test_protectionPreferenceRoundTripAndMigration),
            ("TreeSelection.protectionToggle", tree.test_protectionToggleIsIndependentAndConfirmed),
            ("TreeSelection.addCustomPathRejectsForbidden", tree.test_addCustomPathRejectsForbiddenPaths),
            ("BackupEngine.naming", backup.test_snapshotNaming),
            ("BackupEngine.inProgress", backup.test_inProgressPrefix),
            ("BackupEngine.statusFormat", backup.test_statusFileFormat),
            ("HardLinker.sameFile", hardLinker.test_sameFileSameSizeMtime),
            ("HardLinker.diffSize", hardLinker.test_differentSize),
            ("HardLinker.hardLink", hardLinker.test_hardLinkCreation),
            ("HardLinker.copyFile", hardLinker.test_copyFileCreation),
            ("Protection.containers", protection.test_protectedContainersAcrossFormats),
            ("Protection.compound", protection.test_compoundProtectionAndPasswordDistinction),
            ("Protection.pdf", protection.test_pdfProtectionAndOrdinaryText),
            ("Protection.ordinaryIncluded", protection.test_ordinaryOfficeAndOtherFilesRemainIncluded),
            ("Protection.copyAndLink", protection.test_preferenceBeforeCopyAndHardLink),
            ("Protection.inspectionFailures", protection.test_inspectionFailuresAreNotClaimedAsProtection),
            ("Protection.permissionErrors", protection.test_permissionErrorsKeepActionableCategory),
            ("Protection.reporting", protection.test_skipsAreReportedSeparately),
            ("FileScanner.excludedFileKeepsSibling", scanner.test_excludedFileDoesNotSwallowSiblingDirectory),
            ("FileScanner.excludedDirPruned", scanner.test_excludedDirectoryIsStillPruned),
            ("FileScanner.multipleExcludedFiles", scanner.test_multipleExcludedFilesBeforeDirectory)
        ]

        print("🧪 Running MacBackup4Dev tests (\(suites.count) total)...")
        for (name, test) in suites {
            do {
                try test()
                passed += 1
                print("  ✅ \(name)")
            } catch {
                failed += 1
                failedNames.append(name)
                print("  ❌ \(name): \(error)")
            }
        }

        print("\n\(passed + failed) tests, \(passed) passed, \(failed) failed")
        if !failedNames.isEmpty {
            print("Failed: \(failedNames.joined(separator: ", "))")
            exit(1)
        }
    }
}
